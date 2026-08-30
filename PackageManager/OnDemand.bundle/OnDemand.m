/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * OnDemand — GNUstep bundle loaded into every GUI app via GSAppKitUserBundles.
 * When an app launches, checks whether it ships a Resources/Dependencies.plist
 * and offers to install missing packages directly via the system package manager.
 */

#import "OnDemand.h"
#import <PackageManager/ODProgressWindow.h>

@interface OnDemand ()
+ (void)_appDidFinishLaunch:(NSNotification *)n;
+ (NSArray *)_packagesFromPlistAtPath:(NSString *)plistPath
                             osOverride:(NSString *)os;
+ (NSArray *)_missingPackagesFromArray:(NSArray *)packages;
+ (BOOL)_commandExists:(NSString *)command;
+ (void)_showErrorAlert:(NSString *)title detail:(NSString *)detail;
+ (void)_runInstallWithPackages:(NSArray *)packages;
@end

static NSTask *_installTask = nil;
static NSPipe *_installPipe = nil;
static ODProgressWindow *_progressWin = nil;
static BOOL _installSucceeded = NO;

@implementation OnDemand

+ (void)load
{
  [[NSNotificationCenter defaultCenter]
    addObserver:[self class]
    selector:@selector(_appDidFinishLaunch:)
    name:NSApplicationDidFinishLaunchingNotification
    object:nil];
  NSLog(@"OnDemand bundle: registered for app-launch notifications");
}

+ (void)_appDidFinishLaunch:(NSNotification *)n
{
  NSBundle *appBundle = [NSBundle mainBundle];
  if (!appBundle) return;

  NSString *bundlePath = [appBundle bundlePath];

  NSString *selfBundle = [[NSBundle bundleForClass:[self class]] bundlePath];
  if ([bundlePath isEqualToString:selfBundle] ||
      [bundlePath hasPrefix:@"/System/Applications/Utilities/OnDemand"])
    return;

  NSString *depsPlist = [bundlePath stringByAppendingPathComponent:
                           @"Resources/Dependencies.plist"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:depsPlist])
    return;

  NSLog(@"OnDemand bundle: found Dependencies.plist in %@", bundlePath);

  NSString *appName = [[bundlePath lastPathComponent] stringByDeletingPathExtension];

  NSString *os = nil;
#if defined(__FreeBSD__) || defined(__FreeBSD_kernel__)
  os = @"freebsd";
#elif defined(__OpenBSD__)
  os = @"openbsd";
#elif defined(__NetBSD__)
  os = @"netbsd";
#elif defined(__linux__)
  os = @"linux";
#endif

  NSArray *packages = [self _packagesFromPlistAtPath:depsPlist osOverride:os];

  if (!packages || [packages count] == 0)
    {
      NSLog(@"OnDemand bundle: no packages to install for %@", appName);
      return;
    }

  NSArray *missing = [self _missingPackagesFromArray:packages];

  if ([missing count] == 0)
    {
      NSLog(@"OnDemand bundle: all dependencies satisfied for %@", appName);
      return;
    }

  NSLog(@"OnDemand bundle: missing packages for %@: %@", appName, missing);

  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:[NSString stringWithFormat:
    @"%@ needs additional software to run.", appName]];
  [alert setInformativeText:[NSString stringWithFormat:
    @"The following packages are missing and need to be installed:\n\n• %@\n\n"
    @"Would you like to install them now?",
    [[missing copy] componentsJoinedByString:@"\n• "]]];
  [alert addButtonWithTitle:@"Install"];
  [alert addButtonWithTitle:@"Skip"];

  NSInteger result = [alert runModal];
  if (result != NSAlertFirstButtonReturn)
    {
      NSLog(@"OnDemand bundle: user skipped installation for %@", appName);
      return;
    }

  [self _runInstallWithPackages:missing];
}

+ (void)_runInstallWithPackages:(NSArray *)packages
{
  NSLog(@"OnDemand bundle: installing packages: %@", packages);

  NSString *pmBin = nil;
  NSMutableArray *pmArgs = [NSMutableArray array];

  if ([[NSFileManager defaultManager] fileExistsAtPath:@"/usr/bin/apt-get"])
    {
      pmBin = @"/usr/bin/sudo";
      [pmArgs addObject:@"-A"];
      [pmArgs addObject:@"-E"];
      [pmArgs addObject:@"/usr/bin/apt-get"];
      [pmArgs addObject:@"install"];
      [pmArgs addObjectsFromArray:packages];
      [pmArgs addObject:@"-y"];
    }
  else if ([[NSFileManager defaultManager] fileExistsAtPath:@"/usr/bin/dnf"])
    {
      pmBin = @"/usr/bin/sudo";
      [pmArgs addObject:@"-A"];
      [pmArgs addObject:@"-E"];
      [pmArgs addObject:@"/usr/bin/dnf"];
      [pmArgs addObject:@"install"];
      [pmArgs addObjectsFromArray:packages];
    }
  else if ([[NSFileManager defaultManager] fileExistsAtPath:@"/usr/bin/pacman"])
    {
      pmBin = @"/usr/bin/sudo";
      [pmArgs addObject:@"-A"];
      [pmArgs addObject:@"-E"];
      [pmArgs addObject:@"/usr/bin/pacman"];
      [pmArgs addObject:@"-S"];
      [pmArgs addObjectsFromArray:packages];
    }
  else if ([[NSFileManager defaultManager] fileExistsAtPath:@"/usr/sbin/pkg"])
    {
      pmBin = @"/usr/bin/sudo";
      [pmArgs addObject:@"-A"];
      [pmArgs addObject:@"-E"];
      [pmArgs addObject:@"/usr/sbin/pkg"];
      [pmArgs addObject:@"install"];
      [pmArgs addObjectsFromArray:packages];
    }
  else
    {
      [self _showErrorAlert:@"No Package Manager Found"
                      detail:@"Could not find apt-get, dnf, pacman, or pkg.\n\nPlease install packages manually."];
      return;
    }

  NSLog(@"OnDemand bundle: running: %@ %@", pmBin, [pmArgs componentsJoinedByString:@" "]);

  _installTask = [[NSTask alloc] init];
  [_installTask setLaunchPath:pmBin];
  [_installTask setArguments:pmArgs];
  [_installTask setEnvironment:[NSProcessInfo processInfo].environment];

  _installPipe = [NSPipe pipe];
  [_installTask setStandardOutput:_installPipe];
  [_installTask setStandardError:_installPipe];

  _progressWin = [[ODProgressWindow alloc] initWithTitle:@"Installing..."
                                                  message:@"Installing required packages..."
                                                 packages:packages];

  [_progressWin showWindow:nil];
  NSLog(@"OnDemand bundle: progress window shown");

  @try
    {
      [_installTask launch];
      NSLog(@"OnDemand bundle: task launched");
    }
  @catch (NSException *e)
    {
      [_progressWin close];
      [self _showErrorAlert:@"Installation Failed"
                      detail:[NSString stringWithFormat:@"Could not run package manager:\n%@", e]];
      return;
    }

  while ([_installTask isRunning])
    {
      NSEvent *event = [NSApp nextEventMatchingMask:NSAnyEventMask
                                           untilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]
                                              inMode:NSDefaultRunLoopMode
                                             dequeue:YES];
      if (event)
        [NSApp sendEvent:event];

      if ([_progressWin cancelled])
        {
          [_installTask interrupt];
          [_progressWin close];
          return;
        }
    }

  NSData *outData = [[_installPipe fileHandleForReading] readDataToEndOfFile];
  NSString *outStr = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
  NSInteger status = [_installTask terminationStatus];

  [_progressWin close];

  if (status != 0)
    {
      NSLog(@"OnDemand bundle: install failed with status %ld", (long)status);
      [self _showErrorAlert:@"Installation Failed"
                      detail:[NSString stringWithFormat:@"The package manager exited with an error:\n%@",
                        [outStr substringToIndex:MIN([outStr length], 500)]]];
    }
  else
    {
      NSLog(@"OnDemand bundle: install succeeded");
    }
}

+ (void)_showErrorAlert:(NSString *)title detail:(NSString *)detail
{
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:title];
  [alert setInformativeText:detail];
  [alert addButtonWithTitle:@"OK"];
  [alert runModal];
}

+ (NSArray *)_packagesFromPlistAtPath:(NSString *)plistPath
                             osOverride:(NSString *)os
{
  NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
  if (!plist) return nil;

  NSMutableArray *packages = [NSMutableArray array];

  NSArray *basePackages = [plist objectForKey:@"packages"];
  if ([basePackages isKindOfClass:[NSArray class]])
    [packages addObjectsFromArray:basePackages];

  NSDictionary *osOverrides = [plist objectForKey:@"os_overrides"];
  if ([osOverrides isKindOfClass:[NSDictionary class]] && os)
    {
      NSDictionary *override = [osOverrides objectForKey:os];
      if ([override isKindOfClass:[NSDictionary class]])
        {
          NSArray *overridePackages = [override objectForKey:@"packages"];
          if ([overridePackages isKindOfClass:[NSArray class]])
            [packages addObjectsFromArray:overridePackages];
        }
    }

  return packages;
}

+ (NSArray *)_missingPackagesFromArray:(NSArray *)packages
{
  NSMutableArray *missing = [NSMutableArray array];
  for (NSString *pkg in packages)
    {
      NSString *cmd = [[pkg componentsSeparatedByString:@"_"] firstObject];
      if (!cmd || [cmd length] == 0) cmd = pkg;
      if (![self _commandExists:cmd])
        [missing addObject:pkg];
    }
  return missing;
}

+ (BOOL)_commandExists:(NSString *)command
{
  if (!command || [command length] == 0) return NO;
  if ([command hasPrefix:@"/"])
    return [[NSFileManager defaultManager] isExecutableFileAtPath:command];

  NSTask *t = [[NSTask alloc] init];
  [t setLaunchPath:@"/usr/bin/which"];
  [t setArguments:@[command]];
  NSPipe *p = [NSPipe pipe];
  [t setStandardOutput:p];
  [t setStandardError:[NSPipe pipe]];
  @try
    {
      [t launch];
      [t waitUntilExit];
      return ([t terminationStatus] == 0);
    }
  @catch (NSException *e)
    {
      return NO;
    }
}

@end

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
#import <AppKit/AppKit.h>

@interface OnDemand ()
+ (void)_appDidFinishLaunch:(NSNotification *)n;
+ (NSArray *)_packagesFromPlistAtPath:(NSString *)plistPath
                             osOverride:(NSString *)os;
+ (NSArray *)_missingPackagesFromArray:(NSArray *)packages;
+ (BOOL)_commandExists:(NSString *)command;
+ (BOOL)_installPackages:(NSArray *)packages;
+ (NSString *)_sudoHelperPath;
@end

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

  BOOL success = [self _installPackages:missing];
  if (!success)
    {
      NSAlert *errAlert = [[NSAlert alloc] init];
      [errAlert setMessageText:@"Installation Failed"];
      [errAlert setInformativeText:[NSString stringWithFormat:
        @"Could not install the required packages:\n\n• %@\n\n"
        @"Please try installing them manually.",
        [[missing copy] componentsJoinedByString:@"\n• "]]];
      [errAlert runModal];
    }
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

+ (NSString *)_sudoHelperPath
{
  NSArray *paths = @[
    @"/System/Library/Tools/gershwin-sudo-helper",
    @"/System/Library/Tools/sudo-helper",
    @"/usr/bin/sudo"
  ];
  for (NSString *p in paths)
    {
      if ([[NSFileManager defaultManager] fileExistsAtPath:p])
        return p;
    }
  return @"/usr/bin/sudo";
}

+ (BOOL)_installPackages:(NSArray *)packages
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
      NSLog(@"OnDemand bundle: no known package manager found");
      return NO;
    }

  NSLog(@"OnDemand bundle: running: %@ %@", pmBin, [pmArgs componentsJoinedByString:@" "]);

  NSTask *t = [[NSTask alloc] init];
  [t setLaunchPath:pmBin];
  [t setArguments:pmArgs];
  [t setEnvironment:[NSProcessInfo processInfo].environment];

  NSPipe *outPipe = [NSPipe pipe];
  [t setStandardOutput:outPipe];
  [t setStandardError:outPipe];

  @try
    {
      [t launch];
      [t waitUntilExit];
      NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
      NSString *outStr = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
      NSLog(@"OnDemand bundle: install output: %@", outStr);
      NSLog(@"OnDemand bundle: install exited with status %d", [t terminationStatus]);
      return ([t terminationStatus] == 0);
    }
  @catch (NSException *e)
    {
      NSLog(@"OnDemand bundle: failed to run package manager: %@", e);
      return NO;
    }
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

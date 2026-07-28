/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BootEnvironmentPane.h"
#import "BootConfigController.h"
#include <stdlib.h>

@implementation BootEnvironmentPane

+ (BOOL)rootIsZFS {
  NSString *mounts = [NSString stringWithContentsOfFile:@"/proc/mounts"
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
  if (mounts) {
    for (NSString *line in [mounts componentsSeparatedByString:@"\n"]) {
      NSArray *fields = [line componentsSeparatedByString:@" "];
      if ([fields count] >= 3 &&
          [[fields objectAtIndex:1] isEqualToString:@"/"] &&
          [[fields objectAtIndex:2] isEqualToString:@"zfs"])
        return YES;
    }
    return NO;
  }
  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:@"/sbin/mount"];
  [task setArguments:@[@"-p"]];
  NSPipe *pipe = [NSPipe pipe];
  [task setStandardOutput:pipe];
  @try {
    [task launch];
    [task waitUntilExit];
  } @catch (NSException *e) {
    [task release];
    return NO;
  }
  NSString *output = [[[NSString alloc] initWithData:[[pipe fileHandleForReading] readDataToEndOfFile]
                                            encoding:NSUTF8StringEncoding] autorelease];
  [task release];
  for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
    NSArray *fields = [line componentsSeparatedByString:@"\t"];
    if ([fields count] >= 3 &&
        [[fields objectAtIndex:1] isEqualToString:@"/"] &&
        [[fields objectAtIndex:2] isEqualToString:@"zfs"])
      return YES;
  }
  return NO;
}

+ (BOOL)isCompatible {
  if (![self rootIsZFS]) return NO;
  NSString *pathEnv = [NSString stringWithUTF8String: getenv("PATH")];
  NSArray *paths = [pathEnv componentsSeparatedByString: @":"];
  for (NSString *dir in paths) {
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:
          [dir stringByAppendingPathComponent: @"bectl"]])
      return YES;
  }
  return NO;
}

+ (NSString *)compatibilityReason {
  return @"Root filesystem is not ZFS or bectl not found — boot environment management requires both";
}

- (id)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        bootConfigController = [[BootConfigController alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self stopRefreshTimer];
    [bootConfigController release];
    [super dealloc];
}

- (void)startRefreshTimer
{
    if (!refreshTimer) {
        refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 
                                                        target:bootConfigController 
                                                      selector:@selector(refreshConfigurations:) 
                                                      userInfo:nil 
                                                       repeats:YES];
        [refreshTimer retain];
    }
}

- (void)stopRefreshTimer
{
    if (refreshTimer) {
        [refreshTimer invalidate];
        [refreshTimer release];
        refreshTimer = nil;
    }
}

- (NSView *)loadMainView
{
    if (!_mainView) {
        _mainView = [[bootConfigController createMainView] retain];
    }
    return _mainView;
}

- (NSString *)mainNibName
{
    return nil; // We create the view programmatically
}

- (void)mainViewDidLoad
{
    // Initialize the boot config controller data
    [bootConfigController refreshConfigurations:nil];
}

- (void)didSelect
{
    [super didSelect];
    // Refresh data when the pane is selected and start polling
    [bootConfigController refreshConfigurations:nil];
    [self startRefreshTimer];
}

- (void)didUnselect
{
    [super didUnselect];
    // Stop polling when the pane is not visible
    [self stopRefreshTimer];
}

- (BOOL)autoSaveTextFields
{
    return YES;
}

@end

/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BootEnvironmentPane.h"
#import "BootConfigController.h"
#include <stdlib.h>

@implementation BootEnvironmentPane

+ (BOOL)isCompatible {
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
  return @"/sbin/bectl not found — boot environment management requires bectl";
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

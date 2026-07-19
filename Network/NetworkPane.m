/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Network Preference Pane Implementation
 */

#import "NetworkPane.h"
#import "NetworkController.h"
#include <stdlib.h>

@implementation NetworkPane

+ (BOOL)isCompatible {
  NSString *pathEnv = [NSString stringWithUTF8String: getenv("PATH")];
  NSArray *paths = [pathEnv componentsSeparatedByString: @":"];
  for (NSString *dir in paths) {
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:
          [dir stringByAppendingPathComponent: @"nmcli"]])
      return YES;
  }
  for (NSString *dir in paths) {
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:
          [dir stringByAppendingPathComponent: @"ifconfig"]])
      return YES;
  }
  return NO;
}

+ (NSString *)compatibilityReason {
  return @"Network configuration tools not found";
}

- (id)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        controller = [[NetworkController alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [self stopRefreshTimer];
    [controller release];
    [super dealloc];
}

- (void)startRefreshTimer
{
    if (!refreshTimer) {
        refreshTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                        target:controller
                                                      selector:@selector(refreshInterfaces:)
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
    if (_mainView == nil) {
        _mainView = [[controller createMainView] retain];
    }
    return _mainView;
}

- (NSString *)mainNibName
{
    return nil; // We create the view programmatically
}

- (void)mainViewDidLoad
{
    // Initial data refresh
    [controller refreshInterfaces:nil];
    [self setInitialKeyView:nil];
}

- (void)didSelect
{
    [super didSelect];
    // Refresh data when the pane is selected
    [controller refreshInterfaces:nil];
    [self startRefreshTimer];
    [self setInitialKeyView:nil];
}

- (void)willUnselect
{
    NSDebugLLog(@"gwcomp", @"NetworkPane: willUnselect called");
}

- (void)didUnselect
{
    [super didUnselect];
    [self stopRefreshTimer];
    NSDebugLLog(@"gwcomp", @"NetworkPane: didUnselect called");
}

- (NSPreferencePaneUnselectReply)shouldUnselect
{
    NSDebugLLog(@"gwcomp", @"NetworkPane: shouldUnselect called, allowing unselect");
    return NSUnselectNow;
}

@end

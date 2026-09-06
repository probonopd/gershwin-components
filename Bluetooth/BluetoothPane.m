/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BluetoothPane.h"
#import "BluetoothController.h"
#include <stdlib.h>

@implementation BluetoothPane

+ (BOOL)isCompatible {
  NSString *pathEnv = [NSString stringWithUTF8String: getenv("PATH")];
  NSArray *paths = [pathEnv componentsSeparatedByString: @":"];
  for (NSString *dir in paths) {
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:
          [dir stringByAppendingPathComponent: @"bluetoothctl"]])
      return YES;
  }
  return NO;
}

+ (NSString *)compatibilityReason {
  return @"bluetoothctl not found — Bluetooth configuration requires bluez";
}

- (id)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        controller = [[BluetoothController alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [pollTimer invalidate];
    [pollTimer release];
    [controller release];
    [super dealloc];
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
    return nil;
}

- (void)mainViewDidLoad
{
    [controller refreshFromSystem];
}

- (void)didSelect
{
    [super didSelect];
    [controller refreshFromSystem];
    [self startPolling];
}

- (void)didUnselect
{
    [self stopPolling];
    [super didUnselect];
}

- (BOOL)autoSaveTextFields
{
    return YES;
}

#pragma mark - Polling

- (void)startPolling
{
    if (pollTimer) return;
    pollTimer = [[NSTimer scheduledTimerWithTimeInterval:2.0
                                                  target:self
                                                selector:@selector(pollTick:)
                                                userInfo:nil
                                                 repeats:YES] retain];
}

- (void)stopPolling
{
    if (!pollTimer) return;
    [pollTimer invalidate];
    [pollTimer release];
    pollTimer = nil;
}

- (void)pollTick:(NSTimer *)timer
{
    (void)timer;
    [controller pollDevices];
}

@end

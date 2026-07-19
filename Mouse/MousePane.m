/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MousePane.h"
#import "MouseController.h"
#include <stdlib.h>

@implementation MousePane

+ (BOOL)isCompatible {
  NSString *pathEnv = [NSString stringWithUTF8String: getenv("PATH")];
  NSArray *paths = [pathEnv componentsSeparatedByString: @":"];
  for (NSString *dir in paths) {
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:
          [dir stringByAppendingPathComponent: @"xinput"]])
      return YES;
  }
  return NO;
}

+ (NSString *)compatibilityReason {
  return @"xinput not found — mouse configuration requires X11";
}

- (id)initWithBundle:(NSBundle *)bundle
{
    self = [super initWithBundle:bundle];
    if (self) {
        controller = [[MouseController alloc] init];
    }
    return self;
}

- (void)dealloc
{
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
}

- (BOOL)autoSaveTextFields
{
    return YES;
}

@end

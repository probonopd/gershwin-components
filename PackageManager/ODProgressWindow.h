/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Shared progress window used by OnDemand.app and OnDemand.bundle.
 */

#import <AppKit/AppKit.h>

@interface ODProgressWindow : NSWindow
{
  NSProgressIndicator *_progressBar;
  NSTextField *_statusField;
  NSButton *_cancelButton;
  BOOL _cancelled;
}

@property (nonatomic, readonly) BOOL cancelled;

- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *)message
                     packages:(NSArray *)packages;

- (void)updateProgress:(float)progress message:(NSString *)message;
- (void)setStatus:(NSString *)status;
- (void)showWindow:(id)sender;

@end

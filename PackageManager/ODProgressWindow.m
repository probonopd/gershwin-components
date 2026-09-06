/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Shared progress window used by OnDemand.app and OnDemand.bundle.
 */

#import "ODProgressWindow.h"

static const CGFloat kWinWidth = 400.0;
static const CGFloat kSideMargin = 24.0;
static const CGFloat kBottomMargin = 20.0;
static const CGFloat kTopMargin = 15.0;
static const CGFloat kBtnHeight = 24.0;
static const CGFloat kBtnWide = 100.0;
static const CGFloat kBarHeight = 20.0;
static const CGFloat kLineHeight = 18.0;
static const CGFloat kSpace16 = 16.0;
static const CGFloat kSpace8 = 8.0;
static const CGFloat kSpace24 = 24.0;

@implementation ODProgressWindow

- (instancetype)initWithTitle:(NSString *)title
                      message:(NSString *)message
                     packages:(NSArray *)packages
{
  CGFloat contentH = kTopMargin + kLineHeight + kSpace8 + kBarHeight + kSpace16 + kBtnHeight + kBottomMargin;
  CGFloat winH = contentH;

  self = [super initWithContentRect:NSMakeRect(0, 0, kWinWidth, winH)
                          styleMask:NSWindowStyleMaskTitled
                            backing:NSBackingStoreBuffered
                              defer:NO];
  if (!self) return nil;

  [self setTitle:title ?: @"Installing..."];
  [self setLevel:NSModalPanelWindowLevel];

  NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWinWidth, winH)];
  [self setContentView:content];

  CGFloat y = winH - kTopMargin - kLineHeight;

  NSTextField *msgLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(kSideMargin, y, kWinWidth - 2 * kSideMargin, kLineHeight)];
  [msgLabel setStringValue:message ?: @"Installing required packages..."];
  [msgLabel setBezeled:NO];
  [msgLabel setDrawsBackground:NO];
  [msgLabel setEditable:NO];
  [msgLabel setSelectable:NO];
  [msgLabel setFont:[NSFont boldSystemFontOfSize:13]];
  [content addSubview:msgLabel];

  y -= kLineHeight + kSpace8;

  _progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(kSideMargin, y, kWinWidth - 2 * kSideMargin, kBarHeight)];
  [_progressBar setStyle:NSProgressIndicatorBarStyle];
  [_progressBar setIndeterminate:YES];
  [_progressBar startAnimation:nil];
  [content addSubview:_progressBar];

  y -= kBarHeight + kSpace16;

  _cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(kWinWidth - kSideMargin - kBtnWide, y, kBtnWide, kBtnHeight)];
  [_cancelButton setTitle:@"Cancel"];
  [_cancelButton setTarget:self];
  [_cancelButton setAction:@selector(cancelClicked:)];
  [_cancelButton setKeyEquivalent:@"\e"];
  [content addSubview:_cancelButton];

  _cancelled = NO;
  return self;
}

- (BOOL)cancelled
{
  return _cancelled;
}

- (void)cancelClicked:(id)sender
{
  _cancelled = YES;
}

- (void)updateProgress:(float)progress message:(NSString *)message
{
  if ([_progressBar isIndeterminate])
    {
      [_progressBar setIndeterminate:NO];
    }
  [_progressBar setDoubleValue:progress * 100.0];
  [self setStatus:message];
}

- (void)setStatus:(NSString *)status
{
  if (!_statusField)
    {
      CGFloat y = [self frame].size.height - kTopMargin - kLineHeight - kSpace8 - kBarHeight - kSpace16;
      _statusField = [[NSTextField alloc] initWithFrame:NSMakeRect(kSideMargin, y, kWinWidth - 2 * kSideMargin - kBtnWide - kSpace24, kLineHeight)];
      [_statusField setBezeled:NO];
      [_statusField setDrawsBackground:NO];
      [_statusField setEditable:NO];
      [_statusField setSelectable:NO];
      [_statusField setFont:[NSFont systemFontOfSize:11]];
      [_statusField setTextColor:[NSColor secondaryLabelColor]];
      [[self contentView] addSubview:_statusField];
    }
  [_statusField setStringValue:status ?: @""];
}

- (void)showWindow:(id)sender
{
  [self center];
  [self makeKeyAndOrderFront:nil];
  [self display];
  [self flushWindow];
}

@end

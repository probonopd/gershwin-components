/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "EPUBTOCEntry.h"

@protocol TOCPanelDelegate <NSObject>
- (void)tocDidSelectEntry:(EPUBTOCEntry *)entry;
@end

@interface TOCPanelController : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>

@property (nonatomic, weak) id<TOCPanelDelegate> delegate;
@property (nonatomic, strong) NSArray<EPUBTOCEntry *> *toc;

- (void)toggleWithTOC:(NSArray<EPUBTOCEntry *> *)toc relativeToView:(NSView *)view;
- (void)showWithTOC:(NSArray<EPUBTOCEntry *> *)toc relativeToView:(NSView *)view;
- (void)hide;
- (BOOL)isVisible;

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class DUStorageManager;
@class DUOperationLogView;
@class DUStorageObject;
@class DUStorageCapabilities;

// Coordinates the five-tab operation area (SPEC section 8). The controller
// owns the shared operation log and decides tab availability from the
// capabilities of the current selection; it never runs operations itself.
@interface DUOperationController : NSObject

@property (nonatomic, strong, readonly) NSTabView *tabView;
@property (nonatomic, strong, readonly) DUOperationLogView *logView;

- (instancetype)initWithStorageManager:(DUStorageManager *)manager
    NS_DESIGNATED_INITIALIZER;

// Re-evaluates tab and control availability for a new selection. A nil
// object disables every tab.
- (void)refreshForObject:(DUStorageObject *)object
            capabilities:(DUStorageCapabilities *)capabilities;

// The visible first aid / erase / restore panes, so the window controller
// can fan out selection changes without knowing the tab layout.
- (id)firstAidPane;
- (id)erasePane;
- (id)restorePane;

// Replacement hooks for the partition/RAID panes delivered by later waves.
- (void)setPartitionPane:(NSView *)view;
- (void)setRAIDPane:(NSView *)view;

// Global busy state: disables action controls in all panes while any
// storage operation is running.
- (void)setControlsEnabled:(BOOL)enabled;

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class DUOperationLogView;
@class DUStorageManager;
@class DUStorageObject;
@class DUStorageCapabilities;

// Restore pane (SPEC section 21): source/destination picker rows with the
// block-copy action.
@interface DURestoreViewController : NSObject

@property (nonatomic, strong, readonly) NSView *view;

- (instancetype)initWithStorageManager:(DUStorageManager *)manager
                               logView:(DUOperationLogView *)logView
    NS_DESIGNATED_INITIALIZER;

- (void)refreshForObject:(DUStorageObject *)object
            capabilities:(DUStorageCapabilities *)capabilities;

- (void)setControlsEnabled:(BOOL)enabled;

@end

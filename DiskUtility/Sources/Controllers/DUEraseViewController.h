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

// Erase pane (SPEC section 14): name field, format popup, security options
// dialog and the destructive erase action.
@interface DUEraseViewController : NSObject

@property (nonatomic, strong, readonly) NSView *view;

- (instancetype)initWithStorageManager:(DUStorageManager *)manager
                               logView:(DUOperationLogView *)logView
    NS_DESIGNATED_INITIALIZER;

- (void)refreshForObject:(DUStorageObject *)object
            capabilities:(DUStorageCapabilities *)capabilities;

- (void)setControlsEnabled:(BOOL)enabled;

@end

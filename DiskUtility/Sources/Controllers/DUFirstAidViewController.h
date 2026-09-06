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

// First Aid pane (SPEC sections 9-13): instructions, Show details toggle,
// shared operation log and the verify/repair action groups.
@interface DUFirstAidViewController : NSObject

@property (nonatomic, strong, readonly) NSView *view;

- (instancetype)initWithStorageManager:(DUStorageManager *)manager
                               logView:(DUOperationLogView *)logView
    NS_DESIGNATED_INITIALIZER;

- (void)refreshForObject:(DUStorageObject *)object
            capabilities:(DUStorageCapabilities *)capabilities;

- (void)setControlsEnabled:(BOOL)enabled;

@end

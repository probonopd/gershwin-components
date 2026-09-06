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

// Partition pane (SPEC sections 15-19): pending-layout editor over
// DUPartitionLayout with the graphical map, volume info form, +/- controls,
// scheme options dialog and Apply/Revert semantics.
@interface DUPartitionViewController : NSObject

@property (nonatomic, strong, readonly) NSView *view;

- (instancetype)initWithStorageManager:(DUStorageManager *)manager
                                logView:(DUOperationLogView *)logView
    NS_DESIGNATED_INITIALIZER;

- (void)refreshForObject:(DUStorageObject *)object
             capabilities:(DUStorageCapabilities *)capabilities;

- (void)setControlsEnabled:(BOOL)enabled;

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class DUStorageObject;
@class DUStorageManager;

@protocol DUDeviceBrowserDelegate <NSObject>
// Fired for outline selection changes; object may be nil when empty.
- (void)browserSelectionChanged:(DUStorageObject *)object;
// Contextual command requests (SPEC section 33); the window controller
// routes them to the same handlers as the toolbar.
- (void)browserRequestCommand:(NSString *)token
                    forObject:(DUStorageObject *)object;

// Fired when image files are dropped onto the left pane (e.g. from the
// Workspace); the window controller mounts each one so it appears in the
// list, exactly like File > Open Disk Image.
- (void)browserDidDropImageFiles:(NSArray<NSURL *> *)urls;
@end

// Owns the device tree presentation (ARCHITECTURE.md section 39). Reads
// snapshots from the storage manager and reports user intent upward; it
// never talks to backends itself.
@interface DUDeviceBrowserController : NSObject

@property (nonatomic, strong, readonly) NSView *containerView;

@property (nonatomic, weak) id<DUDeviceBrowserDelegate> delegate;

- (instancetype)initWithStorageManager:(DUStorageManager *)manager
    NS_DESIGNATED_INITIALIZER;

// Rebuilds rows from the manager snapshot, preserving expansion state and
// reselecting preferredIdentifier when still present.
- (void)reloadWithPreferredSelection:(NSString *)preferredIdentifier;

// When YES the outline shows only volumes, hiding whole disks and devices
// (View > Show Only Volumes). Reset with View > Show All Devices.
@property (nonatomic, assign) BOOL showOnlyVolumes;

- (DUStorageObject *)selectedObject;

@end

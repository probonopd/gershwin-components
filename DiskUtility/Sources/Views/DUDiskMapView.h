/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class DUPartitionLayout;
@class DUDiskMapView;

// Presentation-only partition map (SPEC sections 16/17, ARCHITECTURE.md
// section 42). The view draws and hit-tests; it never talks to a backend.
@protocol DUDiskMapViewDelegate <NSObject>
@optional
// Sent when the user clicks a partition. The view changes nothing else;
// the controller decides what selection means.
- (void)mapView:(DUDiskMapView *)mapView didSelectPartitionAtIndex:(NSUInteger)index;

// Sent after the user finished a boundary drag that changed partition
// sizes in the layout, so the controller can refresh labels and dirty state.
- (void)mapViewDidChangeLayout:(DUDiskMapView *)mapView;
@end

@interface DUDiskMapView : NSView

@property (nonatomic, weak) id<DUDiskMapViewDelegate> delegate;

// Owned by the view while set; assigning replaces content and resets
// the selection.
@property (nonatomic, strong, readonly) DUPartitionLayout *layout;

// -1 when nothing is selected.
@property (nonatomic, assign) NSInteger selectedPartitionIndex;

// Boundary dragging is only offered when the controller knows the backend
// supports resizing; NO disables it gracefully without touching the model.
@property (nonatomic, assign) BOOL resizingEnabled;

- (instancetype)initWithFrame:(NSRect)frame NS_DESIGNATED_INITIALIZER;

- (void)setLayout:(DUPartitionLayout *)layout;

@end

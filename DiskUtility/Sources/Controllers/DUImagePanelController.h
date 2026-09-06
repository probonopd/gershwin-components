/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class DUOperationLogView;
@class DUStorageManager;
@class DUStorageObject;

// One panel, three toolbar flows that all operate on disk images:
//   convert - rewrite the selected image into another format
//   resize  - grow or shrink the selected image
//   burn    - write an image file onto the selected optical drive
// Non-modal by design: operations run in the background with progress in
// the shared operation log and the main window's status strip
// (ARCHITECTURE.md section 31).
@interface DUImagePanelController : NSObject

typedef NS_ENUM(NSInteger, DUImagePanelMode) {
    DUImagePanelModeConvert = 0,
    DUImagePanelModeResize,
    DUImagePanelModeBurn,
};

NS_ASSUME_NONNULL_BEGIN

- (instancetype)initWithStorageManager:(DUStorageManager *)manager
                                logView:(DUOperationLogView *)logView
    NS_DESIGNATED_INITIALIZER;

// Which flow the panel shows; resets the form. Set before openPanel.
- (void)setMode:(DUImagePanelMode)mode;

/* Convert/resize act on the outline's selected image; burn acts on the
 * selected optical drive. Call whenever the selection changes and before
 * showing the panel - the source control is read-only by design. */
- (void)setSourceObject:(nullable DUStorageObject *)object;

/* Shows the panel for the current mode and source. */
- (void)openPanel;

NS_ASSUME_NONNULL_END

@end

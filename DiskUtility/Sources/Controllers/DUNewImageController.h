/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class DUOperationLogView;
@class DUStorageManager;
@class DUStorageObject;

// New Image dialog (SPEC toolbar "New Image"): pick a source device or
// volume, a destination file and a format, then stream the image with
// progress in the shared operation log.
@interface DUNewImageController : NSObject

- (instancetype)initWithStorageManager:(DUStorageManager *)manager
                               logView:(nonnull DUOperationLogView * _Nonnull)logView
    NS_DESIGNATED_INITIALIZER;

/* The image SOURCE always mirrors the outline's currently selected
 * object; call this whenever the selection changes and before showing
 * the panel. The source control in the panel is read-only by design -
 * a popup of candidates invited imaging the wrong disk. */
- (void)setSourceObject:(nullable DUStorageObject *)object;

/* Shows the panel for the current source. */
- (void)openPanel;

@end

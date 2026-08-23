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
                               logView:(DUOperationLogView *)logView
    NS_DESIGNATED_INITIALIZER;

// Opens the dialog pre-selected to object (may be nil).
- (void)runForObject:(DUStorageObject *)object;

@end

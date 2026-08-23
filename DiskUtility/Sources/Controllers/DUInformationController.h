/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class DUStorageObject;

// Persistent technical-information footer (SPEC sections 22-26). Renders
// the field set matching the selected object's type.
@interface DUInformationController : NSObject

@property (nonatomic, strong, readonly) NSView *view;

- (instancetype)init NS_DESIGNATED_INITIALIZER;

- (void)setObject:(DUStorageObject *)object;

@end

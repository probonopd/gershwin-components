/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

// Bordered, scrollable, read-only diagnostic log (SPEC section 12). All
// methods may be called from any thread; output is marshalled to the main
// thread internally so operation workers can append freely.
@interface DUOperationLogView : NSObject

// The scroll view to embed in a layout; retains the text view inside.
@property (nonatomic, strong, readonly) NSScrollView *scrollView;

- (instancetype)init NS_DESIGNATED_INITIALIZER;

- (void)appendLine:(NSString *)line;
- (void)clear;

@end

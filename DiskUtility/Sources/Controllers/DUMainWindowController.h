/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class DUStorageManager;

// Owns the main window and fans selection changes out to the browser,
// operation area and information panel (SPEC section 30).
@interface DUMainWindowController : NSWindowController

- (instancetype)initWithStorageManager:(DUStorageManager *)manager
    NS_DESIGNATED_INITIALIZER;

@end

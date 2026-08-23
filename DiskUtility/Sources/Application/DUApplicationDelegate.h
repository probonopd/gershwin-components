/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@class DUMainWindowController;
@class DUStorageManager;

// Application lifecycle owner (ARCHITECTURE.md sections 5-6): builds the
// global services, creates the main window controller and coordinates the
// shutdown sequence. Contains no storage logic itself.
@interface DUApplicationDelegate : NSObject

@property (nonatomic, strong, readonly) DUStorageManager *storageManager;
@property (nonatomic, strong, readonly) DUMainWindowController *windowController;

@end

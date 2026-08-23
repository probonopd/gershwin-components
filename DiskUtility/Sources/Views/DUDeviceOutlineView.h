/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

// Hierarchical device browser (SPEC section 6). The subclass exists to hold
// browser-specific presentation defaults; all data flows through the
// DUDeviceBrowserController as delegate/dataSource.
@interface DUDeviceOutlineView : NSOutlineView

@end

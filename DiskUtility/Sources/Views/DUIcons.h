/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

// Shared icon loader. gnustep-make flattens Resources/Icons/*.png into the
// app bundle's resource root on install, so lookups must try the bundle
// root first and only fall back to the source-tree layout when running
// uninstalled from the project directory.
@interface DUIcons : NSObject

// Returns the 16x16-scaled PNG for `name` ("verify", "disk", ...), or nil
// when no such icon exists; callers must cope with nil (capability-gated
// buttons stay text-only rather than crashing).
+ (NSImage *)iconNamed:(NSString *)name;

@end

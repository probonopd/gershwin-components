/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface X11Support : NSObject

// Discovery
+ (NSArray *)windowList;
+ (NSDictionary *)windowInfo:(unsigned long)xid;

// Input Simulation
+ (void)simulateMouseMoveTo:(NSPoint)point;
+ (void)simulateClick:(int)button; // 1=left, 2=middle, 3=right
+ (void)simulateKeyStroke:(NSString *)keyString;

// Press button 1 at the current pointer position and drag by the given pixel
// offset, releasing over the end position (moving windows, sliders,
// scrollbars, drag-and-drop).
+ (void)simulateDragBy:(NSPoint)delta;

// Emit `count` wheel steps at the current pointer position.  direction is one
// of "up"/"down"/"left"/"right" (X buttons 4/5/6/7).
+ (void)simulateScrollWheel:(NSString *)direction count:(int)count;

// Raise + focus a window so subsequent keyboard input is delivered to it rather
// than an occluding window. Needed because the desktop usually has overlapping
// windows.
+ (void)activateWindow:(unsigned long)xid;

// Send a single key with zero or more modifiers held (e.g. Control+c, or just
// Return) — for shortcuts and menu accelerators that plain text typing cannot
// express. Modifier names: "control"/"ctrl", "alt"/"meta", "shift",
// "super"/"win". The key is either a single character or an X keysym name such
// as "Return", "Left" or "F5".
+ (void)simulateChordWithModifiers:(NSArray *)modifiers key:(NSString *)key;

@end

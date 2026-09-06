/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Registers application defaults and provides typed accessors for the
// preference keys listed in ARCHITECTURE.md section 67.
@interface DUPreferencesController : NSObject

+ (void)registerDefaults;

+ (BOOL)showDetails;
+ (BOOL)confirmDestructiveOperations;
+ (NSTimeInterval)refreshInterval;

@end

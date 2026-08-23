/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Resolves command+section to a man page file URL without invoking
 * the `man` binary (SPEC 18/19). Layout-agnostic across the standard
 * man trees. */
@interface GSHelpManLocator : NSObject

/* MANPATH entries first (order preserved), then the standard system,
 * local and legacy trees; the GNUstep documentation man dir is added
 * when GNUSTEP_SYSTEM_ROOT is set. */
+ (NSArray<NSString *> *)defaultSearchPaths;

/* Exact <name>.<section> wins, then suffixed variants (<name>.3x for
 * section 3, including compression suffixes); the matching manN dir
 * is preferred over other man dirs. nil when not found. A nil
 * section falls back to any-section lookup. */
+ (nullable NSURL *)locateManPageWithCommand:
                                     (nullable NSString *)command
                                     section:(nullable NSString *)section
                                 searchPaths:
                                     (NSArray<NSString *> *)searchPaths;

@end

NS_ASSUME_NONNULL_END

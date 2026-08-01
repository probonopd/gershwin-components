/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/* Reads the top-level contents of Type-2 AppImage files (an ELF runtime
 * followed by a SquashFS image) using libsquashfs.  Used by make_services to
 * register AppImage applications from the *.desktop file inside them. */
@interface AppImageReader : NSObject

/* Whether the file looks like a Type-2 AppImage (ELF magic + "AI\x02"). */
+ (BOOL)looksLikeAppImage:(NSString *)path;

/* Returns a dictionary mapping top-level regular file names to their NSData
 * contents.  Files larger than maxSize bytes and directories are skipped. */
+ (NSDictionary *)topLevelFilesInAppImage:(NSString *)path
                                  maxSize:(NSUInteger)maxSize;

@end

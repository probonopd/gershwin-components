/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Image format identifiers returned by +imageFormatAtPath:.
extern NSString *const kDUImageFormatRaw;
extern NSString *const kDUImageFormatQCow2;
extern NSString *const kDUImageFormatVMDK;
extern NSString *const kDUImageFormatVDI;

// Foundation-only image file helpers shared by operations and backends.
@interface DUImageService : NSObject

// Creates a sparse image file of exactly sizeBytes (truncate-style). An
// existing file at path is truncated to sizeBytes; returns NO with *error
// set on any failure.
+ (BOOL)createImageAtPath:(NSString *)path
                sizeBytes:(unsigned long long)sizeBytes
                    error:(NSError **)error;

// Sniffs the magic bytes of common image containers; kDUImageFormatRaw when
// nothing matches.
+ (NSString *)imageFormatAtPath:(NSString *)path;

@end

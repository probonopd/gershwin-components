/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Decompresses a single compressed stream on the fly using libarchive.
// Producer-consumer pattern: feed compressed data in, get decompressed data out.
@interface CLMArchiveExtractor : NSObject

@property (nonatomic, copy) void (^outputHandler)(NSData *decompressedData);
@property (nonatomic, copy) void (^completionHandler)(NSError *_Nullable error);

// Uncompressed size of the file being extracted, once known. For zip entries
// this is the uncompressed size of the image; for raw single-stream archives
// (gz/xz) it stays 0 because the decompressed size is unknown in advance.
// Note: zips written with data descriptors (local header size 0) report 0
// here; use scanImageSizeInArchiveFile: to get the real size for local files.
@property (nonatomic, assign, readonly) int64_t expectedOutputSize;

// Returns the uncompressed size of the image (.iso/.img) entry in a zip file,
// by opening it seekable so the central directory (with the real sizes) can be
// read. Returns 0 if not a zip or no image entry found.
+ (int64_t)scanImageSizeInArchiveFile:(NSString *)path;

- (instancetype)init;
- (void)startExtracting;
- (void)feedCompressedData:(NSData *)data;
- (void)finish;
- (void)cancel;

@end

NS_ASSUME_NONNULL_END

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOperation.h"

#import "DUStorageBackend.h"

// Verb tokens for DUImageOperation; reuse of the backend operation tokens is
// deliberate so UI menus and operations share one vocabulary.
extern NSString *const kDUImageVerbCreate;
extern NSString *const kDUImageVerbConvert;
extern NSString *const kDUImageVerbResize;

// Options-dictionary keys.
extern NSString *const kDUImageSizeBytesKey;   // NSNumber (unsigned long long)
extern NSString *const kDUImageOutputPathKey;  // NSString, convert target file
extern NSString *const kDUImageFormatKey;      // NSString, e.g. @"qcow2", @"raw"

// Create/convert/resize a disk image file. Creation uses DUImageService;
// conversion and resizing shell out to qemu-img when installed and fail hard
// with an UnsupportedOperation error when it is not.
@interface DUImageOperation : DUOperation

@property (nonatomic, copy, readonly) NSString *imagePath;
@property (nonatomic, copy, readonly) NSString *verb;
@property (nonatomic, copy, readonly) NSDictionary *options;

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                       imagePath:(NSString *)imagePath
                            verb:(NSString *)verb
                         options:(NSDictionary *)options;

@end

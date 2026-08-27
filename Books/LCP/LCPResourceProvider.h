/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "LCPLicense.h"

/* Generic resource access for a publication (spec 8). The renderer keeps
 * calling dataForResource: without knowing whether the bytes come straight
 * from the container or were decrypted on the fly by LCP. */
@protocol PublicationResourceProvider <NSObject>

- (BOOL) isEncrypted:(NSString *)relativePath;
- (NSData *) dataForResource:(NSString *)relativePath error:(NSError **)error;

@end

/* Reads resources directly from a directory (the extracted EPUB root). */
@interface NormalEPUBResourceProvider : NSObject <PublicationResourceProvider>
- (instancetype) initWithBasePath:(NSString *)basePath;
@end

/* Wraps another provider; decrypts the resources listed in `encryptedPaths`
 * using the recovered content key (spec 9). */
@interface LCPEPUBResourceProvider : NSObject <PublicationResourceProvider>
- (instancetype) initWithBaseProvider:(id<PublicationResourceProvider>)base
                              license:(LCPLicense *)license
                          contentKey:(NSData *)contentKey
                              backend:(id)backend; /* id<LCPClientBackend> */
- (void) setEncryptedPaths:(NSSet<NSString *> *)encryptedPaths;
@end

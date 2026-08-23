/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Incremental SHA-256 (FIPS 180-4) for copy/verify checksums. Self-contained
// so every supported platform gets identical digests without an external
// crypto dependency; correctness is pinned by NIST vectors in t_SHA256.
@interface DUSHA256 : NSObject

- (instancetype)init;

// Feeds bytes into the running digest; call as many times as needed.
- (void)updateWithBytes:(const void *)bytes length:(NSUInteger)length;
- (void)updateWithData:(NSData *)data;

// Finishes the digest and returns the lowercase hex string. The instance
// is consumed by this call; create a fresh one for the next digest.
- (NSString *)finalHex;

@end

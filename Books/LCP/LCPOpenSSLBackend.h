/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "LCPClientBackend.h"

/* OpenSSL-backed implementation of the Basic/Test LCP profile crypto. */
@interface LCPOpenSSLBackend : NSObject <LCPClientBackend>

/* The following are implementation/test helpers for minting synthetic
 * licenses and encrypted resources (the reading system only ever decrypts). */
+ (NSData *) keyCheckForLicenseID:(NSString *)licenseID userKey:(NSData *)userKey;
+ (NSData *) encryptedContentKey:(NSData *)contentKey userKey:(NSData *)userKey;
+ (NSData *) encryptedResource:(NSData *)plaintext contentKey:(NSData *)contentKey;

@end

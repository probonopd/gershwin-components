/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "LCPLicense.h"

/* Cryptographic backend abstraction (spec section 11).
 * The rest of the application talks only to this protocol, so a production
 * EDRLab backend can later replace the OpenSSL/Test backend without touching
 * the reader. */
@protocol LCPClientBackend <NSObject>

/* User Key = SHA-256(UTF-8(passphrase)), 32 bytes (spec 4.2). */
- (NSData *) userKeyFromPassphrase:(NSString *)passphrase;

/* Verify the passphrase by decrypting user_key.key_check and comparing it to
 * the license id (spec 3.4). */
- (BOOL) verifyPassphrase:(NSString *)passphrase
                forLicense:(LCPLicense *)license;

/* Decrypt the content key (spec 3.4): AES-256-CBC, IV prepended, W3C padding. */
- (NSData *) decryptContentKeyFromLicense:(LCPLicense *)license
                                  userKey:(NSData *)userKey
                                    error:(NSError **)error;

/* Decrypt a single publication resource (spec 2.2): AES-256-CBC, IV
 * prepended, W3C padding. The ciphertext is the raw bytes stored in the
 * container (IV || encrypted octets). */
- (NSData *) decryptResource:(NSData *)ciphertext
                  contentKey:(NSData *)contentKey
                       error:(NSError **)error;

@end

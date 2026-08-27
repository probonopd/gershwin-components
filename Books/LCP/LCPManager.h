/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "LCPLicense.h"
#import "LCPClientBackend.h"
#import "LCPResourceProvider.h"

/* LCPManager is the single point the application talks to (spec 2).
 * It isolates all LCP knowledge behind a small API. */
@interface LCPManager : NSObject

- (instancetype) initWithBackend:(id<LCPClientBackend>)backend;

/* Parse and validate a .lcpl document. */
- (LCPLicense *) importLicense:(NSData *)json error:(NSError **)error;

/* Hint shown in the unlock dialog (spec 12). */
- (NSString *) passphraseHint;

/* Verify the passphrase, recover the content key. Returns NO on failure. */
- (BOOL) unlockWithPassphrase:(NSString *)passphrase error:(NSError **)error;

/* YES until unlockWithPassphrase succeeds. */
- (BOOL) isLocked;

/* After unlock, wire the resource provider that the reader will use. */
- (void) setResourceProvider:(id<PublicationResourceProvider>)provider
              encryptedPaths:(NSSet<NSString *> *)encryptedPaths;

/* Decrypted bytes for a publication resource (spec 9). */
- (NSData *) resourceForPath:(NSString *)relativePath error:(NSError **)error;

/* The recovered content key (nil while locked). Lets a host resource
 * layer (e.g. EPUBBook) decrypt individual resources itself. */
- (NSData *) contentKey;

/* Decrypt a single resource's ciphertext (IV prepended, W3C padding) using
 * the recovered content key. */
- (NSData *) decryptResource:(NSData *)ciphertext error:(NSError **)error;

@end

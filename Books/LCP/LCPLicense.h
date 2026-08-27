/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "LCPError.h"

/* In-memory model of an LCP license document (.lcpl).
 * Parses and structurally validates the JSON; cryptographic operations
 * (passphrase check, content key recovery) live in LCPClientBackend. */
@interface LCPLicense : NSObject

@property (nonatomic, copy, readonly) NSString *licenseID;
@property (nonatomic, copy, readonly) NSString *issued;
@property (nonatomic, copy, readonly) NSString *updated;
@property (nonatomic, copy, readonly) NSString *provider;

@property (nonatomic, copy, readonly) NSString *profile;
@property (nonatomic, copy, readonly) NSData   *contentKeyEncryptedValue;
@property (nonatomic, copy, readonly) NSString *contentKeyAlgorithm;
@property (nonatomic, copy, readonly) NSString *userKeyAlgorithm;
@property (nonatomic, copy, readonly) NSString *userKeyTextHint;
@property (nonatomic, copy, readonly) NSData   *userKeyKeyCheck;

@property (nonatomic, copy, readonly) NSArray  *links;
@property (nonatomic, copy, readonly) NSDictionary *rights;
@property (nonatomic, copy, readonly) NSDictionary *user;
@property (nonatomic, copy, readonly) NSDictionary *signature;

/* Parse JSON and run structural validation. Returns nil on error. */
+ (instancetype) licenseWithJSON:(NSData *)json error:(NSError **)error;

/* Validate required fields and supported algorithms. */
- (BOOL) validate:(NSError **)error;

/* Convenience: the publication download link (rel="publication"), if any. */
- (NSString *) publicationLink;

@end

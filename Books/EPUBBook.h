/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "EPUBTOCEntry.h"

@interface EPUBBook : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *author;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, copy) NSString *publisher;
@property (nonatomic, copy) NSString *coverPath;
// EPUB RS 3.3, 5.5: nil means the reading system MUST assume "default".
@property (nonatomic, copy) NSString *pageProgressionDirection;
@property (nonatomic, copy) NSArray<NSString *> *spine;
@property (nonatomic, copy) NSArray<EPUBTOCEntry *> *tableOfContents;
@property (nonatomic, copy, readonly) NSString *extractedRoot;

// LCP (Readium Licensed Content Protection). The book is LCP-protected when
// the container holds META-INF/license.lcpl. Until unlocked, encrypted
// resources cannot be read; the renderer stays unaware of LCP and simply
// asks the book for (decrypted) content paths.
@property (nonatomic, readonly) BOOL lcpProtected;
- (NSString *)lcpPassphraseHint;
- (BOOL)lcpUnlockWithPassphrase:(NSString *)passphrase error:(NSError **)error;

- (instancetype)initWithEPUBAtPath:(NSString *)epubPath error:(NSError **)error;
- (NSString *)absolutePathForContent:(NSString *)relativePath;
// Returns a path to the (decrypted, when LCP-encrypted) content for any
// relative or absolute path. Decrypts on demand into the temp extract dir
// and caches the result; the original EPUB on disk is never decrypted.
- (NSString *)materializedPathForPath:(NSString *)anyPath error:(NSError **)error;
- (void)cleanupExtraction;

@end

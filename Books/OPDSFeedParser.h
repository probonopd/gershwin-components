/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "OPDSEntry.h"

// Fetches and parses an OPDS catalog feed. The work runs on a background
// queue; the completion block is delivered on the main queue.
@interface OPDSFeedParser : NSObject

- (void)fetchFeedAtURL:(NSURL *)url
             searchFor:(NSString *)query
            completion:(void (^)(NSArray<OPDSEntry *> *entries,
                                 NSString *feedTitle,
                                 NSError *error))completion;

// Resolve EPUB download URLs for entries that only have a subsection link.
// Entries without a subsection link or EPUB are removed from the result.
// completion is called on the main queue.
- (void)resolveEPUBLinksForEntries:(NSArray<OPDSEntry *> *)entries
                        completion:(void (^)(NSArray<OPDSEntry *> *resolved))completion;

// Download an EPUB to a temporary file and return its path via the main queue.
- (void)downloadEPUBAtURL:(NSURL *)url
               completion:(void (^)(NSString *path, NSError *error))completion;

@end

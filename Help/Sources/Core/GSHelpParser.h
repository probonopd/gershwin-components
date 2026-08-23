/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class GSHelpDocument;

/* Common parser interface (SPEC 9). Parsers turn a source URL into a
 * normalized GSHelpDocument. Malformed sources must yield nil plus an
 * error, never an exception escaping the call. */
@protocol GSHelpParser <NSObject>

- (BOOL)canParseURL:(NSURL *)url;

- (nullable GSHelpDocument *)parseURL:(NSURL *)url
                                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

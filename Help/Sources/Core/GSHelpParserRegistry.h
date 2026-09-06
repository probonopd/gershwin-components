/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#import "GSHelpParser.h"

NS_ASSUME_NONNULL_BEGIN

/* Orders parsers by registration; parserForURL: returns the first
 * parser whose canParseURL: accepts the URL (SPEC 9). */
@interface GSHelpParserRegistry : NSObject

/* Registers parser at the end of the lookup order. Duplicate
 * registrations are ignored. */
- (void)registerParser:(id<GSHelpParser>)parser;

/* Removes every registration of parser; no-op if not registered. */
- (void)unregisterParser:(id<GSHelpParser>)parser;

/* First registered parser accepting url, in registration order;
 * nil if none does. A nil URL is simply offered to the parsers. */
- (nullable id<GSHelpParser>)parserForURL:(nullable NSURL *)url;

/* Current parsers, in registration order. */
@property (nonatomic, readonly) NSArray<id<GSHelpParser>> *parsers;

@end

NS_ASSUME_NONNULL_END

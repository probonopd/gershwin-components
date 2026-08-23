/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#import "GSHelpParser.h"

NS_ASSUME_NONNULL_BEGIN

/* Parses Unix man pages (roff source) into normalized documents
 * (SPEC 18-24). Reads the page source directly and never invokes
 * man(1). Transparently decompresses .gz/.bz2/.xz pages when the
 * matching library was available at build time; unsupported codecs
 * surface as parse errors. Malformed roff degrades to plain text,
 * never raises. */
@interface GSManParser : NSObject <GSHelpParser>
@end

NS_ASSUME_NONNULL_END

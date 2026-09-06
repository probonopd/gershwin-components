/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#import "GSHelpParser.h"

NS_ASSUME_NONNULL_BEGIN

/* Plain-text fallback parser (SPEC 51). Groups blank-line-separated
 * blocks into paragraphs, switches to a single code block for
 * monospaced terminal-style content, and turns high-confidence man
 * references (word(N) standalone or at end of line) into help://man/
 * links. Registered last in the parser registry: it accepts any URL. */
@interface GSTextParser : NSObject <GSHelpParser>
@end

NS_ASSUME_NONNULL_END

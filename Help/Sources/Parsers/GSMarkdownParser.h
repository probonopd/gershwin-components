/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#import "GSHelpParser.h"

NS_ASSUME_NONNULL_BEGIN

/* Parses Markdown documents into normalized documents (SPEC 11-13).
 * Dialect: ATX headings (#..######, clamped to level 4 per SPEC 16),
 * paragraphs, fenced code blocks, 4-space indented code blocks,
 * unordered/ordered lists nested by indentation, nested blockquotes,
 * pipe tables with an alignment separator row, horizontal rules,
 * inline emphasis/strong/code/links/images, backslash escapes and the
 * &amp; &lt; &gt; &quot; entity refs.
 *
 * Representation choices:
 * - Horizontal rules become a GSHelpParagraph holding a single plain
 *   GSHelpText "---"; the renderer draws that as a rule. This keeps
 *   rules visible in every consumer without adding a node class.
 * - Every ATX heading emits an implicit GSHelpAnchor immediately
 *   before it (name derived GitHub-style from the heading text), so
 *   "#anchor" links resolve through the document's anchor map.
 * - Setext underlines (=== / ---) are NOT supported: they collide
 *   with horizontal rules and table separators in this dialect.
 * - Table alignment metadata is dropped: the document model has no
 *   cell-alignment property yet.
 * - Images are produced only for local paths; remote references
 *   degrade to their alt text run (SPEC 49).
 * Malformed input never raises: unterminated fences close at EOF,
 * broken tables stay paragraphs, unknown markup stays literal. */
@interface GSMarkdownParser : NSObject <GSHelpParser>
@end

NS_ASSUME_NONNULL_END

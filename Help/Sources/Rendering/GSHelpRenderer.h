/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

#import "GSHelpDocument.h"

NS_ASSUME_NONNULL_BEGIN

/* Turns a normalized GSHelpDocument into laid-out native content
 * (SPEC 33/34). Consumes only the core model - never any format-
 * specific logic - so Markdown, man and GSdoc share one appearance.
 *
 * The output is a single attributed string suitable for one
 * NSTextView: headings sized by level, inline styles, boxed
 * monospaced code, indented lists, aligned monospace tables, local
 * images as text attachments and links tagged with
 * NSLinkAttributeName for click interception. Fonts/colors come from
 * the user defaults via NSFont user APIs and system colors. */
@interface GSHelpRenderer : NSObject

/* Full document body. */
- (NSAttributedString *)renderedStringForDocument:
    (GSHelpDocument *)document;

/* Character range of the first heading whose text matches, or
 * (NSNotFound, 0) when absent. Used by the sidebar to scroll the
 * document view to the selected entry. */
- (NSRange)rangeOfHeadingText:(nullable NSString *)text;

@end

NS_ASSUME_NONNULL_END

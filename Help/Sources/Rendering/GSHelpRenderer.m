/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSHelpRenderer.h"

#import "GSHelpURL.h"
#import "GSHelpManLocator.h"

#ifdef GS_HAVE_CURL
#include <curl/curl.h>
#endif

/* Layout metrics. Spacing values follow the 2px multiples of the
 * Gershwin AppearanceMetrics house style; sizes are relative to the
 * user's default font size so nothing is hard-coded absolutely. */
static const CGFloat kBlockGap = 10.0;
static const CGFloat kListGap = 3.0;
static const CGFloat kLineSpacing = 4.0;
static const CGFloat kHeadingSpaceBefore = 16.0;
static const CGFloat kHeadingSpaceAfter = 10.0;
static const CGFloat kIndentStep = 18.0;
static const CGFloat kCodeInset = 10.0;
static const CGFloat kMaxImageWidth = 420.0;

#pragma mark - Image attachment cell

/* Draws the loaded NSImage inside the text flow; the stock
 * NSTextAttachmentCell has no image drawing of its own and, on GNUstep,
 * its -image/-setImage: pair is not reliably consulted after an async
 * swap, so we keep our own image reference. */
@interface GSHelpImageAttachmentCell : NSTextAttachmentCell
@end

@implementation GSHelpImageAttachmentCell
{
    NSImage *_helpImage;
}

- (instancetype)initImageCell:(NSImage *)image
{
    self = [super initImageCell: image];
    if (self != nil)
      {
        _helpImage = image;
      }
    return self;
}

- (NSImage *)image
{
    return _helpImage;
}

- (void)setImage:(NSImage *)image
{
    _helpImage = image;
}

- (NSSize)cellSize
{
    return [_helpImage size];
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
    if (_helpImage != nil)
      {
        /* The text view is a flipped coordinate system (origin
         * top-left). An NSImage is drawn bottom-up, so compositing it
         * straight into the cell leaves the picture/markdown table
         * upside-down. Flip the local coordinate system once so the
         * image is drawn upright. */
        [NSGraphicsContext saveGraphicsState];
        NSAffineTransform *flip = [NSAffineTransform transform];
        [flip translateXBy: 0.0 yBy: NSMaxY(cellFrame)];
        [flip scaleXBy: 1.0 yBy: -1.0];
        [flip translateXBy: 0.0 yBy: -NSMinY(cellFrame)];
        [flip concat];
        [_helpImage drawInRect: cellFrame
                      fromRect: NSZeroRect
                     operation: NSCompositeSourceOver
                      fraction: 1.0];
        [NSGraphicsContext restoreGraphicsState];
      }
}

@end

#pragma mark - Renderer

@implementation GSHelpRenderer
{
    NSMutableDictionary<NSString *, NSValue *> *_headingRanges;
    CGFloat _userSize;
    GSHelpDocument *_document;
    /* GNUstep's typesetter ignores paragraphSpacing (both before and
     * after), so block gaps cannot be expressed through paragraph styles.
     * Instead every gap is a real blank line whose line height is pinned
     * to the desired gap via maximumLineHeight/minimumLineHeight. These
     * track the gap that should precede the NEXT block and whether the
     * very first block has been emitted yet. */
    BOOL _firstBlock;
    CGFloat _lastAfter;
}

- (instancetype)init
{
    self = [super init];
    if (self != nil)
      {
        /* Size 0 asks for the user's configured default size, so all
         * derived heading/code sizes stay proportional to it. */
        _userSize = [[NSFont userFontOfSize: 0] pointSize];
        _headingRanges = [NSMutableDictionary new];
        _firstBlock = YES;
        _lastAfter = 0.0;
      }
    return self;
}

- (NSAttributedString *)renderedStringForDocument:(GSHelpDocument *)document
{
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    _document = document;

    if ([document rootNode] != nil)
      {
        for (GSHelpNode *node in [[document rootNode] children])
          {
            [self appendBlockNode: node toString: out indent: 0];
          }
      }
    return out;
}

- (NSRange)rangeOfHeadingText:(NSString *)text
{
    NSValue *value = _headingRanges[text];
    if (value == nil)
      {
        return NSMakeRange(NSNotFound, 0);
      }
    return [value rangeValue];
}

#pragma mark Fonts

- (NSFont *)bodyFont
{
    return [NSFont userFontOfSize: _userSize];
}

/* Heuristic: does this font face name look monospaced? GNUstep's
 * -isFixedPitch is unreliable, so we match the face name instead. */
- (BOOL)fontLooksMonospaced:(NSFont *)font
{
    if (font == nil)
      {
        return NO;
      }
    NSString *u = [[[font fontName] uppercaseString]
        stringByReplacingOccurrencesOfString: @" " withString: @""];
    return ([u containsString: @"MONO"]
            || [u containsString: @"COURIER"]
            || [u containsString: @"TERMINUS"]
            || [u containsString: @"CONSOLAS"]
            || [u containsString: @"FREEMONO"]
            || [u containsString: @"FIXED"]
            || [u containsString: @"TYPEWRITER"]
            || [u containsString: @"LIBERATION"]
            || [u containsString: @"SOURCECODEPRO"]);
}

/* Returns the best monospaced face name whose (space-stripped, upper-cased)
 * name contains `hint` (or any known monospace hint when `hint` is nil),
 * preferring a regular/medium/book weight. */
- (NSString *)bestMonoFaceNameForHint:(nullable NSString *)hint
{
    NSArray<NSString *> *hints =
        hint != nil
            ? @[ [[hint uppercaseString]
                    stringByReplacingOccurrencesOfString: @" "
                                              withString: @""] ]
            : @[ @"MONO", @"COURIER", @"TERMINUS", @"CONSOLAS",
                  @"FREEMONO", @"FIXED", @"TYPEWRITER", @"LIBERATION",
                  @"SOURCECODEPRO" ];
    NSString *best = nil;
    for (NSString *name in
             [[NSFontManager sharedFontManager] availableFonts])
      {
        NSString *u = [[[name uppercaseString]
            stringByReplacingOccurrencesOfString: @" " withString: @""]
            stringByReplacingOccurrencesOfString: @"-"
                                      withString: @""];
        for (NSString *h in hints)
          {
            if ([u containsString: h])
              {
                if (best == nil)
                  {
                    best = name;
                  }
                if ([u containsString: @"REGULAR"]
                    || [u containsString: @"MEDIUM"]
                    || [u containsString: @"BOOK"]
                    || [u containsString: @"ROMAN"])
                  {
                    return name;
                  }
              }
          }
      }
    return best;
}

/* The system's fixed-pitch (monospaced) font for code blocks and tables.
 * GNUstep may "resolve" -userFixedPitchFontOfSize: to a proportional
 * substitute (e.g. when Courier is missing) without returning nil, so we
 * only trust it when the resolved face actually looks monospaced. Otherwise
 * we prefer "Source Code Pro" when installed, then any other monospaced
 * face, so code never renders in a proportional face. */
- (NSFont *)monoFont
{
    NSFont *font = [NSFont userFixedPitchFontOfSize: _userSize];
    if ([self fontLooksMonospaced: font])
      {
        return font;
      }
    NSString *name = [self bestMonoFaceNameForHint: @"Source Code Pro"];
    if (name == nil)
      {
        name = [self bestMonoFaceNameForHint: nil];
      }
    if (name != nil)
      {
        font = [NSFont fontWithName: name size: _userSize];
      }
    if (![self fontLooksMonospaced: font])
      {
        font = [self bodyFont];
      }
    return font;
}

- (NSFont *)headingFontForLevel:(NSUInteger)level
{
    /* Relative scale per level; level is already clamped 1...4.
     * GNUstep's NSFont has no userBoldOfSize:, so derive boldness
     * through the shared font manager instead. */
    static const CGFloat factors[4] = { 1.7, 1.4, 1.2, 1.05 };
    return [[NSFontManager sharedFontManager]
        convertFont: [NSFont userFontOfSize: _userSize * factors[level - 1]]
           toHaveTrait: NSBoldFontMask];
}

- (NSFont *)runFontForStyle:(GSHelpTextStyle)style base:(NSFont *)base
{
    NSFontManager *fm = [NSFontManager sharedFontManager];
    NSFont *font = base;

    if (style & GSHelpTextStyleCode)
      {
        font = [NSFont userFixedPitchFontOfSize: [font pointSize]];
      }
    if (style & GSHelpTextStyleBold)
      {
        font = [fm convertFont: font toHaveTrait: NSBoldFontMask];
      }
    if (style & GSHelpTextStyleItalic)
      {
        font = [fm convertFont: font toHaveTrait: NSItalicFontMask];
      }
    return font;
}

#pragma mark Paragraph styles

- (NSParagraphStyle *)bodyStyleIndent:(NSUInteger)indent
                           spaceBefore:(CGFloat)before
                                  mono:(BOOL)mono
{
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    CGFloat left = indent * kIndentStep;

    style.headIndent = left;
    style.firstLineHeadIndent = left;
    if (mono)
      {
        /* Box the code in from both edges so the background forms a
         * visible block instead of full-width stripes. */
        style.headIndent = left + kCodeInset;
        style.tailIndent = -kCodeInset;
      }
    else
      {
        style.tailIndent = 0.0;
      }
    /* lineSpacing is honoured by GNUstep and keeps wrapped lines from
     * touching. Block-to-block gaps are real pinned-height blank lines
     * (see -beginBlockSpaceBefore:/-appendGapLine:), because GNUstep's
     * typesetter ignores paragraphSpacing entirely. */
    style.lineSpacing = kLineSpacing;
    style.paragraphSpacing = 0.0;
    style.lineBreakMode = NSLineBreakByWordWrapping;
    return style;
}

- (NSParagraphStyle *)headingStyleForLevel:(NSUInteger)level
{
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineSpacing = kLineSpacing;
    style.paragraphSpacing = 0.0;
    style.lineBreakMode = NSLineBreakByWordWrapping;
    return style;
}

#pragma mark Block rendering

- (void)appendBlockNode:(GSHelpNode *)node
               toString:(NSMutableAttributedString *)out
                 indent:(NSUInteger)indent
{
    if ([node isKindOfClass:[GSHelpSection class]])
      {
        for (GSHelpNode *child in [node children])
          {
            [self appendBlockNode: child toString: out indent: indent];
          }
      }
    else if ([node isKindOfClass:[GSHelpHeading class]])
      {
        [self appendHeading: (GSHelpHeading *)node toString: out];
      }
    else if ([node isKindOfClass:[GSHelpParagraph class]])
      {
        [self beginBlockSpaceBefore: kBlockGap toString: out];
        NSUInteger start = [out length];
        [self appendInlineChildren: [node children]
                            toString: out
                                font: [self bodyFont]
                               indent: indent];
        [self closeBlock: out from: start
          withParagraphStyle: [self bodyStyleIndent: indent spaceBefore: 0 mono: NO]];
        [self endBlockSpaceAfter: kBlockGap];
      }
    else if ([node isKindOfClass:[GSHelpCodeBlock class]])
      {
        [self appendCodeBlock: (GSHelpCodeBlock *)node toString: out indent: indent];
      }
    else if ([node isKindOfClass:[GSHelpList class]])
      {
        [self appendList: (GSHelpList *)node toString: out indent: indent];
      }
    else if ([node isKindOfClass:[GSHelpTable class]])
      {
        [self appendTable: (GSHelpTable *)node toString: out indent: indent];
      }
    else if ([node isKindOfClass:[GSHelpQuote class]])
      {
        /* Quotes are indented one step; no color tricks needed. */
        for (GSHelpNode *child in [node children])
          {
            [self appendBlockNode: child toString: out indent: indent + 1];
          }
      }
    else if ([node isKindOfClass:[GSHelpImage class]])
      {
        [self appendImage: (GSHelpImage *)node toString: out indent: indent];
      }
    else if ([node isKindOfClass:[GSHelpLink class]])
      {
        [self beginBlockSpaceBefore: kBlockGap toString: out];
        NSUInteger start = [out length];
        [self appendInlineNode: node toString: out font: [self bodyFont]];
        [self closeBlock: out from: start
          withParagraphStyle: [self bodyStyleIndent: indent spaceBefore: 0 mono: NO]];
        [self endBlockSpaceAfter: kBlockGap];
      }
    else if ([node isKindOfClass:[GSHelpAnchor class]])
      {
        /* Invisible by design; resolvable through document anchors. */
      }
}

/* Pinned-height blank line used as a real, typesetter-honoured gap
 * between blocks (GNUstep ignores paragraphSpacing). */
- (void)appendGapLine:(CGFloat)height
             toString:(NSMutableAttributedString *)out
{
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.maximumLineHeight = height;
    ps.minimumLineHeight = height;
    ps.lineSpacing = 0.0;
    ps.lineBreakMode = NSLineBreakByWordWrapping;
    [out appendAttributedString:
        [[NSAttributedString alloc] initWithString: @"\n"
                                        attributes: @{
            NSFontAttributeName: [self bodyFont],
            NSParagraphStyleAttributeName: ps }]];
}

/* Called at the start of every block. Inserts the gap that should sit
 * between the previous block and this one: max(previous block's trailing
 * gap, this block's leading gap). The very first block gets no leading
 * gap. */
- (void)beginBlockSpaceBefore:(CGFloat)before
                     toString:(NSMutableAttributedString *)out
{
    if (_firstBlock)
      {
        _firstBlock = NO;
        _lastAfter = 0.0;
        return;
      }
    CGFloat gap = MAX(_lastAfter, before);
    if (gap > 0.0)
      {
        [self appendGapLine: gap toString: out];
      }
    _lastAfter = 0.0;
}

/* Called at the end of every block, recording the gap this block wants
 * beneath it so the next block's -beginBlockSpaceBefore: can combine it
 * with its own leading gap. */
- (void)endBlockSpaceAfter:(CGFloat)after
{
    _lastAfter = after;
}

/* Closes a block: appends the paragraph-breaking newline carrying the
 * block's base style (font, indent, line spacing) and applies that style
 * across the whole block. The inter-block gap itself is a separate,
 * pinned-height blank line emitted by -beginBlockSpaceBefore:/-endBlock. */
- (void)closeBlock:(NSMutableAttributedString *)out
              from:(NSUInteger)start
  withParagraphStyle:(NSParagraphStyle *)baseStyle
{
    NSMutableParagraphStyle *style = [baseStyle mutableCopy];
    style.paragraphSpacing = 0.0;
    style.paragraphSpacingBefore = 0.0;
    [out appendAttributedString:
        [[NSAttributedString alloc] initWithString: @"\n"
                                        attributes: @{ NSParagraphStyleAttributeName: style }]];
    [out addAttribute: NSParagraphStyleAttributeName
                value: style
                range: NSMakeRange(start, [out length] - start)];
}

- (void)appendHeading:(GSHelpHeading *)heading
             toString:(NSMutableAttributedString *)out
{
    NSString *text = GSHelpTitleCased([heading text]);
    if ([text length] == 0)
      {
        return;
      }

    NSUInteger level = [heading level];
    if (level < 1 || level > 4)
      {
        level = 1;
      }

    NSRange range = NSMakeRange([out length], [text length]);
    /* First heading wins so the sidebar always scrolls somewhere sane. */
    if (_headingRanges[text] == nil)
      {
        _headingRanges[text] = [NSValue valueWithRange: range];
      }

    /* The gap above a heading is a real pinned-height blank line. */
    [self beginBlockSpaceBefore: kHeadingSpaceBefore toString: out];

    NSUInteger start = [out length];
    NSDictionary *attrs = @{
        NSFontAttributeName: [self headingFontForLevel: level],
        NSParagraphStyleAttributeName: [self headingStyleForLevel: level],
    };
    [out appendAttributedString:
        [[NSAttributedString alloc] initWithString: text attributes: attrs]];

    [self closeBlock: out from: start
      withParagraphStyle: [self headingStyleForLevel: level]];
    [self endBlockSpaceAfter: kHeadingSpaceAfter];
}

- (void)appendCodeBlock:(GSHelpCodeBlock *)codeBlock
               toString:(NSMutableAttributedString *)out
                 indent:(NSUInteger)indent
{
    NSString *code = [codeBlock code];
    if ([code length] == 0)
      {
        return;
      }

    /* SPEC 48: code must copy as source text - no prefixes added,
     * only presentation attributes around it. */
    NSFont *font = [self monoFont];
    /* The gap above the code block is a real pinned-height blank line. */
    [self beginBlockSpaceBefore: kBlockGap toString: out];
    NSParagraphStyle *style = [self bodyStyleIndent: indent
                                       spaceBefore: 0
                                               mono: YES];
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSParagraphStyleAttributeName: style,
        /* Shade code with the window background colour so the block reads
         * as inset against the white reading pane. */
        NSBackgroundColorAttributeName: [NSColor windowBackgroundColor],
    };
    NSUInteger start = [out length];
    [out appendAttributedString:
        [[NSAttributedString alloc] initWithString: code attributes: attrs]];

    [self closeBlock: out from: start
      withParagraphStyle: style];
    [self endBlockSpaceAfter: kBlockGap];
}

- (void)appendList:(GSHelpList *)list
           toString:(NSMutableAttributedString *)out
             indent:(NSUInteger)indent
{
    NSUInteger counter = 1;
    BOOL firstItem = YES;

    [self beginBlockSpaceBefore: kBlockGap toString: out];

    for (GSHelpNode *child in [list children])
      {
        if (![child isKindOfClass:[GSHelpListItem class]])
          {
            [self appendBlockNode: child toString: out indent: indent + 1];
            continue;
          }

        if (!firstItem)
          {
            /* Tight gap between sibling list items so the list reads as
             * one grouped block rather than loose paragraphs. */
            [self appendGapLine: kListGap toString: out];
          }
        firstItem = NO;

        NSString *prefix = [list isOrdered]
            ? [NSString stringWithFormat: @"%lu. ", (unsigned long)counter++]
            : @"\u2022  ";

        GSHelpListItem *item = (GSHelpListItem *)child;
        NSMutableArray<GSHelpList *> *nested = [NSMutableArray new];

        NSUInteger start = [out length];
        /* The prefix needs the body font explicitly: attribute-less
         * runs fall back to the text view's default font and render
         * at the wrong size next to their own item text. -closeBlock:
         * applies the real paragraph style across the whole item below. */
        [out appendAttributedString:
            [[NSAttributedString alloc] initWithString: prefix
                                            attributes: @{
                NSFontAttributeName: [self bodyFont],
            }]];
        for (GSHelpNode *itemChild in [item children])
          {
            if ([itemChild isKindOfClass:[GSHelpList class]])
              {
                [nested addObject: (GSHelpList *)itemChild];
              }
            else
              {
                [self appendInlineNode: itemChild
                              toString: out
                                  font: [self bodyFont]];
              }
          }
        [self closeBlock: out from: start
          withParagraphStyle: [self bodyStyleIndent: indent spaceBefore: 0 mono: NO]];

        for (GSHelpList *sub in nested)
          {
            [self appendList: sub toString: out indent: indent + 1];
          }
      }

    [self endBlockSpaceAfter: kBlockGap];
}

/* Renders a table the way gcasa/StepDown does: draw the whole grid
 * into an NSImage (header row shaded, 1px grid, text inset and
 * vertically centred) and embed it as a text attachment. This keeps
 * real column alignment without a table view, and matches StepDown's
 * on-screen look exactly. */
- (NSImage *)tableImageForRows:(NSArray<NSArray<NSString *> *> *)rows
                          font:(NSFont *)font
{
    NSUInteger rowCount = [rows count];
    if (rowCount == 0)
      {
        return nil;
      }
    NSUInteger columnCount = [rows[0] count];
    if (columnCount == 0)
      {
        return nil;
      }

    NSDictionary *textAttrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [NSColor blackColor],
    };
    CGFloat hPadding = 8.0;
    CGFloat vPadding = 5.0;
    CGFloat rowHeight =
        ceil([font ascender] - [font descender]
             + [font leading] + (vPadding * 2.0));
    if (rowHeight < 20.0)
      {
        rowHeight = 20.0;
      }

    /* Every column starts at 56pt and only grows to fit its widest
     * cell plus the horizontal padding, as in StepDown. */
    NSMutableArray<NSNumber *> *widths =
        [NSMutableArray arrayWithCapacity: columnCount];
    for (NSUInteger i = 0; i < columnCount; i++)
      {
        [widths addObject: @(56.0)];
      }
    for (NSUInteger i = 0; i < rowCount; i++)
      {
        NSArray<NSString *> *row = rows[i];
        for (NSUInteger j = 0; j < columnCount; j++)
          {
            NSString *cell = (j < [row count]) ? row[j] : @"";
            NSSize textSize = [cell sizeWithAttributes: textAttrs];
            NSUInteger cellLength =
                (NSUInteger)ceil(textSize.width + (hPadding * 2.0));
            NSUInteger width = [widths[j] unsignedIntegerValue];
            if (cellLength > width)
              {
                widths[j] = @(cellLength);
              }
          }
      }

    CGFloat tableWidth = 1.0;
    for (NSUInteger j = 0; j < columnCount; j++)
      {
        tableWidth += [widths[j] floatValue] + 1.0;
      }
    CGFloat tableHeight = 1.0 + ((CGFloat)rowCount * (rowHeight + 1.0));

    NSImage *image =
        [[NSImage alloc] initWithSize: NSMakeSize(tableWidth, tableHeight)];
    if (image == nil)
      {
        return nil;
      }

    NSColor *borderColor = [NSColor colorWithCalibratedWhite: 0.76 alpha: 1.0];
    NSColor *headerBackgroundColor =
        [NSColor colorWithCalibratedWhite: 0.93 alpha: 1.0];
    NSColor *bodyBackgroundColor = [NSColor whiteColor];
    NSColor *headerTextColor =
        [NSColor colorWithCalibratedWhite: 0.08 alpha: 1.0];
    NSDictionary *headerTextAttrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: headerTextColor,
    };

    [image lockFocus];
    [[NSColor clearColor] setFill];
    NSRectFill(NSMakeRect(0, 0, tableWidth, tableHeight));

    CGFloat y = tableHeight - 1.0;
    for (NSUInteger i = 0; i < rowCount; i++)
      {
        NSArray<NSString *> *row = rows[i];
        y -= rowHeight;
        CGFloat x = 1.0;
        for (NSUInteger j = 0; j < columnCount; j++)
          {
            CGFloat cellWidth = [widths[j] floatValue];
            NSRect cellRect = NSMakeRect(x, y, cellWidth, rowHeight);

            if (i == 0)
              {
                [headerBackgroundColor setFill];
              }
            else
              {
                [bodyBackgroundColor setFill];
              }
            NSRectFill(cellRect);

            NSString *displayText = (j < [row count]) ? row[j] : @"";
            NSSize textSize = (i == 0)
                ? [displayText sizeWithAttributes: headerTextAttrs]
                : [displayText sizeWithAttributes: textAttrs];
            NSPoint textPoint = NSMakePoint(
                x + hPadding, y + floor((rowHeight - textSize.height) / 2.0));
            if (i == 0)
              {
                [displayText drawAtPoint: textPoint
                           withAttributes: headerTextAttrs];
              }
            else
              {
                [displayText drawAtPoint: textPoint
                           withAttributes: textAttrs];
              }

            [borderColor setStroke];
            [NSBezierPath strokeRect: cellRect];

            x += cellWidth + 1.0;
          }
         y -= 1.0;
      }
    [image unlockFocus];

    /* GNUstep composites an NSCachedImageRep (the rep -lockFocus
     * produces) into a flipped text view without flip compensation,
     * which mirrors the table horizontally on screen. A data-backed
     * bitmap rep (the kind a file-loaded image has) is composited
     * correctly, so re-wrap through TIFF data to switch rep types. */
    NSData *tiff = [image TIFFRepresentation];
    if (tiff != nil)
      {
        NSImage *rewrapped = [[NSImage alloc] initWithData: tiff];
        if (rewrapped != nil)
          {
            image = rewrapped;
          }
      }

    /* The text view is a flipped context. GNUstep flips an image
     * whose -flipped flag disagrees with the context, which would put
     * the header at the bottom and turn the text upside down. Marking
     * the image flipped makes its orientation agree with the context
     * so no flip is applied and the table shows upright. */
    [image setFlipped: YES];
    return image;
}

- (void)appendTable:(GSHelpTable *)table
            toString:(NSMutableAttributedString *)out
              indent:(NSUInteger)indent
{
    NSArray<GSHelpTableRow *> *rows = [table rows];
    if ([rows count] == 0)
      {
        return;
      }

    /* Normalise ragged rows to a uniform column count (matching
     * StepDown's StepDownNormalizeTableRow), then draw once. */
    NSUInteger columns = 0;
    for (GSHelpTableRow *row in rows)
      {
        columns = MAX(columns, [[row cells] count]);
      }
    if (columns == 0)
      {
        return;
      }

    NSMutableArray<NSMutableArray<NSString *> *> *matrix =
        [NSMutableArray arrayWithCapacity: [rows count]];
    for (GSHelpTableRow *row in rows)
      {
        NSMutableArray<NSString *> *cells =
            [NSMutableArray arrayWithCapacity: columns];
        NSArray<GSHelpTableCell *> *src = [row cells];
        for (NSUInteger c = 0; c < columns; c++)
          {
            NSString *t = (c < [src count])
                ? [[src objectAtIndex: c] text] : @"";
            [cells addObject: (t ?: @"")];
          }
        [matrix addObject: cells];
      }

    NSFont *font = [self bodyFont];
    NSImage *image = [self tableImageForRows: matrix font: font];
    if (image == nil)
      {
        return;
      }

    [self beginBlockSpaceBefore: kBlockGap toString: out];

    NSTextAttachment *attachment =
        [[NSTextAttachment alloc] initWithFileWrapper: nil];
    GSHelpImageAttachmentCell *cell =
        [[GSHelpImageAttachmentCell alloc] initImageCell: image];
    [attachment setAttachmentCell: cell];
    NSUInteger start = [out length];
    [out appendAttributedString:
        [NSAttributedString attributedStringWithAttachment: attachment]];
    [self closeBlock: out from: start
      withParagraphStyle: [self bodyStyleIndent: indent spaceBefore: 0 mono: NO]];
    [self endBlockSpaceAfter: kBlockGap];
}

- (void)appendImage:(GSHelpImage *)imageNode
            toString:(NSMutableAttributedString *)out
              indent:(NSUInteger)indent
{
    NSURL *url = [self imageURLForNode: imageNode];
    NSLog(@"Help: appendImage path=%@ -> url=%@", [imageNode path], url);

    [self beginBlockSpaceBefore: kBlockGap toString: out];

    /* Remote image: attach a placeholder box, fetch off the main thread,
     * then swap the real picture in and ask the view to re-layout. */
    if (url != nil && ![url isFileURL])
      {
        NSLog(@"Help: remote image, attaching placeholder and fetching %@",
              url);
        NSTextAttachment *attachment =
            [[NSTextAttachment alloc] initWithFileWrapper: nil];
        GSHelpImageAttachmentCell *cell =
            [[GSHelpImageAttachmentCell alloc] initImageCell:
                [self placeholderImage]];
        [attachment setAttachmentCell: cell];
        NSUInteger start = [out length];
        [out appendAttributedString:
            [NSAttributedString attributedStringWithAttachment: attachment]];
        [self closeBlock: out from: start
          withParagraphStyle: [self bodyStyleIndent: indent spaceBefore: 0 mono: NO]];
        [self fetchRemoteImage: url cell: cell];
        [self endBlockSpaceAfter: kBlockGap];
        return;
      }

    NSImage *image = nil;
    if (url != nil)
      {
        image = [[NSImage alloc] initWithContentsOfFile: [url path]];
      }

    if (image == nil)
      {
        NSLog(@"Help: local image MISSING (%@), showing alt text", url);
        /* Alt text stands in when the file is missing or the URL is
         * neither a local file nor a supported remote scheme. */
        NSString *alt = [imageNode altText] ?: @"image";
        NSDictionary *attrs = @{
            NSFontAttributeName:
                [[NSFontManager sharedFontManager]
                    convertFont: [self bodyFont]
                       toHaveTrait: NSItalicFontMask],
        };
        [out appendAttributedString:
            [[NSAttributedString alloc] initWithString:
                [NSString stringWithFormat: @"[%@]", alt] attributes: attrs]];
        [self endBlockSpaceAfter: kBlockGap];
        return;
      }
    NSLog(@"Help: local image loaded %@", url);

    NSSize size = [image size];
    if (size.width > kMaxImageWidth)
      {
        NSSize scaled = NSMakeSize(kMaxImageWidth,
                                   size.height * kMaxImageWidth / size.width);
        [image setSize: scaled];
      }

    NSTextAttachment *attachment =
        [[NSTextAttachment alloc] initWithFileWrapper: nil];
    GSHelpImageAttachmentCell *cell =
        [[GSHelpImageAttachmentCell alloc] initImageCell: image];
    [attachment setAttachmentCell: cell];
    NSUInteger start = [out length];
    [out appendAttributedString:
        [NSAttributedString attributedStringWithAttachment: attachment]];
    [self closeBlock: out from: start
      withParagraphStyle: [self bodyStyleIndent: indent spaceBefore: 0 mono: NO]];
    [self endBlockSpaceAfter: kBlockGap];
}

/* A blank box reserves layout space for a remote image until it loads,
 * so the document does not jump from zero-height to full-height. */
- (NSImage *)placeholderImage
{
    return [[NSImage alloc] initWithSize: NSMakeSize(kMaxImageWidth, 120)];
}

/* Resolve an image reference to a URL. Local paths (absolute, or
 * relative to the document's source directory per SPEC 49/62) become
 * file URLs; http/https references are left as remote URLs. Anything
 * else (help:, data:, ...) yields nil so the alt text is shown. */
- (nullable NSURL *)imageURLForNode:(GSHelpImage *)imageNode
{
    NSString *path = [imageNode path];
    if ([path length] == 0)
      {
        return nil;
      }

    if ([path hasPrefix: @"http://"] || [path hasPrefix: @"https://"])
      {
        return [NSURL URLWithString: path];
      }
    if (![path hasPrefix: @"/"])
      {
        NSURL *base = [[_document sourceURL] URLByDeletingLastPathComponent];
        if (base != nil)
          {
            return [NSURL fileURLWithPath:
                       [[base URLByAppendingPathComponent: path] path]];
          }
        return nil;
      }
    return [NSURL fileURLWithPath: path];
}

/* Fetch a remote image on a background thread; on completion (main
 * thread) swap it into the attachment cell and ask the view to
 * re-layout. GNUstep has no async NSURL loading we can rely on
 * everywhere, so a synchronous fetch on a worker thread is used. */
- (void)fetchRemoteImage:(NSURL *)url cell:(GSHelpImageAttachmentCell *)cell
{
    [NSThread detachNewThreadSelector: @selector(runRemoteImageFetch:)
                             toTarget: self
                           withObject: @{ @"url": url, @"cell": cell }];
}

#ifdef GS_HAVE_CURL
static size_t gsHelpCurlWrite(void *ptr,
                              size_t size,
                              size_t nmemb,
                              void *userdata)
{
    NSMutableData *data = (__bridge NSMutableData *)userdata;
    [data appendBytes: ptr length: size * nmemb];
    return size * nmemb;
}

/* Fetch over libcurl so HTTP redirects (GitHub user-attachments 302 to
 * the blob store) are followed; GNUstep's NSURL loading stops at the
 * first 30x and would leave a blank placeholder. */
static NSData *gsHelpFetchURLData(NSString *urlString)
{
    CURL *curl = curl_easy_init();
    if (curl == NULL)
      {
        return nil;
      }
    NSMutableData *buffer = [NSMutableData new];
    curl_easy_setopt(curl, CURLOPT_URL, [urlString UTF8String]);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, gsHelpCurlWrite);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, (__bridge void *)buffer);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 16L);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "GershwinHelp/1.0");
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);
    CURLcode rc = curl_easy_perform(curl);
    curl_easy_cleanup(curl);
    if (rc != CURLE_OK)
      {
        return nil;
      }
    return [buffer length] > 0 ? [NSData dataWithData: buffer] : nil;
}

/* In-memory cache so a remote picture is fetched once per process,
 * reused across documents and re-renders (no re-download on every
 * outline click). Keyed by the absolute URL string. */
static NSMutableDictionary<NSString *, NSData *> *gsHelpImageCache = nil;
static NSLock *gsHelpImageCacheLock = nil;

static void gsHelpEnsureImageCache(void)
{
    if (gsHelpImageCache == nil)
      {
        gsHelpImageCache = [NSMutableDictionary new];
        gsHelpImageCacheLock = [NSLock new];
      }
}

static NSData *gsHelpCachedFetch(NSString *urlString)
{
    gsHelpEnsureImageCache();
    [gsHelpImageCacheLock lock];
    NSData *cached = gsHelpImageCache[urlString];
    [gsHelpImageCacheLock unlock];
    if (cached != nil)
      {
        NSLog(@"Help: image cache HIT %@", urlString);
        return cached;
      }
    NSLog(@"Help: image cache MISS, fetching %@", urlString);
    NSData *data = gsHelpFetchURLData(urlString);
    if (data != nil)
      {
        NSLog(@"Help: image fetched %lu bytes %@",
              (unsigned long)[data length], urlString);
        [gsHelpImageCacheLock lock];
        gsHelpImageCache[urlString] = data;
        [gsHelpImageCacheLock unlock];
      }
    else
      {
        NSLog(@"Help: image FETCH FAILED %@", urlString);
      }
    return data;
}
#endif

- (void)runRemoteImageFetch:(NSDictionary *)info
{
    @autoreleasepool {
      NSURL *url = info[@"url"];
      GSHelpImageAttachmentCell *cell = info[@"cell"];
      NSString *urlString = [url absoluteString];
      NSData *data = nil;
#ifdef GS_HAVE_CURL
      data = gsHelpCachedFetch(urlString);
#else
      NSLog(@"Help: fetching image via NSData %@", urlString);
      data = [NSData dataWithContentsOfURL: url];
      NSLog(@"Help: image fetch %@ -> %lu bytes",
            urlString, (unsigned long)[data length]);
#endif
      NSImage *image = (data != nil)
          ? [[NSImage alloc] initWithData: data] : nil;
      if (image != nil)
        {
          NSSize size = [image size];
          if (size.width > kMaxImageWidth)
            {
              NSSize scaled = NSMakeSize(kMaxImageWidth,
                                         size.height * kMaxImageWidth
                                             / size.width);
              [image setSize: scaled];
            }
        }
      [self performSelectorOnMainThread: @selector(applyRemoteImage:)
                             withObject: @{ @"url": urlString,
                                             @"cell": cell,
                                             @"image": image ?: [NSNull null] }
                          waitUntilDone: NO];
    }
}

- (void)applyRemoteImage:(NSDictionary *)info
{
    NSString *urlString = info[@"url"];
    GSHelpImageAttachmentCell *cell = info[@"cell"];
    NSImage *image = info[@"image"];
    if ([image isKindOfClass: [NSImage class]] && image != nil)
      {
        NSSize s = [image size];
        NSLog(@"Help: image LOADED (%.0fx%.0f), swapping into cell %@",
              s.width, s.height, urlString);
        [cell setImage: image];
      }
    else
      {
        NSLog(@"Help: image NOT loaded, keeping placeholder %@", urlString);
      }
    if (_imageDidLoad != nil)
      {
        _imageDidLoad();
      }
}

#pragma mark Inline rendering

- (void)appendInlineChildren:(NSArray<GSHelpNode *> *)children
                    toString:(NSMutableAttributedString *)out
                        font:(NSFont *)baseFont
                      indent:(NSUInteger)indent
{
    for (GSHelpNode *child in children)
      {
        [self appendInlineNode: child toString: out font: baseFont];
      }
}

- (void)appendInlineNode:(GSHelpNode *)node
                toString:(NSMutableAttributedString *)out
                    font:(NSFont *)baseFont
{
    if ([node isKindOfClass:[GSHelpText class]])
      {
        GSHelpText *run = (GSHelpText *)node;
        NSString *string = [run string];
        if ([string length] == 0)
          {
            return;
          }
        NSDictionary *attrs = @{
            NSFontAttributeName:
                [self runFontForStyle: [run style] base: baseFont],
        };
        [out appendAttributedString:
            [[NSAttributedString alloc] initWithString: string
                                            attributes: attrs]];
      }
    else if ([node isKindOfClass:[GSHelpLink class]])
      {
        GSHelpLink *link = (GSHelpLink *)node;
        NSString *target = [link target] ?: @"";
        BOOL navigable = [self linkTargetIsNavigable: target];

        for (GSHelpText *run in [link labelRuns])
          {
            NSString *string = [run string];
            if ([string length] == 0)
              {
                continue;
              }
            NSDictionary *attrs;
            if (navigable)
              {
                /* Target stored as the link attribute value so click
                 * handling can resolve it later (help:// or relative). */
                attrs = @{
                    NSFontAttributeName:
                        [self runFontForStyle: [run style] base: baseFont],
                    NSLinkAttributeName: target,
                    NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
                };
              }
            else
              {
                /* An unresolvable reference (e.g. a man page that is
                 * not installed) must not look or act like a link;
                 * render it as ordinary text so it cannot be clicked
                 * into a dead end. */
                attrs = @{
                    NSFontAttributeName:
                        [self runFontForStyle: [run style] base: baseFont],
                };
              }
            [out appendAttributedString:
                [[NSAttributedString alloc] initWithString: string
                                                attributes: attrs]];
          }
      }
    else if ([node isKindOfClass:[GSHelpImage class]])
      {
        [self appendImage: (GSHelpImage *)node toString: out indent: 0];
      }
}

/* A reference is shown as a link only when it actually leads somewhere.
 * Man references require the page to be installed; local/relative links
 * require the file to exist; external http(s) links always navigate. */
- (BOOL)linkTargetIsNavigable:(NSString *)target
{
  if (target.length == 0)
    {
      return NO;
    }
  NSURL *url = [NSURL URLWithString: target];
  if (url == nil)
    {
      return NO;
    }
  NSString *scheme = [url scheme];
  if (scheme == nil || [scheme isEqualToString: @""])
    {
      /* Relative target: resolve against the document's own location
       * and require the file to exist. */
      if (_document.sourceURL == nil)
        {
          return NO;
        }
      NSURL *abs = [NSURL URLWithString: target
                          relativeToURL: _document.sourceURL];
      abs = [abs absoluteURL];
      return [[NSFileManager defaultManager] fileExistsAtPath: [abs path]];
    }
  if ([scheme isEqualToString: @"http"] || [scheme isEqualToString: @"https"])
    {
      return YES;
    }
  if ([scheme isEqualToString: @"file"])
    {
      return [[NSFileManager defaultManager] fileExistsAtPath: [url path]];
    }
  if ([GSHelpURL isHelpURL: url])
    {
      NSString *kind = [GSHelpURL kindOfURL: url];
      if ([kind isEqualToString: @"man"])
        {
          NSURL *page = [GSHelpManLocator
              locateManPageWithCommand: [GSHelpURL commandOfURL: url]
                               section: [GSHelpURL sectionOfURL: url]
                           searchPaths:
                               [GSHelpManLocator defaultSearchPaths]];
          return page != nil;
        }
      /* Other help: kinds (catalog/section/topic) are resolved by the
       * controller against the installed catalog, so trust them. */
      return YES;
    }
  return NO;
}

@end

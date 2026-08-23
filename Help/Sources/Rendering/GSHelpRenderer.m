/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSHelpRenderer.h"

/* Layout metrics. Spacing values follow the 2px multiples of the
 * Gershwin AppearanceMetrics house style; sizes are relative to the
 * user's default font size so nothing is hard-coded absolutely. */
static const CGFloat kBlockGap = 8.0;
static const CGFloat kHeadingSpaceBefore = 14.0;
static const CGFloat kHeadingSpaceAfter = 6.0;
static const CGFloat kIndentStep = 18.0;
static const CGFloat kCodeInset = 10.0;
static const CGFloat kMaxImageWidth = 420.0;

#pragma mark - Image attachment cell

/* Draws the loaded NSImage inside the text flow; the stock
 * NSTextAttachmentCell has no image drawing of its own. */
@interface GSHelpImageAttachmentCell : NSTextAttachmentCell
@end

@implementation GSHelpImageAttachmentCell

- (NSSize)cellSize
{
    return [[self image] size];
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
    NSImage *image = [self image];
    if (image != nil)
      {
        [image drawInRect: cellFrame
                 fromRect: NSZeroRect
                operation: NSCompositeSourceOver
                 fraction: 1.0];
      }
}

@end

#pragma mark - Renderer

@implementation GSHelpRenderer
{
    NSMutableDictionary<NSString *, NSValue *> *_headingRanges;
    CGFloat _userSize;
    GSHelpDocument *_document;
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
    style.paragraphSpacingBefore = before;
    style.paragraphSpacing = kBlockGap;
    style.lineBreakMode = NSLineBreakByWordWrapping;
    return style;
}

- (NSParagraphStyle *)headingStyleForLevel:(NSUInteger)level
{
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.paragraphSpacingBefore = kHeadingSpaceBefore;
    style.paragraphSpacing = kHeadingSpaceAfter;
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
        NSUInteger start = [out length];
        [self appendInlineChildren: [node children]
                            toString: out
                                font: [self bodyFont]
                               indent: indent];
        [self finishParagraph: out from: start
                        style: [self bodyStyleIndent: indent spaceBefore: 0 mono: NO]];
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
        NSUInteger start = [out length];
        [self appendInlineNode: node toString: out font: [self bodyFont]];
        [self finishParagraph: out from: start
                        style: [self bodyStyleIndent: indent spaceBefore: 0 mono: NO]];
      }
    else if ([node isKindOfClass:[GSHelpAnchor class]])
      {
        /* Invisible by design; resolvable through document anchors. */
      }
}

- (void)finishParagraph:(NSMutableAttributedString *)out
                   from:(NSUInteger)start
                  style:(NSParagraphStyle *)style
{
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
    NSString *text = [heading text];
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

    NSDictionary *attrs = @{
        NSFontAttributeName: [self headingFontForLevel: level],
        NSParagraphStyleAttributeName: [self headingStyleForLevel: level],
    };
    [out appendAttributedString:
        [[NSAttributedString alloc] initWithString: text attributes: attrs]];

    [out appendAttributedString:
        [[NSAttributedString alloc] initWithString: @"\n" attributes: attrs]];
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
    NSFont *font = [NSFont userFixedPitchFontOfSize: _userSize];
    NSParagraphStyle *style = [self bodyStyleIndent: indent
                                       spaceBefore: kBlockGap
                                               mono: YES];
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSParagraphStyleAttributeName: style,
        NSBackgroundColorAttributeName: [NSColor textBackgroundColor],
    };
    [out appendAttributedString:
        [[NSAttributedString alloc] initWithString: code attributes: attrs]];

    [out appendAttributedString:
        [[NSAttributedString alloc] initWithString: @"\n" attributes: attrs]];
}

- (void)appendList:(GSHelpList *)list
          toString:(NSMutableAttributedString *)out
            indent:(NSUInteger)indent
{
    NSUInteger counter = 1;

    for (GSHelpNode *child in [list children])
      {
        if (![child isKindOfClass:[GSHelpListItem class]])
          {
            [self appendBlockNode: child toString: out indent: indent + 1];
            continue;
          }

        NSString *prefix = [list isOrdered]
            ? [NSString stringWithFormat: @"%lu. ", (unsigned long)counter++]
            : @"\u2022  ";

        GSHelpListItem *item = (GSHelpListItem *)child;
        NSMutableArray<GSHelpList *> *nested = [NSMutableArray new];

        NSUInteger start = [out length];
        [out appendAttributedString:
            [[NSAttributedString alloc] initWithString: prefix attributes: @{}]];
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
        [self finishParagraph: out from: start
                        style: [self bodyStyleIndent: indent spaceBefore: 2.0 mono: NO]];

        for (GSHelpList *sub in nested)
          {
            [self appendList: sub toString: out indent: indent + 1];
          }
      }
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

    /* Column width = longest cell text; monospace padding keeps
     * columns aligned without a table view (v1 approach). */
    NSUInteger columns = 0;
    for (GSHelpTableRow *row in rows)
      {
        columns = MAX(columns, [[row cells] count]);
      }
    if (columns == 0)
      {
        return;
      }

    NSUInteger widths[columns];
    for (NSUInteger i = 0; i < columns; i++)
      {
        widths[i] = 0;
      }
    for (GSHelpTableRow *row in rows)
      {
        for (NSUInteger i = 0; i < [[row cells] count]; i++)
          {
            NSString *text = [[row cells][i] text];
            widths[i] = MAX(widths[i], [text length]);
          }
      }

    NSUInteger totalWidth = 2 * columns;
    for (NSUInteger i = 0; i < columns; i++)
      {
        totalWidth += widths[i];
      }

    NSFont *mono = [NSFont userFixedPitchFontOfSize: _userSize];
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.firstLineHeadIndent = indent * kIndentStep;
    style.headIndent = indent * kIndentStep;
    style.paragraphSpacing = 0.0;
    style.paragraphSpacingBefore = 0.0;

    for (NSUInteger r = 0; r < [rows count]; r++)
      {
        BOOL header = (r == 0);
        NSFont *rowFont = header
            ? [[NSFontManager sharedFontManager] convertFont: mono
                                                   toHaveTrait: NSBoldFontMask]
            : mono;

        NSMutableString *line = [NSMutableString new];
        NSArray<GSHelpTableCell *> *cells = [rows[r] cells];
        for (NSUInteger c = 0; c < columns; c++)
          {
            NSString *text = (c < [cells count]) ? [[cells objectAtIndex: c] text] : @"";
            [line appendFormat: @"  %@%*s",
                text ?: @"",
                (int)(widths[c] - [text length]), ""];
          }
        [line appendString: @"  "];

        NSUInteger start = [out length];
        [out appendAttributedString:
            [[NSAttributedString alloc] initWithString: line
                                            attributes: @{ NSFontAttributeName: rowFont }]];

        /* Rule between header and body so tables read as tables. */
        if (header && [rows count] > 1)
          {
            NSMutableString *rule = [NSMutableString new];
            while ([rule length] < totalWidth)
              {
                [rule appendString: @"-"];
              }
            [out appendAttributedString:
                [[NSAttributedString alloc] initWithString: @"\n"
                                                attributes: @{ NSFontAttributeName: mono }]];
            [out appendAttributedString:
                [[NSAttributedString alloc] initWithString: rule
                                                attributes: @{ NSFontAttributeName: mono }]];
          }

        [out appendAttributedString:
            [[NSAttributedString alloc] initWithString: @"\n"
                                            attributes: @{ NSFontAttributeName: rowFont }]];
        [out addAttribute: NSParagraphStyleAttributeName
                    value: style
                    range: NSMakeRange(start, [out length] - start)];
      }

    [out appendAttributedString:
        [[NSAttributedString alloc] initWithString: @"\n"
                                        attributes: @{ NSFontAttributeName: mono }]];
}

- (void)appendImage:(GSHelpImage *)imageNode
           toString:(NSMutableAttributedString *)out
             indent:(NSUInteger)indent
{
    NSImage *image = [self imageForNode: imageNode];

    if (image == nil)
      {
        /* Alt text stands in when the local file is missing. */
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
        return;
      }

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

    [out appendAttributedString:
        [NSAttributedString attributedStringWithAttachment: attachment]];
    [out appendAttributedString:
        [[NSAttributedString alloc] initWithString: @"\n"]];
}

- (nullable NSImage *)imageForNode:(GSHelpImage *)imageNode
{
    NSString *path = [imageNode path];
    if ([path length] == 0)
      {
        return nil;
      }

    if (![path isAbsolutePath])
      {
        /* Relative image paths resolve against the document's own
         * source directory (SPEC 49/62: help bundle resources only). */
        NSURL *base = [[_document sourceURL] URLByDeletingLastPathComponent];
        if (base == nil)
          {
            return nil;
          }
        path = [[base URLByAppendingPathComponent: path] path];
      }

    NSImage *image = [[NSImage alloc] initWithContentsOfFile: path];
    return image;
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

        for (GSHelpText *run in [link labelRuns])
          {
            NSString *string = [run string];
            if ([string length] == 0)
              {
                continue;
              }
            /* Target stored as the link attribute value so click
             * handling can resolve it later (help:// or relative). */
            NSDictionary *attrs = @{
                NSFontAttributeName:
                    [self runFontForStyle: [run style] base: baseFont],
                NSLinkAttributeName: target,
                NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
            };
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

@end

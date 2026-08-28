/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EPUBHTMLConverter.h"

@interface BooksImageAttachmentCell : NSTextAttachmentCell
@end

static const CGFloat kBodySize = 16.0;
@interface EPUBHTMLConverter () <NSXMLParserDelegate>
{
  NSMutableAttributedString *_out;
  NSMutableArray<NSNumber *> *_traitStack;
  NSMutableArray<NSNumber *> *_sizeStack;
  NSMutableArray<NSNumber *> *_ignoreStack;
  NSUInteger _blockStart;
  NSMutableParagraphStyle *_blockStyle;
  NSURL *_base;
  NSURL *_containerRoot;
  NSFont *_lastFont;
  NSMutableArray<NSString *> *_dirStack;
  NSMutableArray<NSString *> *_langStack;
  NSString *_currentDir;
  NSString *_currentLang;
  NSMutableDictionary<NSString *, NSNumber *> *_anchors;
}

@end

@implementation EPUBHTMLConverter

+ (NSAttributedString *)attributedStringFromXHTMLAtPath:(NSString *)path
                                                 baseURL:(NSURL *)base
                                                   error:(NSError **)error
{
  return [self attributedStringFromXHTMLAtPath:path
                                        baseURL:base
                                 containerRoot:nil
                                         error:error];
}

+ (NSAttributedString *)attributedStringFromXHTMLAtPath:(NSString *)path
                                                  baseURL:(NSURL *)base
                                           containerRoot:(NSString *)containerRoot
                                                    error:(NSError **)error
{
  return [self attributedStringFromXHTMLAtPath:path
                                        baseURL:base
                                 containerRoot:containerRoot
                                       anchors:NULL
                                          error:error];
}

+ (NSAttributedString *)attributedStringFromXHTMLAtPath:(NSString *)path
                                                  baseURL:(NSURL *)base
                                           containerRoot:(NSString *)containerRoot
                                                 anchors:(NSDictionary<NSString *, NSNumber *> **)outAnchors
                                                    error:(NSError **)error
{
  EPUBHTMLConverter *c = [[EPUBHTMLConverter alloc] init];
  c->_containerRoot = [containerRoot isKindOfClass:[NSString class]]
                          ? [NSURL fileURLWithPath:[containerRoot stringByStandardizingPath]]
                          : nil;
  NSAttributedString *result = [c parsePath:path baseURL:base error:error];
  if (outAnchors != NULL)
    *outAnchors = [c->_anchors copy];
  return result;
}

- (NSAttributedString *)parsePath:(NSString *)path
                           baseURL:(NSURL *)base
                             error:(NSError **)error
{
  NSData *raw = [NSData dataWithContentsOfFile:path];
  if (raw == nil)
    {
      if (error) *error = [NSError errorWithDomain:@"EPUBHTML" code:1
                                          userInfo:@{ NSLocalizedDescriptionKey: @"cannot read file" }];
      return [[NSAttributedString alloc] init];
    }
  _base = base;
  _out = [[NSMutableAttributedString alloc] init];
  _traitStack = [NSMutableArray arrayWithObject:@(0)];
  _sizeStack = [NSMutableArray arrayWithObject:@(kBodySize)];
  _ignoreStack = [NSMutableArray arrayWithObject:@(0)];
  _dirStack = [NSMutableArray array];
  _langStack = [NSMutableArray array];
  _currentDir = nil;
  _currentLang = nil;
  _blockStart = 0;
  _blockStyle = [self defaultParagraph];
  _anchors = [NSMutableDictionary dictionary];

  NSMutableData *d = [NSMutableData dataWithCapacity:[raw length]];
  [d appendData:raw];
  // Normalise a few HTML entities the XML parser will not know.
  NSString *s = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
  if (s)
    {
      s = [s stringByReplacingOccurrencesOfString:@"&nbsp;" withString:@" "];
      NSData *nd = [s dataUsingEncoding:NSUTF8StringEncoding];
      if (nd) d = [NSMutableData dataWithData:nd];
    }

  NSXMLParser *parser = [[NSXMLParser alloc] initWithData:d];
  [parser setShouldResolveExternalEntities:NO];
  [parser setDelegate:self];
  if (![parser parse] && error == NULL)
    {
      // best-effort: return whatever we accumulated
    }
  // ensure trailing newline
  if ([_out length] > 0 &&
      ![[_out string] hasSuffix:@"\n"])
    [_out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
  return _out;
}

- (NSMutableParagraphStyle *)defaultParagraph
{
  NSMutableParagraphStyle *p = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
  [p setParagraphSpacing:6.0];
  [p setParagraphSpacingBefore:0.0];
  [p setAlignment:NSLeftTextAlignment];
  [p setHeadIndent:0.0];
  [p setTailIndent:0.0];
  [p setFirstLineHeadIndent:0.0];
  return p;
}

- (NSFont *)currentFont
{
  NSFontTraitMask trait = [_traitStack.lastObject unsignedIntegerValue];
  CGFloat size = [_sizeStack.lastObject doubleValue];
  // Palatino (and its URW clone "Palladio") is the default book face; fall
  // back through its common aliases and then to a generic serif if none of
  // them are installed.
  NSArray<NSString *> *families = @[ @"Palatino", @"URW Palladio L",
                                     @"Palladio", @"Palatino Linotype",
                                     @"TeX Gyre Pagella", @"DejaVu Serif",
                                     @"Times New Roman" ];
  NSFont *f = nil;
  NSFontManager *fm = [NSFontManager sharedFontManager];
  // GNUstep's fontWithFamily:traits:weight:size: treats weight 0 as below the
  // valid range and returns nil; the regular weight in its 0..15 scale is 5.
  // Bold/italic are carried by the trait mask, not by the weight value.
  for (NSString *family in families)
    {
      f = [fm fontWithFamily:family traits:trait weight:5 size:size];
      if (f != nil) break;
    }
  if (f == nil)
    f = [NSFont fontWithName:@"URW Palladio L" size:size]
          ?: [NSFont userFontOfSize:size];
  _lastFont = f;
  return f;
}

- (void)pushTrait:(NSFontTraitMask)trait
{
  NSFontTraitMask cur = [_traitStack.lastObject unsignedIntegerValue];
  [_traitStack addObject:@(cur | trait)];
}
- (void)popTrait:(NSFontTraitMask)trait
{
  // remove the most recent matching trait from the stack
  for (NSInteger i = (NSInteger)[_traitStack count] - 1; i >= 0; i--)
    {
      NSFontTraitMask m = [_traitStack[i] unsignedIntegerValue];
      if (m & trait)
        {
          [_traitStack removeObjectAtIndex:i];
          break;
        }
    }
  if ([_traitStack count] == 0) [_traitStack addObject:@(0)];
}
- (void)pushSize:(CGFloat)size { [_sizeStack addObject:@(size)]; }
- (void)popSize { if ([_sizeStack count] > 1) [_sizeStack removeLastObject]; }

- (void)pushIgnore:(BOOL)ignore
{
  NSInteger cur = [_ignoreStack.lastObject integerValue];
  [_ignoreStack addObject:@(cur + (ignore ? 1 : 0))];
}
- (void)popIgnore { if ([_ignoreStack count] > 1) [_ignoreStack removeLastObject]; }
- (BOOL)ignoring { return [_ignoreStack.lastObject integerValue] > 0; }

- (void)startBlock:(NSMutableParagraphStyle *)style
{
  // finalize the previous block first
  [self finalizeBlock];
  BOOL needBreak = ([_out length] > 0);
  if (needBreak)
    [_out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
  _blockStart = [_out length];
  _blockStyle = style ?: [self defaultParagraph];
  // EPUB RS 3.3, 5.1 / 6.1: apply the base writing direction resolved from the
  // dir attribute (ltr/rtl). "auto"/absent leaves the natural direction.
  if ([_currentDir isEqualToString:@"rtl"])
    [_blockStyle setBaseWritingDirection:NSWritingDirectionRightToLeft];
  else if ([_currentDir isEqualToString:@"ltr"])
    [_blockStyle setBaseWritingDirection:NSWritingDirectionLeftToRight];
}

- (void)finalizeBlock
{
  NSUInteger end = [_out length];
  if (end > _blockStart)
    {
      NSRange r = NSMakeRange(_blockStart, end - _blockStart);
      [_out addAttribute:NSParagraphStyleAttributeName value:_blockStyle range:r];
    }
  // Advance past the finalized range so a later startBlock does not re-finalize
  // (and overwrite) this block's paragraph attributes.
  _blockStart = end;
  _blockStyle = [self defaultParagraph];
}

#pragma mark - NSXMLParserDelegate

- (void)parser:(NSXMLParser *)parser
didStartElement:(NSString *)element
   namespaceURI:(NSString *)ns
  qualifiedName:(NSString *)qn
     attributes:(NSDictionary *)attrs
{
  NSString *e = [element lowercaseString];

  // Record a page-list / TOC anchor: the offset where this element's content
  // begins, keyed by its id. Done first so it points at the element start even
  // for block elements that append a leading newline in startBlock below.
  NSString *idAttr = attrs[@"id"];
  if (idAttr != nil && [idAttr length] > 0)
    {
      [_anchors setObject:@([_out length]) forKey:idAttr];
    }

  // EPUB RS 3.3, 3.7 / 5.1 / 6.1: process the dir and xml:lang attributes.
  // Direction is inherited until overridden; we push the effective value for
  // every element so block starts can apply the base writing direction.
  NSString *dirAttr = attrs[@"dir"] ?: attrs[@"epub:dir"];
  NSString *langAttr = attrs[@"lang"] ?: attrs[@"xml:lang"];
  NSString *newDir = (dirAttr != nil) ? dirAttr : _currentDir;
  NSString *newLang = (langAttr != nil) ? langAttr : _currentLang;
  [_dirStack addObject:(newDir ?: (id)[NSNull null])];
  [_langStack addObject:(newLang ?: (id)[NSNull null])];
  _currentDir = newDir;
  _currentLang = newLang;

  if ([e isEqualToString:@"b"] || [e isEqualToString:@"strong"]) { [self pushTrait:NSBoldFontMask]; return; }
  if ([e isEqualToString:@"i"] || [e isEqualToString:@"em"]) { [self pushTrait:NSItalicFontMask]; return; }
  if ([e isEqualToString:@"u"]) { return; }
  if ([e isEqualToString:@"script"] || [e isEqualToString:@"style"]) { [self pushIgnore:YES]; return; }
  // The document head (title, meta, link) is not body content; ignoring it
  // stops the head's <title> from being rendered as a duplicate (normal-size)
  // copy of the chapter name that the body already shows as a heading.
  if ([e isEqualToString:@"head"]) { [self pushIgnore:YES]; return; }

  if ([e isEqualToString:@"br"]) {
    if (![self ignoring]) [_out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    return;
  }
  if ([e isEqualToString:@"hr"]) {
    if (![self ignoring]) { [self startBlock:nil]; [_out appendAttributedString:[[NSAttributedString alloc] initWithString:@"-----\n"]]; }
    return;
  }
  if ([e isEqualToString:@"img"]) {
    if (![self ignoring]) [self appendImageWithAttributes:attrs];
    return;
  }

  if ([e isEqualToString:@"h1"]) { [self startBlock:[self headingStyle:NSLeftTextAlignment]]; [self pushSize:28]; [self pushTrait:NSBoldFontMask]; return; }
  if ([e isEqualToString:@"h2"]) { [self startBlock:[self headingStyle:NSLeftTextAlignment]]; [self pushSize:24]; [self pushTrait:NSBoldFontMask]; return; }
  if ([e isEqualToString:@"h3"]) { [self startBlock:[self headingStyle:NSLeftTextAlignment]]; [self pushSize:20]; [self pushTrait:NSBoldFontMask]; return; }
  if ([e isEqualToString:@"h4"]) { [self startBlock:[self headingStyle:NSLeftTextAlignment]]; [self pushSize:18]; [self pushTrait:NSBoldFontMask]; return; }
  if ([e isEqualToString:@"h5"]) { [self startBlock:[self headingStyle:NSLeftTextAlignment]]; [self pushSize:16]; [self pushTrait:NSBoldFontMask]; return; }
  if ([e isEqualToString:@"h6"]) { [self startBlock:[self headingStyle:NSLeftTextAlignment]]; [self pushSize:14]; [self pushTrait:NSBoldFontMask]; return; }
  if ([e isEqualToString:@"p"] || [e isEqualToString:@"div"]) { [self startBlock:[self defaultParagraph]]; return; }
  if ([e isEqualToString:@"blockquote"]) {
    NSMutableParagraphStyle *p = [self defaultParagraph];
    [p setHeadIndent:24]; [p setTailIndent:-24]; [p setParagraphSpacingBefore:6];
    [self startBlock:p]; return;
  }
  if ([e isEqualToString:@"li"]) {
    NSMutableParagraphStyle *p = [self defaultParagraph];
    [p setHeadIndent:20]; [p setFirstLineHeadIndent:8]; [p setParagraphSpacing:3];
    [self startBlock:p];
    if (![self ignoring]) [_out appendAttributedString:[[NSAttributedString alloc] initWithString:@"-  "]];
    return;
  }
  if ([e isEqualToString:@"a"]) { return; }
  // other inline/unknown elements: ignore tag, keep text
}

- (void)parser:(NSXMLParser *)parser
  didEndElement:(NSString *)element
   namespaceURI:(NSString *)ns
  qualifiedName:(NSString *)qn
{
  NSString *e = [element lowercaseString];

  // pop the dir/lang context pushed in didStartElement
  if ([_dirStack count] > 0) [_dirStack removeLastObject];
  if ([_langStack count] > 0) [_langStack removeLastObject];
  id d = [_dirStack lastObject];
  id l = [_langStack lastObject];
  _currentDir = ([d isKindOfClass:[NSString class]]) ? d : nil;
  _currentLang = ([l isKindOfClass:[NSString class]]) ? l : nil;

  if ([e isEqualToString:@"b"] || [e isEqualToString:@"strong"]) { [self popTrait:NSBoldFontMask]; return; }
  if ([e isEqualToString:@"i"] || [e isEqualToString:@"em"]) { [self popTrait:NSItalicFontMask]; return; }
  if ([e isEqualToString:@"u"]) { return; }
  if ([e isEqualToString:@"script"] || [e isEqualToString:@"style"]) { [self popIgnore]; return; }
  if ([e isEqualToString:@"head"]) { [self popIgnore]; return; }
  if ([e hasPrefix:@"h"] && [e length] == 2) { [self popTrait:NSBoldFontMask]; [self popSize]; [self finalizeBlock]; [self appendBlankLine]; return; }
  if ([e isEqualToString:@"p"] || [e isEqualToString:@"div"] || [e isEqualToString:@"li"] || [e isEqualToString:@"blockquote"]) {
    [self finalizeBlock]; [self appendBlankLine]; return;
  }
}

- (void)appendBlankLine
{
  if (![self ignoring])
    [_out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
  if ([self ignoring]) return;
  if ([string length] == 0) return;
  string = [self sanitizeString:string];
  NSDictionary *attrs = @{ NSFontAttributeName: [self currentFont] };
  NSAttributedString *a = [[NSAttributedString alloc] initWithString:string attributes:attrs];
  [_out appendAttributedString:a];
}

// WHY this exists: GNUstep's glyph drawing crashes (an objc_msgSend_fpret
// ABI mismatch in the font-fallback path) when it must render typographic
// Unicode such as the bullet or em-dash, because the base font lacks those
// glyphs and fallback misdispatches. We map the common cases to ASCII so the
// page renders instead of segfaulting.
- (NSString *)sanitizeString:(NSString *)s
{
  if (s == nil) return s;
  struct { unichar from; NSString *to; } map[] = {
    { 0x2014, @"--" }, { 0x2013, @"-" },
    { 0x2018, @"'" },  { 0x2019, @"'" },
    { 0x201B, @"'" },  { 0x201C, @"\"" }, { 0x201D, @"\"" }, { 0x201F, @"\"" },
    { 0x2026, @"..." }, { 0x00A0, @" " }, { 0x2022, @"-" },
    { 0x2032, @"'" }, { 0x2033, @"\"" },
  };
  for (size_t i = 0; i < sizeof(map) / sizeof(map[0]); i++)
    {
      NSString *from = [NSString stringWithCharacters:&map[i].from length:1];
      s = [s stringByReplacingOccurrencesOfString:from withString:map[i].to];
    }
  return s;
}

- (void)appendAltText:(NSString *)alt
{
  if (alt == nil || [alt length] == 0) return;
  NSDictionary *attrs = @{ NSFontAttributeName: [self currentFont] };
  NSAttributedString *a = [[NSAttributedString alloc] initWithString:alt
                                                         attributes:attrs];
  [_out appendAttributedString:a];
}

- (void)appendImageWithAttributes:(NSDictionary *)attrs
{
  if ([self ignoring]) return;
  NSString *src = attrs[@"src"];
  NSString *alt = attrs[@"alt"];

  // EPUB RS 3.3, 5.1.2: an image without a resolvable source (or one that
  // cannot be loaded) falls back to its alternate text. A decorative image
  // carries an empty alt and must render nothing.
  if (src == nil || [src length] == 0)
    {
      [self appendAltText:alt];
      return;
    }

  NSURL *url = [NSURL URLWithString:src relativeToURL:_base];
  if (url == nil)
    {
      [self appendAltText:alt];
      return;
    }

  NSImage *img = nil;
  NSString *scheme = [url scheme];
  if ([scheme isEqualToString:@"data"])
    {
      // EPUB RS 3.3, 3.4: data: URLs are acceptable only as embedded content
      // (never as navigation, which this reader does not perform).
      img = [[NSImage alloc] initWithContentsOfURL:url];
    }
  else
    {
      // file: scheme covers both relative references (resolved against the
      // in-container _base) and absolute file: URLs. EPUB RS 3.3, 3.5 / 4.1.1:
      // constrain every such path to the container root so a reference like
      // file:///etc/passwd or ../../../secret cannot escape the publication.
      // Remote schemes (http/https/...) are not fetched (no network access).
      if (scheme != nil && ![scheme isEqualToString:@"file"])
        {
          [self appendAltText:alt];
          return;
        }
      NSString *path = [url path];
      if (path == nil)
        {
          [self appendAltText:alt];
          return;
        }
      if (_containerRoot != nil)
        {
          NSString *std = [path stringByStandardizingPath];
          NSString *root = [_containerRoot path];
          if (![std hasPrefix:root] && ![std hasPrefix:[root stringByAppendingString:@"/"]])
            {
              [self appendAltText:alt];
              return;
            }
        }
      img = [[NSImage alloc] initWithContentsOfFile:path];
    }

  if (img == nil)
    {
      [self appendAltText:alt];
      return;
    }

  NSData *tiff = [img TIFFRepresentation];
  if (tiff == nil)
    {
      [self appendAltText:alt];
      return;
    }
  NSFileWrapper *fw = [[NSFileWrapper alloc] initRegularFileWithContents:tiff];
  NSTextAttachment *att = [[NSTextAttachment alloc] initWithFileWrapper:fw];
  // WHY a custom cell: GNUstep draws a default NSTextAttachment by rendering
  // its NSImage, which crashes (bestRepresentationForRect fpret bug). Our cell
  // blits the image's bitmap representation directly, avoiding NSImage drawing.
  // The cell also scales the bitmap to the available line width so an image
  // wider than the page is shrunk to fit (EPUB RS 3.3, 3.1).
  BooksImageAttachmentCell *cell = [[BooksImageAttachmentCell alloc] init];
  [att setAttachmentCell:cell];
  // EPUB RS 3.3, 3.1: images are inline by default and flow within their
  // containing block at the point where they occur; they are NOT forced onto
  // their own paragraph. The layout manager asks the cell for its frame, and
  // the cell reports a size scaled to the available space (preserving aspect
  // ratio), so the picture sits inline with the surrounding text.
  unichar ch = 0xfffc;
  NSString *attStr = [NSString stringWithCharacters:&ch length:1];
  NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] initWithString:attStr];
  [mas addAttribute:NSAttachmentAttributeName value:att range:NSMakeRange(0, 1)];
  [_out appendAttributedString:mas];
}

- (NSMutableParagraphStyle *)headingStyle:(NSTextAlignment)align
{
  NSMutableParagraphStyle *p = [self defaultParagraph];
  [p setAlignment:align];
  [p setParagraphSpacingBefore:10];
  [p setParagraphSpacing:6];
  return p;
}

@end

#pragma mark - Safe image attachment cell

@implementation BooksImageAttachmentCell

// WHY override setAttachment: GNUstep only loads the wrapped image into the
// cell when the cell was NOT explicitly set (NSTextAttachment.m:307). Because
// we install our own cell, the image is never copied in, so [self image] is
// nil and nothing draws. Pull the image out of the file wrapper here.
- (void)setAttachment:(NSTextAttachment *)anObject
{
  [super setAttachment:anObject];
  NSFileWrapper *fw = [anObject fileWrapper];
  if (fw != nil && [fw isRegularFile])
    {
      NSData *d = [fw regularFileContents];
      if (d != nil)
        {
          NSImage *img = [[NSImage alloc] initWithData:d];
          if (img != nil) [self setImage:img];
        }
    }
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)aView
{
  [self _safeDraw:cellFrame];
}

- (void)drawWithFrame:(NSRect)cellFrame
               inView:(NSView *)aView
       characterIndex:(NSUInteger)charIndex
{
  [self _safeDraw:cellFrame];
}

- (void)drawWithFrame:(NSRect)cellFrame
               inView:(NSView *)aView
       characterIndex:(NSUInteger)charIndex
        layoutManager:(NSLayoutManager *)layoutManager
{
  [self _safeDraw:cellFrame];
}

// WHY: draw the image's bitmap representation directly. NSImage drawInRect
// crashes on this GNUstep runtime, so we use the underlying NSBitmapImageRep,
// whose own drawInRect blits pixel data without the broken NSImage path.
- (void)_safeDraw:(NSRect)frame
{
  NSImage *img = [self image];
  if (img == nil) return;
  NSBitmapImageRep *rep = nil;
  for (NSImageRep *r in [img representations])
    {
      if ([r isKindOfClass:[NSBitmapImageRep class]])
        {
          rep = (NSBitmapImageRep *)r;
          break;
        }
    }
  if (rep == nil)
    {
      NSData *d = [img TIFFRepresentation];
      if (d != nil) rep = [[NSBitmapImageRep alloc] initWithData:d];
    }
  if (rep == nil) return;
  [rep drawInRect:frame
          fromRect:NSZeroRect
         operation:NSCompositeSourceOver
          fraction:1.0
     respectFlipped:YES
           hints:nil];
}

// Intrinsic pixel size of the attached image, used to compute the scaled
// frame. Pixel dimensions are preferred over the nominal NSImage size so the
// scale is correct regardless of the image's embedded DPI.
- (NSSize)naturalSize
{
  NSImage *img = [self image];
  if (img == nil) return NSZeroSize;
  for (NSImageRep *r in [img representations])
    {
      if ([r isKindOfClass:[NSBitmapImageRep class]])
        return NSMakeSize([(NSBitmapImageRep *)r pixelsWide],
                          [(NSBitmapImageRep *)r pixelsHigh]);
    }
  return [img size];
}

// WHY override cellFrame: the layout manager reserves space for an attachment
// from this rect. The default returns the image's intrinsic size, so a picture
// wider than the page overflows (and is clipped). EPUB RS 3.3, 3.1 requires a
// Reading System to scale an image to fit the available space while preserving
// its aspect ratio; we do exactly that here, using the line fragment's width as
// the available width and the text container's height as the available height,
// and we never upscale beyond the intrinsic size so small images are not blurred.
- (NSRect)cellFrameForTextContainer:(NSTextContainer *)textContainer
                 proposedLineFragment:(NSRect)lineFrag
                       glyphPosition:(NSPoint)position
                    characterIndex:(NSUInteger)charIndex
{
  NSSize natural = [self naturalSize];
  if (natural.width <= 0.0 || natural.height <= 0.0)
    return [super cellFrameForTextContainer:textContainer
                        proposedLineFragment:lineFrag
                              glyphPosition:position
                           characterIndex:charIndex];

  CGFloat maxW = lineFrag.size.width;
  if (maxW <= 0.0 && textContainer != nil)
    maxW = [textContainer containerSize].width;
  CGFloat maxH = (textContainer != nil)
    ? [textContainer containerSize].height
    : lineFrag.size.height;

  CGFloat w = natural.width;
  CGFloat h = natural.height;
  if (w > maxW)
    {
      CGFloat s = maxW / w;
      w *= s; h *= s;
    }
  if (h > maxH)
    {
      CGFloat s = maxH / h;
      h *= s; w *= s;
    }
  // Do not upscale beyond the intrinsic size.
  if (w > natural.width)
    {
      w = natural.width; h = natural.height;
    }
  // Bottom-align the picture to the text baseline, matching the default cell.
  return NSMakeRect(0.0, 0.0, w, h);
}

@end

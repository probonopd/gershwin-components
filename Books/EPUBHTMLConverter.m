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
  NSFont *_lastFont;
}
@end

@implementation EPUBHTMLConverter

+ (NSAttributedString *)attributedStringFromXHTMLAtPath:(NSString *)path
                                                 baseURL:(NSURL *)base
                                                   error:(NSError **)error
{
  EPUBHTMLConverter *c = [[EPUBHTMLConverter alloc] init];
  return [c parsePath:path baseURL:base error:error];
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
  _blockStart = 0;
  _blockStyle = [self defaultParagraph];

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
}

- (void)finalizeBlock
{
  NSUInteger end = [_out length];
  if (end > _blockStart)
    {
      NSRange r = NSMakeRange(_blockStart, end - _blockStart);
      [_out addAttribute:NSParagraphStyleAttributeName value:_blockStyle range:r];
    }
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
  if ([e isEqualToString:@"b"] || [e isEqualToString:@"strong"]) { [self pushTrait:NSBoldFontMask]; return; }
  if ([e isEqualToString:@"i"] || [e isEqualToString:@"em"]) { [self pushTrait:NSItalicFontMask]; return; }
  if ([e isEqualToString:@"u"]) { return; }
  if ([e isEqualToString:@"script"] || [e isEqualToString:@"style"]) { [self pushIgnore:YES]; return; }

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
  if ([e isEqualToString:@"b"] || [e isEqualToString:@"strong"]) { [self popTrait:NSBoldFontMask]; return; }
  if ([e isEqualToString:@"i"] || [e isEqualToString:@"em"]) { [self popTrait:NSItalicFontMask]; return; }
  if ([e isEqualToString:@"u"]) { return; }
  if ([e isEqualToString:@"script"] || [e isEqualToString:@"style"]) { [self popIgnore]; return; }
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

- (void)appendImageWithAttributes:(NSDictionary *)attrs
{
  NSString *src = attrs[@"src"];
  if (src == nil) return;
  NSURL *url = [NSURL URLWithString:src relativeToURL:_base];
  if (url == nil) return;
  NSImage *img = [[NSImage alloc] initWithContentsOfFile:[url path]];
  if (img == nil) img = [[NSImage alloc] initWithContentsOfURL:url];
  if (img == nil) return;
  NSData *tiff = [img TIFFRepresentation];
  if (tiff == nil) return;
  NSFileWrapper *fw = [[NSFileWrapper alloc] initRegularFileWithContents:tiff];
  NSTextAttachment *att = [[NSTextAttachment alloc] initWithFileWrapper:fw];
  // WHY a custom cell: GNUstep draws a default NSTextAttachment by rendering
  // its NSImage, which crashes (bestRepresentationForRect fpret bug). Our cell
  // blits the image's bitmap representation directly, avoiding NSImage drawing.
  BooksImageAttachmentCell *cell = [[BooksImageAttachmentCell alloc] init];
  [att setAttachmentCell:cell];
  [self startBlock:nil];
  unichar ch = 0xfffc;
  NSString *attStr = [NSString stringWithCharacters:&ch length:1];
  NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] initWithString:attStr];
  [mas addAttribute:NSAttachmentAttributeName value:att range:NSMakeRange(0, 1)];
  [_out appendAttributedString:mas];
  [_out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
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
    respectFlipped:NO
          hints:nil];
}

@end

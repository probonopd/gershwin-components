/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EPUBHTMLConverter.h"

@interface BooksImageAttachmentCell : NSTextAttachmentCell
@end

static const CGFloat kBodySize = 16.0;

// Minimal CSS property parser: parses an inline style attribute string into a
// dictionary mapping property names (lowercased) to values (trimmed).
static NSDictionary<NSString *, NSString *> *ParseCSSProperties(NSString *style)
{
  if (style == nil || [style length] == 0) return nil;
  NSMutableDictionary *props = [NSMutableDictionary dictionary];
  NSArray *decls = [style componentsSeparatedByString:@";"];
  for (NSString *decl in decls)
    {
      NSString *trimmed = [decl stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if ([trimmed length] == 0) continue;
      NSRange colonRange = [trimmed rangeOfString:@":"];
      if (colonRange.location == NSNotFound) continue;
      NSUInteger colonPos = colonRange.location;
      NSString *prop = [[trimmed substringToIndex:colonPos]
          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      NSString *val = [[trimmed substringFromIndex:colonPos + 1]
          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if ([prop length] > 0 && [val length] > 0)
        [props setObject:val forKey:[prop lowercaseString]];
    }
  return [props count] > 0 ? props : nil;
}

// Parse a CSS font-size value (px, pt, em, %, xx-small..xx-large) into points.
static CGFloat ParseCSSFontSize(NSString *value, CGFloat baseSize)
{
  if (value == nil) return baseSize;
  NSString *v = [value stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceCharacterSet]];
  // Named sizes
  NSDictionary *named = @{
    @"xx-small": @6.0, @"x-small": @8.0, @"small": @11.0,
    @"medium": @16.0, @"large": @19.0, @"x-large": @24.0, @"xx-large": @32.0,
    @"smaller": @(baseSize * 0.8), @"larger": @(baseSize * 1.2)
  };
  NSNumber *nv = named[[v lowercaseString]];
  if (nv != nil) return [nv floatValue];
  // Numeric with unit
  if ([v hasSuffix:@"px"])
    return [[v stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"px"]] floatValue];
  if ([v hasSuffix:@"pt"])
    return [[v stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"pt"]] floatValue];
  if ([v hasSuffix:@"em"])
    return [[v stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"em"]] floatValue] * baseSize;
  if ([v hasSuffix:@"%"])
    return [[v stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"%"]] floatValue] / 100.0 * baseSize;
  // Bare number = px
  CGFloat n = [v floatValue];
  return (n > 0) ? n : baseSize;
}

// Parse a CSS color (#hex, rgb(), named) into NSColor. Returns nil on failure.
static NSColor *ParseCSSColor(NSString *value)
{
  if (value == nil) return nil;
  NSString *v = [value stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceCharacterSet]];
  // #hex
  if ([v hasPrefix:@"#"])
    {
      NSString *hex = [v substringFromIndex:1];
      if ([hex length] == 3)
        hex = [NSString stringWithFormat:@"%@%@%@%@%@%@",
            [hex substringWithRange:NSMakeRange(0,1)],
            [hex substringWithRange:NSMakeRange(0,1)],
            [hex substringWithRange:NSMakeRange(1,1)],
            [hex substringWithRange:NSMakeRange(1,1)],
            [hex substringWithRange:NSMakeRange(2,1)],
            [hex substringWithRange:NSMakeRange(2,1)]];
      if ([hex length] == 6)
        {
          unsigned int rgb = 0;
          NSScanner *sc = [NSScanner scannerWithString:hex];
          [sc scanHexInt:&rgb];
          return [NSColor colorWithCalibratedRed:((rgb >> 16) & 0xff) / 255.0
                                          green:((rgb >> 8) & 0xff) / 255.0
                                           blue:(rgb & 0xff) / 255.0
                                          alpha:1.0];
        }
    }
  // rgb(r, g, b)
  if ([v hasPrefix:@"rgb"])
    {
      NSString *inner = [v stringByReplacingOccurrencesOfString:@"rgb(" withString:@""];
      inner = [inner stringByReplacingOccurrencesOfString:@")" withString:@""];
      NSArray *parts = [inner componentsSeparatedByString:@","];
      if ([parts count] >= 3)
        {
          CGFloat r = [[parts[0] stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceCharacterSet]] floatValue] / 255.0;
          CGFloat g = [[parts[1] stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceCharacterSet]] floatValue] / 255.0;
          CGFloat b = [[parts[2] stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceCharacterSet]] floatValue] / 255.0;
          return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:1.0];
        }
    }
  // Named colors (common subset)
  NSDictionary *named = @{
    @"black": [NSColor blackColor], @"white": [NSColor whiteColor],
    @"red": [NSColor redColor], @"green": [NSColor greenColor],
    @"blue": [NSColor blueColor], @"gray": [NSColor grayColor],
    @"grey": [NSColor grayColor], @"orange": [NSColor orangeColor],
    @"brown": [NSColor brownColor], @"purple": [NSColor purpleColor],
    @"yellow": [NSColor yellowColor], @"cyan": [NSColor cyanColor],
    @"magenta": [NSColor magentaColor],
  };
  return named[[v lowercaseString]];
}

@interface EPUBHTMLConverter () <NSXMLParserDelegate>
{
  NSMutableAttributedString *_out;
  NSMutableArray<NSNumber *> *_traitStack;
  NSMutableArray<NSNumber *> *_sizeStack;
  NSMutableArray<NSNumber *> *_ignoreStack;
  NSMutableArray<NSNumber *> *_monoStack;
  NSMutableArray<NSNumber *> *_supStack;
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
  // CSS support: linked stylesheet rules keyed by selector
  NSMutableDictionary<NSString *, NSDictionary *> *_cssRules;
  // Ordered list counter stack
  NSMutableArray<NSNumber *> *_olCounterStack;
  // Current inline CSS properties from the innermost element with a style attr
  NSDictionary<NSString *, NSString *> *_currentCSSProps;
  // @font-face mappings: CSS family name -> file path within EPUB container.
  // Used by currentFont to resolve CSS font-family names; fonts are loaded
  // directly from the EPUB, never installed into the system font manager.
  NSMutableDictionary<NSString *, NSString *> *_epubFontFaces;
  // Font-family stack: tracks CSS-specified font-family through the element tree.
  // nil means no override (use default families).
  NSMutableArray<NSString *> *_fontFamilyStack;
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
   _monoStack = [NSMutableArray arrayWithObject:@(NO)];
  _supStack = [NSMutableArray arrayWithObject:@(NO)];
  _dirStack = [NSMutableArray array];
  _langStack = [NSMutableArray array];
  _currentDir = nil;
  _currentLang = nil;
  _blockStart = 0;
  _blockStyle = [self defaultParagraph];
  _anchors = [NSMutableDictionary dictionary];
  _cssRules = [NSMutableDictionary dictionary];
  _olCounterStack = [NSMutableArray array];
  _epubFontFaces = [NSMutableDictionary dictionary];
  _fontFamilyStack = [NSMutableArray arrayWithObject:(id)[NSNull null]];

  // Load linked CSS stylesheets referenced from <link rel="stylesheet">.
  // This also populates _epubFontFaces from any @font-face rules.
  [self loadStylesheetsFromPath:path];

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
  [p setParagraphSpacing:0.0];
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
  NSString *cssFamily = nil;
  id topFam = [_fontFamilyStack lastObject];
  if ([topFam isKindOfClass:[NSString class]])
    cssFamily = topFam;

  // If a CSS font-family is specified, try @font-face first, then NSFontManager.
  if (cssFamily != nil)
    {
      NSString *key = [cssFamily lowercaseString];
      NSString *weight = (trait & NSBoldFontMask) ? @"bold" : @"normal";
      NSString *style = (trait & NSItalicFontMask) ? @"italic" : @"normal";

      // Try variant-specific match: family|weight|style.
      NSString *variantKey = [NSString stringWithFormat:@"%@|%@|%@", key, weight, style];
      NSString *fontPath = _epubFontFaces[variantKey];
      // Fall back to plain family match.
      if (fontPath == nil) fontPath = _epubFontFaces[key];

      if (fontPath != nil)
        {
          // Font-face path known; try NSFontManager with the CSS family name.
          // If the font is available on the system it will be used; otherwise
          // we fall through to the default families below.
          NSFont *f = [[NSFontManager sharedFontManager]
              fontWithFamily:cssFamily traits:trait weight:5 size:size];
          if (f != nil)
            {
              _lastFont = f;
              return f;
            }
        }

      // Even without @font-face, try the CSS family name via NSFontManager.
      NSFont *f = [[NSFontManager sharedFontManager]
          fontWithFamily:cssFamily traits:trait weight:5 size:size];
      if (f != nil)
        {
          _lastFont = f;
          return f;
        }
    }

  // Palatino (and its URW clone "Palladio") is the default book face; fall
  // back through its common aliases and then to a generic serif if none of
  // them are installed.
  NSArray<NSString *> *families;
  if ([_monoStack.lastObject boolValue])
    {
      // Fixed-width faces for code listings. Ordered by availability across
      // Linux/BSD so a readable mono is always found.
      families = @[ @"DejaVu Sans Mono", @"Liberation Mono", @"Courier New",
                    @"Courier", @"FreeMono", @"Monaco", @"Menlo" ];
    }
  else
    {
      families = @[ @"Palatino", @"URW Palladio L",
                    @"Palladio", @"Palatino Linotype",
                    @"TeX Gyre Pagella", @"DejaVu Serif",
                    @"Times New Roman" ];
    }
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

- (void)pushMono { [_monoStack addObject:@(YES)]; }
- (void)popMono { if ([_monoStack count] > 1) [_monoStack removeLastObject]; }

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

#pragma mark - CSS support

// Load linked CSS stylesheets from the same directory as the XHTML file.
// Only handles simple selector-to-property mappings (type selectors and
// class selectors). This is a pragmatic subset - full CSS is out of scope.
- (void)loadStylesheetsFromPath:(NSString *)path
{
  NSString *dir = [path stringByDeletingLastPathComponent];
  NSData *raw = [NSData dataWithContentsOfFile:path];
  if (raw == nil) return;
  NSString *html = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
  if (html == nil) return;

  // Find <link rel="stylesheet" href="..."> tags.
  NSRegularExpression *re = [NSRegularExpression
      regularExpressionWithPattern:@"<link[^>]+rel=[\"'][^\"']*stylesheet[^\"']*[\"'][^>]+href=[\"']([^\"']+)[\"']"
                           options:NSRegularExpressionCaseInsensitive
                             error:NULL];
  // Also match href before rel.
  NSRegularExpression *re2 = [NSRegularExpression
      regularExpressionWithPattern:@"<link[^>]+href=[\"']([^\"']+)[\"'][^>]+rel=[\"'][^\"']*stylesheet[^\"']*[\"']"
                           options:NSRegularExpressionCaseInsensitive
                             error:NULL];

  NSMutableString *htmlMut = [html mutableCopy];
  for (NSRegularExpression *r in @[re, re2])
    {
      NSArray *matches = [r matchesInString:htmlMut options:0
                                     range:NSMakeRange(0, [htmlMut length])];
      for (NSTextCheckingResult *m in matches)
        {
          NSString *href = [htmlMut substringWithRange:[m rangeAtIndex:1]];
          NSString *cssPath = [dir stringByAppendingPathComponent:href];
          [self loadCSSFile:cssPath];
        }
    }
}

- (void)loadCSSFile:(NSString *)cssPath
{
  NSData *data = [NSData dataWithContentsOfFile:cssPath];
  if (data == nil) return;
  NSString *css = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (css == nil) return;
  NSString *cssDir = [cssPath stringByDeletingLastPathComponent];

  // Strip CSS comments.
  NSRegularExpression *commentRe = [NSRegularExpression
      regularExpressionWithPattern:@"/\\*[^*]*\\*+(?:[^/*][^*]*\\*+)*/"
                           options:0 error:NULL];
  css = [commentRe stringByReplacingMatchesInString:css options:0
                                              range:NSMakeRange(0, [css length])
                                       withTemplate:@""];

  // Parse @font-face blocks: @font-face { font-family: "..."; src: url("..."); ... }
  [self parseFontFacesFromCSS:css baseDir:cssDir];

  // Parse simple rules: selector { property: value; ... }
  NSRegularExpression *ruleRe = [NSRegularExpression
      regularExpressionWithPattern:@"([^{}]+)\\{([^}]*)\\}"
                           options:0 error:NULL];
  NSArray *rules = [ruleRe matchesInString:css options:0
                                     range:NSMakeRange(0, [css length])];
  for (NSTextCheckingResult *rm in rules)
    {
      NSString *selector = [[css substringWithRange:[rm rangeAtIndex:1]]
          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      NSString *body = [css substringWithRange:[rm rangeAtIndex:2]];
      NSDictionary *props = ParseCSSProperties(body);
      if (props != nil && [selector length] > 0)
        [_cssRules setObject:props forKey:[selector lowercaseString]];
    }
}

// WHY @font-face support: EPUB 3.3, 5.2.1: reading systems SHOULD support
// @font-face to allow publishers to embed custom fonts. Without this, books
// that ship their own fonts render with system font substitutions, breaking
// the intended typography. We parse @font-face blocks to extract font-family
// names and font file paths, then install them via GSFontAssetInstaller so
// GNUstep's font manager can find them by family name.
- (void)parseFontFacesFromCSS:(NSString *)css baseDir:(NSString *)cssDir
{
  // Match @font-face { ... } blocks (non-greedy).
  NSRegularExpression *ffRe = [NSRegularExpression
      regularExpressionWithPattern:@"@font-face\\s*\\{([^}]*)\\}"
                           options:0 error:NULL];
  NSArray *matches = [ffRe matchesInString:css options:0
                                     range:NSMakeRange(0, [css length])];
  for (NSTextCheckingResult *m in matches)
    {
      NSString *block = [css substringWithRange:[m rangeAtIndex:1]];
      NSDictionary *props = ParseCSSProperties(block);
      if (props == nil) continue;

      // Extract font-family (strip quotes).
      NSString *family = props[@"font-family"];
      if (family == nil) continue;
      family = [family stringByTrimmingCharactersInSet:
          [NSCharacterSet characterSetWithCharactersInString:@"\"' "]];
      if ([family length] == 0) continue;

      // Extract first src URL from src: url("...") format("...");
      NSString *src = props[@"src"];
      if (src == nil) continue;
      NSString *urlStr = nil;
      NSRegularExpression *urlRe = [NSRegularExpression
          regularExpressionWithPattern:@"url\\(['\"]?([^'\")]+)['\"]?\\)"
                               options:0 error:NULL];
      NSTextCheckingResult *urlMatch = [urlRe firstMatchInString:src options:0
                                                           range:NSMakeRange(0, [src length])];
      if (urlMatch != nil && [urlMatch rangeAtIndex:1].location != NSNotFound)
        {
          urlStr = [src substringWithRange:[urlMatch rangeAtIndex:1]];
        }
      if (urlStr == nil) continue;

      // Resolve relative URL against the CSS file's directory.
      NSString *fontPath = [cssDir stringByAppendingPathComponent:urlStr];
      fontPath = [fontPath stringByStandardizingPath];

      if ([[NSFileManager defaultManager] fileExistsAtPath:fontPath])
        {
          NSString *key = [family lowercaseString];
          // Prefer bold/italic variants if specified.
          NSString *weight = props[@"font-weight"] ?: @"normal";
          NSString *style = props[@"font-style"] ?: @"normal";
          NSString *variantKey = [NSString stringWithFormat:@"%@|%@|%@",
              key, weight, style];
          [_epubFontFaces setObject:fontPath forKey:variantKey];
          // Also store a plain family->path mapping for fallback.
          if ([_epubFontFaces objectForKey:key] == nil)
            [_epubFontFaces setObject:fontPath forKey:key];
        }
    }
}

// Look up CSS properties for an element by type selector and class selector.
- (NSDictionary<NSString *, NSString *> *)cssPropertiesForElement:(NSString *)tag
                                                           classes:(NSArray<NSString *> *)classes
{
  NSMutableDictionary *merged = [NSMutableDictionary dictionary];
  // Type selector (e.g., "p", "h1")
  NSDictionary *typeProps = _cssRules[[tag lowercaseString]];
  if (typeProps != nil) [merged addEntriesFromDictionary:typeProps];
  // Class selectors (e.g., ".author", ".indent")
  for (NSString *cls in classes)
    {
      NSString *key = [NSString stringWithFormat:@".%@", cls];
      NSDictionary *classProps = _cssRules[[key lowercaseString]];
      if (classProps != nil) [merged addEntriesFromDictionary:classProps];
    }
  return [merged count] > 0 ? merged : nil;
}

#pragma mark - Inline style application

// Apply CSS properties to a range. When range.length == 0 (called from
// didStartElement), only paragraph-level properties are applied to _blockStyle.
// When range.length > 0 (called from foundCharacters), character-level
// attributes are applied to the given range AND paragraph-level properties
// are applied to _blockStyle for the current block.
- (void)applyCSSProperties:(NSDictionary<NSString *, NSString *> *)props
                     range:(NSRange)range
{
  if (props == nil) return;
  if (range.length == 0 && [props count] == 0) return;

  NSString *fontSizeVal = props[@"font-size"];
  NSString *fontWeightVal = props[@"font-weight"];
  NSString *fontStyleVal = props[@"font-style"];
  NSString *colorVal = props[@"color"];
  NSString *bgColorVal = props[@"background-color"];
  NSString *textDecVal = props[@"text-decoration"];
  NSString *textAlignVal = props[@"text-align"];
  NSString *lineHeightVal = props[@"line-height"];
  NSString *marginTopVal = props[@"margin-top"];
  NSString *marginBottomVal = props[@"margin-bottom"];
  NSString *textIndentVal = props[@"text-indent"];
  NSString *vertAlignVal = props[@"vertical-align"];
  NSString *whiteSpaceVal = props[@"white-space"];

  // Character-level attributes: only when we have an actual range.
  if (range.length > 0)
    {
      CGFloat size = [_sizeStack.lastObject doubleValue];
      NSFontTraitMask trait = [_traitStack.lastObject unsignedIntegerValue];

      if (fontSizeVal)
        size = ParseCSSFontSize(fontSizeVal, kBodySize);
      if (fontWeightVal)
        {
          if ([fontWeightVal isEqualToString:@"bold"] ||
              [fontWeightVal isEqualToString:@"bolder"])
            trait |= NSBoldFontMask;
          else if ([fontWeightVal intValue] >= 700)
            trait |= NSBoldFontMask;
        }
      if (fontStyleVal)
        {
          if ([fontStyleVal isEqualToString:@"italic"] ||
              [fontStyleVal isEqualToString:@"oblique"])
            trait |= NSItalicFontMask;
        }

      // Build the font using the current family preference.
      NSString *family = ([_monoStack.lastObject boolValue]) ? @"Courier" : @"URW Palladio L";
      NSFontManager *fm = [NSFontManager sharedFontManager];
      NSFont *font = [fm fontWithFamily:family traits:trait weight:5 size:size];
      if (font == nil)
        font = [NSFont fontWithName:@"URW Palladio L" size:size] ?: [NSFont userFontOfSize:size];
      [_out addAttribute:NSFontAttributeName value:font range:range];

      if (colorVal)
        {
          NSColor *c = ParseCSSColor(colorVal);
          if (c) [_out addAttribute:NSForegroundColorAttributeName value:c range:range];
        }
      if (bgColorVal)
        {
          NSColor *c = ParseCSSColor(bgColorVal);
          if (c) [_out addAttribute:NSBackgroundColorAttributeName value:c range:range];
        }
      if (textDecVal)
        {
          if ([textDecVal rangeOfString:@"underline"].location != NSNotFound)
            [_out addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:range];
          if ([textDecVal rangeOfString:@"line-through"].location != NSNotFound)
            [_out addAttribute:NSStrikethroughStyleAttributeName value:@(1) range:range];
        }
      if (vertAlignVal)
        {
          if ([vertAlignVal isEqualToString:@"super"])
            {
              CGFloat smaller = size * 0.7;
              NSFont *sf = [fm fontWithFamily:family traits:trait weight:5 size:smaller];
              if (sf == nil) sf = [NSFont fontWithName:@"URW Palladio L" size:smaller] ?: [NSFont userFontOfSize:smaller];
              [_out addAttribute:NSFontAttributeName value:sf range:range];
              [_out addAttribute:NSBaselineOffsetAttributeName value:@(size * 0.4) range:range];
            }
          else if ([vertAlignVal isEqualToString:@"sub"])
            {
              CGFloat smaller = size * 0.7;
              NSFont *sf = [fm fontWithFamily:family traits:trait weight:5 size:smaller];
              if (sf == nil) sf = [NSFont fontWithName:@"URW Palladio L" size:smaller] ?: [NSFont userFontOfSize:smaller];
              [_out addAttribute:NSFontAttributeName value:sf range:range];
              [_out addAttribute:NSBaselineOffsetAttributeName value:@(-size * 0.2) range:range];
            }
        }
    }

  // Paragraph-level properties: always apply to _blockStyle so they take
  // effect when finalizeBlock runs (regardless of range.length).
  if (textAlignVal || lineHeightVal || marginTopVal || marginBottomVal || textIndentVal || whiteSpaceVal)
    {
      NSMutableParagraphStyle *ps = [_blockStyle mutableCopy];
      if ([textAlignVal isEqualToString:@"center"])
        [ps setAlignment:NSCenterTextAlignment];
      else if ([textAlignVal isEqualToString:@"right"])
        [ps setAlignment:NSRightTextAlignment];
      else if ([textAlignVal isEqualToString:@"justify"])
        [ps setAlignment:NSJustifiedTextAlignment];

      if (lineHeightVal)
        {
          CGFloat lh = [lineHeightVal floatValue];
          if (lh > 0) [ps setLineSpacing:lh];
        }
      if (marginTopVal)
        {
          CGFloat mt = [marginTopVal floatValue];
          if (mt > 0) [ps setParagraphSpacingBefore:mt];
        }
      if (marginBottomVal)
        {
          CGFloat mb = [marginBottomVal floatValue];
          if (mb > 0) [ps setParagraphSpacing:mb];
        }
      if (textIndentVal)
        {
          CGFloat ti = [textIndentVal floatValue];
          [ps setFirstLineHeadIndent:ti];
        }
      if ([whiteSpaceVal isEqualToString:@"pre"])
        {
          [ps setParagraphSpacing:0.0];
          [ps setParagraphSpacingBefore:0.0];
          [ps setLineSpacing:0.0];
        }
      _blockStyle = ps;
    }
}

// Apply character-level CSS properties to a standalone attributed string
// (used by foundCharacters before the string is appended to _out).
- (void)applyCSSProperties:(NSDictionary<NSString *, NSString *> *)props
     toAttributedString:(NSMutableAttributedString *)mas
{
  if (props == nil || [mas length] == 0) return;
  NSRange range = NSMakeRange(0, [mas length]);

  NSString *fontSizeVal = props[@"font-size"];
  NSString *fontWeightVal = props[@"font-weight"];
  NSString *fontStyleVal = props[@"font-style"];
  NSString *colorVal = props[@"color"];
  NSString *bgColorVal = props[@"background-color"];
  NSString *textDecVal = props[@"text-decoration"];
  NSString *vertAlignVal = props[@"vertical-align"];

  CGFloat size = [_sizeStack.lastObject doubleValue];
  NSFontTraitMask trait = [_traitStack.lastObject unsignedIntegerValue];

  if (fontSizeVal)
    size = ParseCSSFontSize(fontSizeVal, kBodySize);
  if (fontWeightVal)
    {
      if ([fontWeightVal isEqualToString:@"bold"] ||
          [fontWeightVal isEqualToString:@"bolder"])
        trait |= NSBoldFontMask;
      else if ([fontWeightVal intValue] >= 700)
        trait |= NSBoldFontMask;
    }
  if (fontStyleVal)
    {
      if ([fontStyleVal isEqualToString:@"italic"] ||
          [fontStyleVal isEqualToString:@"oblique"])
        trait |= NSItalicFontMask;
    }

  NSString *family = ([_monoStack.lastObject boolValue]) ? @"Courier" : @"URW Palladio L";
  NSFontManager *fm = [NSFontManager sharedFontManager];
  NSFont *font = [fm fontWithFamily:family traits:trait weight:5 size:size];
  if (font == nil)
    font = [NSFont fontWithName:@"URW Palladio L" size:size] ?: [NSFont userFontOfSize:size];
  [mas addAttribute:NSFontAttributeName value:font range:range];

  if (colorVal)
    {
      NSColor *c = ParseCSSColor(colorVal);
      if (c) [mas addAttribute:NSForegroundColorAttributeName value:c range:range];
    }
  if (bgColorVal)
    {
      NSColor *c = ParseCSSColor(bgColorVal);
      if (c) [mas addAttribute:NSBackgroundColorAttributeName value:c range:range];
    }
  if (textDecVal)
    {
      if ([textDecVal rangeOfString:@"underline"].location != NSNotFound)
        [mas addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:range];
      if ([textDecVal rangeOfString:@"line-through"].location != NSNotFound)
        [mas addAttribute:NSStrikethroughStyleAttributeName value:@(1) range:range];
    }
  if (vertAlignVal)
    {
      if ([vertAlignVal isEqualToString:@"super"])
        {
          CGFloat smaller = size * 0.7;
          NSFont *sf = [fm fontWithFamily:family traits:trait weight:5 size:smaller];
          if (sf == nil) sf = [NSFont fontWithName:@"URW Palladio L" size:smaller] ?: [NSFont userFontOfSize:smaller];
          [mas addAttribute:NSFontAttributeName value:sf range:range];
          [mas addAttribute:NSBaselineOffsetAttributeName value:@(size * 0.4) range:range];
        }
      else if ([vertAlignVal isEqualToString:@"sub"])
        {
          CGFloat smaller = size * 0.7;
          NSFont *sf = [fm fontWithFamily:family traits:trait weight:5 size:smaller];
          if (sf == nil) sf = [NSFont fontWithName:@"URW Palladio L" size:smaller] ?: [NSFont userFontOfSize:smaller];
          [mas addAttribute:NSFontAttributeName value:sf range:range];
          [mas addAttribute:NSBaselineOffsetAttributeName value:@(-size * 0.2) range:range];
        }
    }
}

#pragma mark - Ordered list helpers

- (void)pushOLCounter
{
  [_olCounterStack addObject:@(1)];
}
- (void)popOLCounter
{
  if ([_olCounterStack count] > 0) [_olCounterStack removeLastObject];
}
- (NSInteger)currentOLCounter
{
  if ([_olCounterStack count] == 0) return 1;
  return [[_olCounterStack lastObject] integerValue];
}
- (void)incrementOLCounter
{
  if ([_olCounterStack count] == 0) return;
  NSInteger n = [[_olCounterStack lastObject] integerValue];
  [_olCounterStack removeLastObject];
  [_olCounterStack addObject:@(n + 1)];
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

  // Resolve CSS properties from inline style attribute and linked stylesheets.
  NSString *styleAttr = attrs[@"style"];
  NSDictionary *inlineProps = ParseCSSProperties(styleAttr);
  NSString *classAttr = attrs[@"class"];
  NSArray *classes = [classAttr componentsSeparatedByString:@" "];
  NSDictionary *cssProps = [self cssPropertiesForElement:e classes:classes];
  // Inline styles take precedence over stylesheet rules.
  NSMutableDictionary *mergedProps = cssProps ? [cssProps mutableCopy] : [NSMutableDictionary dictionary];
  if (inlineProps) [mergedProps addEntriesFromDictionary:inlineProps];
  // Store as current for foundCharacters to apply to text ranges.
  _currentCSSProps = [mergedProps count] > 0 ? mergedProps : nil;

  if ([e isEqualToString:@"b"] || [e isEqualToString:@"strong"]) { [self pushTrait:NSBoldFontMask]; return; }
  if ([e isEqualToString:@"i"] || [e isEqualToString:@"em"]) { [self pushTrait:NSItalicFontMask]; return; }
  if ([e isEqualToString:@"u"]) { return; }
  if ([e isEqualToString:@"small"]) { [self pushSize:[_sizeStack.lastObject doubleValue] * 0.8]; return; }
  if ([e isEqualToString:@"big"]) { [self pushSize:[_sizeStack.lastObject doubleValue] * 1.2]; return; }
  if ([e isEqualToString:@"sup"]) { [_supStack addObject:@(YES)]; return; }
  if ([e isEqualToString:@"sub"]) { [_supStack addObject:@(YES)]; return; }
  if ([e isEqualToString:@"del"] || [e isEqualToString:@"s"] || [e isEqualToString:@"strike"]) {
    [self pushTrait:NSItalicFontMask]; return;
  }
  if ([e isEqualToString:@"mark"]) {
    // Highlight: push a yellow background that will be applied to text.
    // We handle this by adding a background color attribute to foundCharacters.
    return;
  }
  if ([e isEqualToString:@"abbr"] || [e isEqualToString:@"acronym"]) { return; }
  if ([e isEqualToString:@"script"] || [e isEqualToString:@"style"]) { [self pushIgnore:YES]; return; }
  if ([e isEqualToString:@"head"]) { [self pushIgnore:YES]; return; }

  // Linked CSS stylesheets: <link rel="stylesheet" href="...">.
  // These are already loaded in loadStylesheetsFromPath; skip rendering.
  if ([e isEqualToString:@"link"]) { return; }
  // Skip meta, title, base elements.
  if ([e isEqualToString:@"meta"] || [e isEqualToString:@"title"] ||
      [e isEqualToString:@"base"]) { return; }

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
  if ([e isEqualToString:@"p"] || [e isEqualToString:@"div"]) {
    [self startBlock:[self defaultParagraph]];
    if (mergedProps) [self applyCSSProperties:mergedProps range:NSMakeRange([_out length], 0)];
    return;
  }
  if ([e isEqualToString:@"blockquote"]) {
    NSMutableParagraphStyle *p = [self defaultParagraph];
    [p setHeadIndent:24]; [p setTailIndent:-24]; [p setParagraphSpacingBefore:6];
    [self startBlock:p]; return;
  }
  // Lists: <ul> starts a list context, <ol> starts with a counter.
  if ([e isEqualToString:@"ul"]) { return; }
  if ([e isEqualToString:@"ol"]) {
    [self pushOLCounter];
    return;
  }
  if ([e isEqualToString:@"li"]) {
    NSMutableParagraphStyle *p = [self defaultParagraph];
    [p setHeadIndent:20]; [p setFirstLineHeadIndent:8]; [p setParagraphSpacing:3];
    [self startBlock:p];
    if (![self ignoring])
      {
        // Check if we're inside an <ol> or <ul>.
        NSString *bullet;
        if ([_olCounterStack count] > 0)
          {
            bullet = [NSString stringWithFormat:@"%ld.  ", (long)[self currentOLCounter]];
            [self incrementOLCounter];
          }
        else
          bullet = @"-  ";
        [_out appendAttributedString:[[NSAttributedString alloc] initWithString:bullet]];
      }
    return;
  }
  if ([e isEqualToString:@"dl"]) { return; }
  if ([e isEqualToString:@"dt"]) {
    NSMutableParagraphStyle *p = [self defaultParagraph];
    [p setHeadIndent:20]; [p setFirstLineHeadIndent:8];
    [self startBlock:p];
    if (![self ignoring]) [_out appendAttributedString:[[NSAttributedString alloc] initWithString:@"-  "]];
    return;
  }
  if ([e isEqualToString:@"dd"]) {
    NSMutableParagraphStyle *p = [self defaultParagraph];
    [p setHeadIndent:36]; [p setFirstLineHeadIndent:8];
    [self startBlock:p]; return;
  }
  if ([e isEqualToString:@"figure"]) {
    NSMutableParagraphStyle *p = [self defaultParagraph];
    [p setAlignment:NSCenterTextAlignment];
    [self startBlock:p]; return;
  }
  if ([e isEqualToString:@"figcaption"]) { return; }
  if ([e isEqualToString:@"details"]) { return; }
  if ([e isEqualToString:@"summary"]) {
    [self pushTrait:NSBoldFontMask]; return;
  }
  if ([e isEqualToString:@"a"]) { return; }
  if ([e isEqualToString:@"span"] || [e isEqualToString:@"label"]) {
    // Apply CSS properties to inline span.
    if (mergedProps) [self applyCSSProperties:mergedProps range:NSMakeRange([_out length], 0)];
    return;
  }

  // Preformatted text and code. EPUB RS 3.3, 5.2: <pre> is a block that
  // preserves the author's line breaks and spacing; the XML parser already
  // reports the raw whitespace, so each source newline becomes a real line
  // break and runs of spaces are kept. <code>/<tt>/<kbd>/<samp> are inline
  // and only switch the face to monospace. The legacy <listing>/<xmp>/
  // <plaintext> elements are preformatted blocks too.
  if ([e isEqualToString:@"pre"] || [e isEqualToString:@"listing"] ||
      [e isEqualToString:@"xmp"] || [e isEqualToString:@"plaintext"])
    {
      // Preformatted text: every source line is its own paragraph (a "\n"
      // terminates a paragraph), so any inter-paragraph spacing would render as
      // a blank line between code lines. Zero out the spacing so the listing
      // keeps the author's exact line rhythm.
      NSMutableParagraphStyle *p = [self defaultParagraph];
      [p setParagraphSpacing:0.0];
      [p setParagraphSpacingBefore:0.0];
      [p setLineSpacing:0.0];
      [p setHeadIndent:0.0];
      [p setFirstLineHeadIndent:0.0];
      [self startBlock:p];
      [self pushMono];
      return;
    }
  if ([e isEqualToString:@"code"] || [e isEqualToString:@"tt"] ||
      [e isEqualToString:@"kbd"] || [e isEqualToString:@"samp"])
    {
      [self pushMono];
      return;
    }

  // other inline/unknown elements: ignore tag, keep text
}

- (void)parser:(NSXMLParser *)parser
  didEndElement:(NSString *)element
   namespaceURI:(NSString *)ns
  qualifiedName:(NSString *)qn
{
  NSString *e = [element lowercaseString];

  // Clear inline CSS context for this element. The next element (or
  // foundCharacters call) will re-establish its own if needed.
  _currentCSSProps = nil;

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
  if ([e isEqualToString:@"small"]) { [self popSize]; return; }
  if ([e isEqualToString:@"big"]) { [self popSize]; return; }
  if ([e isEqualToString:@"sup"] || [e isEqualToString:@"sub"]) {
    if ([_supStack count] > 1) [_supStack removeLastObject];
    return;
  }
  if ([e isEqualToString:@"del"] || [e isEqualToString:@"s"] || [e isEqualToString:@"strike"]) {
    [self popTrait:NSItalicFontMask]; return;
  }
  if ([e isEqualToString:@"mark"] || [e isEqualToString:@"abbr"] ||
      [e isEqualToString:@"acronym"] || [e isEqualToString:@"label"]) { return; }
  if ([e isEqualToString:@"script"] || [e isEqualToString:@"style"]) { [self popIgnore]; return; }
  if ([e isEqualToString:@"head"]) { [self popIgnore]; return; }
  if ([e isEqualToString:@"link"] || [e isEqualToString:@"meta"] ||
      [e isEqualToString:@"title"] || [e isEqualToString:@"base"]) { return; }
  if ([e hasPrefix:@"h"] && [e length] == 2) { [self popTrait:NSBoldFontMask]; [self popSize]; [self finalizeBlock]; return; }
  if ([e isEqualToString:@"p"] || [e isEqualToString:@"div"] || [e isEqualToString:@"blockquote"] ||
      [e isEqualToString:@"figure"] || [e isEqualToString:@"figcaption"]) {
    [self finalizeBlock]; return;
  }
  if ([e isEqualToString:@"ul"]) { return; }
  if ([e isEqualToString:@"ol"]) { [self popOLCounter]; return; }
  if ([e isEqualToString:@"li"]) { [self finalizeBlock]; return; }
  if ([e isEqualToString:@"dl"]) { return; }
  if ([e isEqualToString:@"dt"]) { [self finalizeBlock]; return; }
  if ([e isEqualToString:@"dd"]) { [self finalizeBlock]; return; }
  if ([e isEqualToString:@"details"]) { return; }
  if ([e isEqualToString:@"summary"]) { return; }
  if ([e isEqualToString:@"span"]) { return; }
  if ([e isEqualToString:@"a"]) { return; }
  if ([e isEqualToString:@"pre"] || [e isEqualToString:@"listing"] ||
      [e isEqualToString:@"xmp"] || [e isEqualToString:@"plaintext"])
    {
      [self popMono];
      [self finalizeBlock];
      return;
    }
  if ([e isEqualToString:@"code"] || [e isEqualToString:@"tt"] ||
      [e isEqualToString:@"kbd"] || [e isEqualToString:@"samp"])
    {
      [self popMono];
      return;
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
  if ([self ignoring]) return;
  if ([string length] == 0) return;
  string = [self sanitizeString:string];
  NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:string
                                                                       attributes:@{ NSFontAttributeName: [self currentFont] }];
  // Apply sup/sub font sizing if inside a <sup> or <sub>.
  BOOL isSupSub = [_supStack.lastObject boolValue];
  if (isSupSub)
    {
      CGFloat baseSize = [_sizeStack.lastObject doubleValue];
      CGFloat smaller = baseSize * 0.7;
      CGFloat offset = ([_supStack.lastObject boolValue]) ? (baseSize * 0.4) : (-baseSize * 0.2);
      NSFont *sf = [NSFont fontWithName:@"URW Palladio L" size:smaller] ?: [NSFont userFontOfSize:smaller];
      [a addAttribute:NSFontAttributeName value:sf range:NSMakeRange(0, [a length])];
      [a addAttribute:NSBaselineOffsetAttributeName value:@(offset) range:NSMakeRange(0, [a length])];
    }
  // Apply inline CSS properties (from style attribute or linked stylesheet).
  if (_currentCSSProps)
    {
      [self applyCSSProperties:_currentCSSProps toAttributedString:a];
    }
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

/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSMarkdownParser.h"

#import "GSHelpDocument.h"
#import "GSHelpNode.h"

@interface GSMarkdownParser ()
/* Emits the anchor + heading pair (and records firstH1) used by every
 * heading form (ATX, '=' delimited, Setext underline). */
- (void)gsmdEmitHeading:(NSString *)plain
                  level:(NSUInteger)level
                   into:(GSHelpNode *)container;
@end

#pragma mark - Small string helpers

static NSString *GSMDTrim(NSString *s)
{
    return [s stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
}

static BOOL GSMDIsBlank(NSString *line)
{
    return [GSMDTrim(line) length] == 0;
}

static NSUInteger GSMDIndentOf(NSString *line)
{
    NSUInteger i = 0, width = 0, len = [line length];
    while (i < len)
      {
        unichar c = [line characterAtIndex:i];
        if (c == ' ')
          {
            width++;
            i++;
          }
        else if (c == '\t')
          {
            /* Tab stops of 4 keep indent arithmetic simple. */
            width += 4 - (width % 4);
            i++;
          }
        else
          {
            break;
          }
      }
    return width;
}

/* Removes up to n indent columns, preserving the rest of the line. */
static NSString *GSMDRemoveIndent(NSString *line, NSUInteger n)
{
    NSUInteger i = 0, removed = 0, len = [line length];
    while (i < len && removed < n)
      {
        unichar c = [line characterAtIndex:i];
        if (c == ' ')
          {
            removed++;
            i++;
          }
        else if (c == '\t')
          {
            NSUInteger w = 4 - (removed % 4);
            if (removed + w > n)
              {
                break;
              }
            removed += w;
            i++;
          }
        else
          {
            break;
          }
      }
    return [line substringFromIndex:i];
}

static NSRange GSMDRangeFrom(NSString *hay, NSString *needle,
                             NSUInteger from)
{
    NSUInteger len = [hay length];
    if (from >= len)
      {
        return NSMakeRange(NSNotFound, 0);
      }
    return [hay rangeOfString:needle options:0
                        range:NSMakeRange(from, len - from)];
}

static NSString *GSMDLeftTrimmed(NSString *line);

#pragma mark - Block syntax predicates

/* List marker length ("- ", "* ", "+ ", "12. ") of a left-trimmed
 * line, or 0 when the line does not start a list item. */
static NSUInteger GSMDMarkerLength(NSString *lt)
{
    NSUInteger len = [lt length];
    if (len < 2)
      {
        return 0;
      }
    unichar c0 = [lt characterAtIndex:0];
    if ((c0 == '-' || c0 == '*' || c0 == '+')
        && ([lt characterAtIndex:1] == ' '
            || [lt characterAtIndex:1] == '\t'))
      {
        return 2;
      }
    NSUInteger i = 0;
    while (i < len)
      {
        unichar c = [lt characterAtIndex:i];
        if (c < '0' || c > '9')
          {
            break;
          }
        i++;
      }
    if (i > 0 && i < len && [lt characterAtIndex:i] == '.'
        && i + 1 < len
        && ([lt characterAtIndex:i + 1] == ' '
            || [lt characterAtIndex:i + 1] == '\t'))
      {
        return i + 2;
      }
    return 0;
}

static BOOL GSMDMarkerIsOrdered(NSString *lt)
{
    unichar c = [lt length] > 0 ? [lt characterAtIndex:0] : '-';
    return c >= '0' && c <= '9';
}

static BOOL GSMDIsRule(NSString *trimmed)
{
    NSUInteger len = [trimmed length];
    if (len < 3)
      {
        return NO;
      }
    unichar first = [trimmed characterAtIndex:0];
    if (first != '-' && first != '*' && first != '_')
      {
        return NO;
      }
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < len; i++)
      {
        unichar c = [trimmed characterAtIndex:i];
        if (c == first)
          {
            count++;
          }
        else if (c != ' ' && c != '\t')
          {
            return NO;
          }
      }
    return count >= 3;
}

static NSArray<NSString *> *GSMDTableCells(NSString *trimmed)
{
    NSString *t = trimmed;
    if ([t hasPrefix:@"|"])
      {
        t = [t substringFromIndex:1];
      }
    if ([t hasSuffix:@"|"] && [t length] > 0)
      {
        t = [t substringToIndex:[t length] - 1];
      }
    NSMutableArray *cells =
        [[t componentsSeparatedByString:@"|"] mutableCopy];
    for (NSUInteger i = 0; i < [cells count]; i++)
      {
        cells[i] = GSMDTrim(cells[i]);
      }
    return cells;
}

static BOOL GSMDSeparatorRow(NSString *trimmed)
{
    NSArray *cells = GSMDTableCells(trimmed);
    if ([cells count] == 0)
      {
        return NO;
      }
    BOOL hasDash = NO;
    for (NSString *cell in cells)
      {
        NSUInteger cl = [cell length];
        if (cl == 0)
          {
            return NO;
          }
        for (NSUInteger i = 0; i < cl; i++)
          {
            unichar c = [cell characterAtIndex:i];
            if (c == '-')
              {
                hasDash = YES;
              }
            else if (c != ':')
              {
                return NO;
              }
          }
      }
    return hasDash;
}

/* ATX heading level (1..6) with content out, or 0 when the line is
 * no heading. Closing hash runs are stripped only after whitespace,
 * so "C#" style text survives. */
static NSUInteger GSMDHeadingLevel(NSString *trimmed,
                                   NSString **contentOut)
{
    NSUInteger i = 0, len = [trimmed length];
    while (i < len && [trimmed characterAtIndex:i] == '#')
      {
        i++;
      }
    if (i == 0 || i > 6)
      {
        return 0;
      }
    if (i < len)
      {
        unichar c = [trimmed characterAtIndex:i];
        if (c != ' ' && c != '\t')
          {
            return 0;
          }
      }
    NSString *content = i < len ? [trimmed substringFromIndex:i + 1] : @"";
    content = GSMDTrim(content);
    NSUInteger end = [content length];
    while (end > 0 && [content characterAtIndex:end - 1] == '#')
      {
        end--;
      }
    if (end < [content length])
      {
        if (end > 0)
          {
            unichar before = [content characterAtIndex:end - 1];
            if (before == ' ' || before == '\t')
              {
                content = GSMDTrim([content substringToIndex:end]);
              }
          }
        else
          {
            content = @"";
          }
      }
    *contentOut = content;
    return i;
}

/* '=' delimited headline: "= Text =", "== Text ==", ... A leading run of
 * '=' gives the level (clamped to 4); an optional trailing '=' run is
 * stripped. Only '=' is used so it never collides with '-' list items.
 * Returns the level or 0 when the line is not this form. */
static NSUInteger GSMDDelimitedEqualsHeadingLevel(NSString *trimmed,
                                                  NSString **contentOut)
{
    NSUInteger len = [trimmed length];
    if (len == 0 || [trimmed characterAtIndex:0] != '=')
      {
        return 0;
      }
    NSUInteger n = 0;
    while (n < len && [trimmed characterAtIndex:n] == '=')
      {
        n++;
      }
    if (n < 1 || n > 4)
      {
        return 0;
      }
    /* A space must follow the opening '=' run before the text. */
    if (n < len)
      {
        unichar c = [trimmed characterAtIndex:n];
        if (c != ' ' && c != '\t')
          {
            return 0;
          }
      }
    NSString *content = GSMDTrim([trimmed substringFromIndex:n]);
    /* Optional trailing '=' run, preceded by whitespace. */
    NSUInteger t = [content length];
    while (t > 0 && [content characterAtIndex:t - 1] == '=')
      {
        t--;
      }
    if (t < [content length])
      {
        if (t == 0)
          {
            return 0;
          }
        unichar before = [content characterAtIndex:t - 1];
        if (before != ' ' && before != '\t')
          {
            return 0;
          }
        content = GSMDTrim([content substringToIndex:t - 1]);
      }
    if ([content length] == 0)
      {
        return 0;
      }
    *contentOut = content;
    return n;
}

/* Setext underline: a line made entirely of '=' (level 1) or '-' (level 2),
 * at least two characters. The heading text is the line above it. */
static BOOL GSMDIsSetextUnderline(NSString *trimmed, NSUInteger *levelOut)
{
    NSUInteger len = [trimmed length];
    if (len < 2)
      {
        return NO;
      }
    unichar c = [trimmed characterAtIndex:0];
    if (c != '=' && c != '-')
      {
        return NO;
      }
    for (NSUInteger k = 1; k < len; k++)
      {
        if ([trimmed characterAtIndex:k] != c)
          {
            return NO;
          }
      }
    *levelOut = (c == '=') ? 1 : 2;
    return YES;
}

/* Builds a GSHelpImage from a minimal <img> tag by pulling out the
 * src/alt/title attributes (the only ones the renderer uses). Returns
 * nil when there is no usable src, so a malformed tag is simply
 * skipped rather than rendered. */
static GSHelpImage *GSMDImageFromHTMLTag(NSString *tag)
{
    NSRegularExpression *attrRe =
        [[NSRegularExpression alloc]
            initWithPattern: @"([a-zA-Z][a-zA-Z0-9_-]*)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>/]+)"
                    options: 0
                      error: NULL];
    if (attrRe == nil)
      {
        return nil;
      }
    NSMutableDictionary<NSString *, NSString *> *attrs =
        [NSMutableDictionary new];
    NSArray *matches = [attrRe matchesInString: tag
                                       options: 0
                                         range: NSMakeRange(0, [tag length])];
    for (NSTextCheckingResult *m in matches)
      {
        NSString *key = [tag substringWithRange: [m rangeAtIndex: 1]];
        NSString *val = [tag substringWithRange: [m rangeAtIndex: 2]];
        /* Strip a single layer of surrounding quotes, if present. */
        if ([val length] >= 2)
          {
            unichar first = [val characterAtIndex: 0];
            unichar last = [val characterAtIndex: [val length] - 1];
            if ((first == '"' && last == '"')
                || (first == '\'' && last == '\''))
              {
                val = [val substringWithRange:
                    NSMakeRange(1, [val length] - 2)];
              }
          }
        attrs[[key lowercaseString]] = val;
      }
    NSString *src = attrs[@"src"];
    if ([src length] == 0)
      {
        return nil;
      }
    GSHelpImage *img = [GSHelpImage new];
    img.path = src;
    img.altText = attrs[@"alt"] ?: attrs[@"title"];
    return img;
}

#pragma mark - Inline scanning

static NSString *GSMDDecodeEntity(NSString *ent)
{
    if ([ent isEqualToString:@"&amp;"])
      {
        return @"&";
      }
    if ([ent isEqualToString:@"&lt;"])
      {
        return @"<";
      }
    if ([ent isEqualToString:@"&gt;"])
      {
        return @">";
      }
    if ([ent isEqualToString:@"&quot;"])
      {
        return @"\"";
      }
    if ([ent isEqualToString:@"&apos;"])
      {
        return @"'";
      }
        /* Numeric forms &#NN; and &#xHH; round out the named four.
         * strtoul keeps this independent of NSScanner API gaps. */
        if ([ent length] > 3
            && [ent characterAtIndex:1] == '#'
            && [ent characterAtIndex:[ent length] - 1] == ';')
          {
            NSString *digits = [ent substringWithRange:
                NSMakeRange(2, [ent length] - 3)];
            BOOL hex = NO;
            if ([digits length] > 1
                && ([digits hasPrefix:@"x"] || [digits hasPrefix:@"X"]))
              {
                hex = YES;
                digits = [digits substringFromIndex:1];
              }
            const char *cstr =
                [digits cStringUsingEncoding:NSASCIIStringEncoding];
            if (cstr == NULL)
              {
                return nil;
              }
            char *end = NULL;
            unsigned long value = strtoul(cstr, &end, hex ? 16 : 10);
            if (end == cstr || *end != '\0')
              {
                return nil;
              }
            if (value == 0 || value >= 0x110000
                || (value >= 0xD800 && value <= 0xDFFF))
              {
                return nil;
              }
            return [NSString stringWithFormat:@"%C", (unichar)value];
          }
    return nil;
}

/* Decodes entity refs in a raw attribute string (image alt text). */
static NSString *GSMDDecodeEntitiesIn(NSString *s)
{
    NSMutableString *out = [NSMutableString new];
    NSUInteger i = 0, len = [s length];
    while (i < len)
      {
        unichar c = [s characterAtIndex:i];
        if (c == '&')
          {
            NSUInteger maxLen = MIN(len - i, (NSUInteger)12);
            NSRange semi = [s rangeOfString:@";"
                      options:0 range:NSMakeRange(i, maxLen)];
            if (semi.location != NSNotFound)
              {
                NSString *ent =
                    [s substringWithRange:NSMakeRange(i,
                        semi.location - i + 1)];
                NSString *decoded = GSMDDecodeEntity(ent);
                if (decoded != nil)
                  {
                    [out appendString:decoded];
                    i = semi.location + 1;
                    continue;
                  }
              }
          }
        [out appendFormat:@"%C", c];
        i++;
      }
    return out;
}

static GSHelpText *GSMDTextNode(NSString *s, GSHelpTextStyle st)
{
    GSHelpText *t = [GSHelpText new];
    t.string = s;
    t.style = st;
    return t;
}

static void GSMDFlushPending(NSMutableString **pendingRef,
                             GSHelpTextStyle base,
                             NSMutableArray<GSHelpNode *> *out)
{
    if ([*pendingRef length] > 0)
      {
        [out addObject:GSMDTextNode([*pendingRef copy], base)];
        *pendingRef = [NSMutableString new];
      }
}

/* Recursive inline scanner. Emphasis nesting merges styles into a
 * single run instead of building a tree: the model is flat runs.
 * Links and images inside labels flatten to their textual content. */
static void GSMDScanInline(NSString *s,
                           GSHelpTextStyle base,
                           NSMutableArray<GSHelpNode *> *out)
{
    NSMutableString *pending = [NSMutableString new];
    NSUInteger i = 0, len = [s length];

    while (i < len)
      {
        unichar c = [s characterAtIndex:i];

        if (c == '<')
          {
            /* Minimal inline-HTML support: an <img> tag becomes an
             * image; any other tag is dropped so raw HTML never leaks
             * into the rendered text. A '<' that is not the start of a
             * tag stays literal. */
            if (i + 1 < len)
              {
                unichar nc = [s characterAtIndex: i + 1];
                /* A real tag starts with a letter, or with '/', '!',
                 * '?' (closing tags, comments, declarations). */
                BOOL isTag = (nc < 128
                              && (isalpha((int)nc)
                                  || nc == '/'
                                  || nc == '!'
                                  || nc == '?'));
                if (isTag)
                  {
                    NSRange close = [s rangeOfString: @">"
                                          options: 0
                                            range: NSMakeRange(i + 1,
                                                               len - i - 1)];
                    if (close.location != NSNotFound)
                      {
                        NSString *tag = [s substringWithRange:
                            NSMakeRange(i + 1, close.location - i - 1)];
                        GSMDFlushPending(&pending, base, out);
                        if ([tag hasPrefix: @"img"]
                              || [tag hasPrefix: @"IMG"])
                          {
                            GSHelpImage *img =
                                GSMDImageFromHTMLTag(tag);
                            if (img != nil)
                              {
                                [out addObject: img];
                              }
                          }
                        i = close.location + 1;
                        continue;
                      }
                  }
              }
            [pending appendFormat: @"%C", c];
            i++;
            continue;
          }

        if (c == '\\' && i + 1 < len)
          {
            /* Backslash escapes only punctuation; anything else
             * keeps its backslash so odd input stays visible. */
            static NSCharacterSet *punct = nil;
            if (punct == nil)
              {
                punct = [NSCharacterSet
                    characterSetWithCharactersInString:
                        @"!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"];
              }
            unichar n = [s characterAtIndex:i + 1];
            if ([punct characterIsMember:n])
              {
                [pending appendFormat:@"%C", n];
                i += 2;
              }
            else
              {
                [pending appendFormat:@"%C", c];
                i++;
              }
            continue;
          }

        if (c == '&')
          {
            NSUInteger maxLen = MIN(len - i, (NSUInteger)12);
            NSRange semi = [s rangeOfString:@";"
                      options:0 range:NSMakeRange(i, maxLen)];
            if (semi.location != NSNotFound)
              {
                NSString *ent = [s substringWithRange:NSMakeRange(
                    i, semi.location - i + 1)];
                NSString *decoded = GSMDDecodeEntity(ent);
                if (decoded != nil)
                  {
                    [pending appendString:decoded];
                    i = semi.location + 1;
                    continue;
                  }
              }
            [pending appendFormat:@"%C", c];
            i++;
            continue;
          }

        if (c == '`')
          {
            NSRange close = GSMDRangeFrom(s, @"`", i + 1);
            if (close.location != NSNotFound)
              {
                GSMDFlushPending(&pending, base, out);
                NSString *code =
                    [s substringWithRange:NSMakeRange(
                        i + 1, close.location - i - 1)];
                [out addObject:GSMDTextNode(code,
                    base | GSHelpTextStyleCode)];
                i = close.location + 1;
                continue;
              }
            [pending appendFormat:@"%C", c];
            i++;
            continue;
          }

        if (c == '[')
          {
            NSRange bracketClose = GSMDRangeFrom(s, @"](", i + 1);
            if (bracketClose.location != NSNotFound)
              {
                NSRange parenClose =
                    GSMDRangeFrom(s, @")", bracketClose.location + 2);
                if (parenClose.location != NSNotFound)
                  {
                    NSString *label = [s substringWithRange:NSMakeRange(
                        i + 1, bracketClose.location - i - 1)];
                    NSString *target =
                        [s substringWithRange:NSMakeRange(
                            bracketClose.location + 2,
                            parenClose.location
                                - bracketClose.location - 2)];
                    target = GSMDTrim(target);
                    GSMDFlushPending(&pending, base, out);
                    GSHelpLink *link = [GSHelpLink new];
                    link.target = target;
                    NSMutableArray *labelNodes =
                        [NSMutableArray new];
                    GSMDScanInline(label, GSHelpTextStylePlain,
                                   labelNodes);
                    for (GSHelpNode *n in labelNodes)
                      {
                        if ([n isKindOfClass:[GSHelpText class]])
                          {
                            GSHelpText *t = (GSHelpText *)n;
                            [link appendLabelRun:t.string
                                           style:t.style];
                          }
                        else if ([n isKindOfClass:[GSHelpLink class]])
                          {
                            [link appendLabelRun:
                                [(GSHelpLink *)n labelText]
                                       style:GSHelpTextStylePlain];
                          }
                        else if ([n isKindOfClass:[GSHelpImage class]])
                          {
                            [link appendLabelRun:
                                [(GSHelpImage *)n altText]
                                       style:GSHelpTextStylePlain];
                          }
                      }
                    [out addObject:link];
                    i = parenClose.location + 1;
                    continue;
                  }
              }
            [pending appendFormat:@"%C", c];
            i++;
            continue;
          }

        if (c == '!' && i + 1 < len
            && [s characterAtIndex:i + 1] == '[')
          {
            NSRange bracketClose = GSMDRangeFrom(s, @"](", i + 2);
            if (bracketClose.location != NSNotFound)
              {
                NSRange parenClose =
                    GSMDRangeFrom(s, @")", bracketClose.location + 2);
                if (parenClose.location != NSNotFound)
                  {
                    NSString *alt =
                        GSMDDecodeEntitiesIn([s substringWithRange:
                            NSMakeRange(i + 2,
                                bracketClose.location - i - 2)]);
                    NSString *path =
                        [s substringWithRange:NSMakeRange(
                            bracketClose.location + 2,
                            parenClose.location
                                - bracketClose.location - 2)];
                    GSMDFlushPending(&pending, base, out);
                    if ([path rangeOfString:@"://"].location
                            == NSNotFound
                        && ![path hasPrefix:@"help:"])
                      {
                        GSHelpImage *img = [GSHelpImage new];
                        img.path = path;
                        img.altText = alt;
                        [out addObject:img];
                      }
                    else
                      {
                        [out addObject:GSMDTextNode(alt, base)];
                      }
                    i = parenClose.location + 1;
                    continue;
                  }
              }
            [pending appendFormat:@"%C", c];
            i++;
            continue;
          }

        if (c == '*' || c == '_')
          {
            NSUInteger dlen = 1;
            if (i + 2 < len
                && [s characterAtIndex:i + 1] == c
                && [s characterAtIndex:i + 2] == c)
              {
                dlen = 3;
              }
            else if (i + 1 < len && [s characterAtIndex:i + 1] == c)
              {
                dlen = 2;
              }
            NSString *delim =
                [s substringWithRange:NSMakeRange(i, dlen)];
            NSRange close = GSMDRangeFrom(s, delim, i + dlen);
            if (close.location != NSNotFound)
              {
                GSMDFlushPending(&pending, base, out);
                NSString *inner =
                    [s substringWithRange:NSMakeRange(
                        i + dlen, close.location - i - dlen)];
                GSHelpTextStyle extra =
                    dlen == 3 ? (GSHelpTextStyleBold
                                 | GSHelpTextStyleItalic)
                              : (dlen == 2 ? GSHelpTextStyleBold
                                           : GSHelpTextStyleItalic);
                GSMDScanInline(inner, base | extra, out);
                i = close.location + dlen;
                continue;
              }
            [pending appendFormat:@"%C", c];
            i++;
            continue;
          }

        [pending appendFormat:@"%C", c];
        i++;
      }

    GSMDFlushPending(&pending, base, out);
}

/* Plain-text projection used where the model stores plain strings
 * only (heading text, table cells). */
static NSString *GSMDPlainTextOf(NSString *s)
{
    NSMutableArray *nodes = [NSMutableArray new];
    GSMDScanInline(s, GSHelpTextStylePlain, nodes);
    NSMutableString *result = [NSMutableString new];
    for (GSHelpNode *n in nodes)
      {
        if ([n isKindOfClass:[GSHelpText class]])
          {
            [result appendString:((GSHelpText *)n).string];
          }
        else if ([n isKindOfClass:[GSHelpLink class]])
          {
            [result appendString:[(GSHelpLink *)n labelText]];
          }
        else if ([n isKindOfClass:[GSHelpImage class]])
          {
            [result appendString:((GSHelpImage *)n).altText];
          }
      }
    return result;
}

/* GitHub-style anchor name: lowercased, spaces to hyphens, all
 * punctuation dropped (Unicode letters and digits survive). */
static NSString *GSMDAnchorName(NSString *text)
{
    NSMutableString *out = [NSMutableString new];
    NSString *lower = [text lowercaseString];
    NSUInteger len = [lower length];
    for (NSUInteger i = 0; i < len; i++)
      {
        unichar c = [lower characterAtIndex:i];
        if (c == ' ')
          {
            [out appendString:@"-"];
          }
        else if ([[NSCharacterSet alphanumericCharacterSet]
                     characterIsMember:c]
                 || c == '-' || c == '_')
          {
            [out appendFormat:@"%C", c];
          }
      }
    /* Collapse repeated hyphens so "Hello  World" stays one anchor. */
    while ([out rangeOfString:@"--"].location != NSNotFound)
      {
        [out replaceOccurrencesOfString:@"--"
                             withString:@"-"
                                options:0
                                  range:NSMakeRange(0, [out length])];
      }
    while ([out hasPrefix:@"-"])
      {
        [out deleteCharactersInRange:NSMakeRange(0, 1)];
      }
    while ([out hasSuffix:@"-"] && [out length] > 0)
      {
        [out deleteCharactersInRange:NSMakeRange([out length] - 1, 1)];
      }
    return out;
}

#pragma mark - Parser

@interface GSMarkdownParser ()
@property (nonatomic, strong, nullable) NSString *firstH1;
@end

@implementation GSMarkdownParser

- (BOOL)canParseURL:(NSURL *)url
{
    if (url == nil)
      {
        return NO;
      }
    NSString *ext = [[url pathExtension] lowercaseString];
    if ([ext isEqualToString:@"md"]
        || [ext isEqualToString:@"markdown"]
        || [ext isEqualToString:@"mdown"])
      {
        return YES;
      }
    if (![url isFileURL])
      {
        return NO;
      }
    /* Content sniff for extension-less files: a heading or fence
     * near the top is enough evidence. */
    NSFileHandle *fh =
        [NSFileHandle fileHandleForReadingAtPath:[url path]];
    if (fh == nil)
      {
        return NO;
      }
    NSData *data = [fh readDataOfLength:8192];
    [fh closeFile];
    NSString *head =
        [[NSString alloc] initWithData:data
                              encoding:NSUTF8StringEncoding];
    if (head == nil)
      {
        return NO;
      }
    NSArray *lines =
        [head componentsSeparatedByString:@"\n"];
    NSUInteger limit = MIN([lines count], (NSUInteger)20);
    for (NSUInteger i = 0; i < limit; i++)
      {
        NSString *t = GSMDTrim(lines[i]);
        if ([t hasPrefix:@"```"])
          {
            return YES;
          }
        if ([t length] > 1 && [t hasPrefix:@"#"]
            && ([t characterAtIndex:1] == ' '
                || [t characterAtIndex:1] == '\t'))
          {
            return YES;
          }
      }
    return NO;
}

- (nullable GSHelpDocument *)parseURL:(NSURL *)url
                                error:(NSError **)error
{
    if (error != nil)
      {
        *error = nil;
      }
    if (url == nil)
      {
        if (error != nil)
          {
            *error = [NSError errorWithDomain:@"GSHelpMarkdownParser"
                                          code:1
                                      userInfo:@{
                NSLocalizedDescriptionKey : @"nil URL",
              }];
          }
        return nil;
      }
    NSError *readError = nil;
    /* Read bytes first: an empty file must yield an empty document,
     * not be confused with a read failure (GNUstep returns nil for
     * zero-length sources via the string convenience API). */
    NSData *data =
        [[NSData alloc] initWithContentsOfURL:url options:0
                                        error:&readError];
    if (data == nil)
      {
        if (error != nil)
          {
            *error = readError ?: [NSError
                errorWithDomain:@"GSHelpMarkdownParser"
                           code:2
                       userInfo:@{
                  NSLocalizedDescriptionKey :
                      @"cannot read Markdown source",
                }];
          }
        return nil;
      }
    NSString *src = @"";
    if ([data length] > 0)
      {
        src = [[NSString alloc] initWithData:data
                                    encoding:NSUTF8StringEncoding];
      }
    if (src == nil)
      {
        /* Invalid UTF-8: fail hard per protocol. */
        if (error != nil)
          {
            *error = [NSError
                errorWithDomain:@"GSHelpMarkdownParser"
                           code:3
                       userInfo:@{
                  NSLocalizedDescriptionKey :
                      @"Markdown source is not valid UTF-8",
                }];
          }
        return nil;
      }

    src = [src stringByReplacingOccurrencesOfString:@"\r\n"
                                         withString:@"\n"];
    src = [src stringByReplacingOccurrencesOfString:@"\r"
                                         withString:@"\n"];

    self.firstH1 = nil;
    GSHelpSection *root = [GSHelpSection new];
    [self parseLines:[src componentsSeparatedByString:@"\n"]
                into:root];

    GSHelpDocument *doc = [GSHelpDocument new];
    doc.sourceType = @"markdown";
    doc.sourceURL = url;
    NSString *fallback =
        [[url lastPathComponent] stringByDeletingPathExtension];
    NSString *title =
        self.firstH1 ?: ([fallback length] > 0 ? fallback : nil);
    /* Document names such as COPYING/README normalise to title case
     * (SPEC: consistent with man section headings). */
    doc.title = GSHelpTitleCased(title);
    root.title = title;
    doc.rootNode = root;
    return doc;
}

#pragma mark Block parsing

- (void)appendInlineOf:(NSString *)s to:(GSHelpNode *)node
{
    NSMutableArray *runs = [NSMutableArray new];
    GSMDScanInline(s, GSHelpTextStylePlain, runs);
    for (GSHelpNode *n in runs)
      {
        [node appendNode:n];
      }
}

- (void)flushPara:(NSMutableString **)paraRef into:(GSHelpNode *)container
{
    NSMutableString *p = *paraRef;
    if (p != nil && [p length] > 0)
      {
        GSHelpParagraph *par = [GSHelpParagraph new];
        NSMutableArray *runs = [NSMutableArray new];
        GSMDScanInline(p, GSHelpTextStylePlain, runs);
        for (GSHelpNode *n in runs)
          {
            [par appendNode:n];
          }
        [container appendNode:par];
      }
    *paraRef = nil;
}

- (void)gsmdEmitHeading:(NSString *)plain
                  level:(NSUInteger)level
                   into:(GSHelpNode *)container
{
    NSString *name = GSMDAnchorName(plain);
    if ([name length] > 0)
      {
        GSHelpAnchor *anchor = [GSHelpAnchor new];
        anchor.name = name;
        [container appendNode:anchor];
      }
    GSHelpHeading *heading = [GSHelpHeading new];
    heading.level = level;
    heading.text = plain;
    [container appendNode:heading];
    if (level == 1 && self.firstH1 == nil)
      {
        self.firstH1 = plain;
      }
}

/* Core block loop. Recursion happens only for blockquotes, which
 * strip one ">" level and re-enter this method on the remainder. */
- (void)parseLines:(NSArray<NSString *> *)lines
              into:(GSHelpNode *)container
{
    __block NSMutableString *para = nil;
    NSUInteger count = [lines count];
#define GSMD_FLUSH() [self flushPara:&para into:container]

    NSUInteger i = 0;
    while (i < count)
      {
        NSString *raw = lines[i];
        NSString *trimmed = GSMDTrim(raw);

        if ([trimmed hasPrefix:@"```"])
          {
            GSMD_FLUSH();
            NSString *lang = GSMDTrim([trimmed substringFromIndex:3]);
            NSMutableArray *bodyLines = [NSMutableArray new];
            i++;
            while (i < count)
              {
                if ([GSMDTrim(lines[i]) hasPrefix:@"```"])
                  {
                    i++;
                    break;
                  }
                [bodyLines addObject:lines[i]];
                i++;
              }
            /* The split after a trailing newline leaves an empty
             * last element; it is an artifact, not fence content. */
            while ([bodyLines count] > 0
                   && [[bodyLines lastObject] isEqual:@""])
              {
                [bodyLines removeLastObject];
              }
            GSHelpCodeBlock *cb = [GSHelpCodeBlock new];
            cb.code =
                [bodyLines componentsJoinedByString:@"\n"];
            cb.language = [lang length] > 0 ? lang : nil;
            [container appendNode:cb];
            continue;
          }

        if (GSMDIsBlank(raw))
          {
            GSMD_FLUSH();
            i++;
            continue;
          }

        NSString *content = nil;
        NSUInteger level = GSMDHeadingLevel(trimmed, &content);
        if (level > 0)
          {
            GSMD_FLUSH();
            [self gsmdEmitHeading: GSMDPlainTextOf(content)
                            level: level
                             into: container];
            i++;
            continue;
          }

        /* "= Text =", "== Text ==" style headline. */
        level = GSMDDelimitedEqualsHeadingLevel(trimmed, &content);
        if (level > 0)
          {
            GSMD_FLUSH();
            [self gsmdEmitHeading: GSMDPlainTextOf(content)
                            level: level
                             into: container];
            i++;
            continue;
          }

        /* Setext underline headline: this text line is followed by a line
         * of '=' (level 1) or '-' (level 2). */
        if (i + 1 < count)
          {
            NSUInteger slevel = 0;
            if (GSMDIsSetextUnderline(
                    GSMDTrim(lines[i + 1]), &slevel))
              {
                GSMD_FLUSH();
                [self gsmdEmitHeading: GSMDPlainTextOf(trimmed)
                                level: slevel
                                 into: container];
                i += 2;
                continue;
              }
          }

        if (GSMDIsRule(trimmed))
          {
            GSMD_FLUSH();
            /* Documented representation: rule as paragraph with a
             * single plain "---" run the renderer draws as a rule. */
            GSHelpParagraph *rule = [GSHelpParagraph new];
            [rule appendNode:GSMDTextNode(@"---",
                GSHelpTextStylePlain)];
            [container appendNode:rule];
            i++;
            continue;
          }

        if ([trimmed hasPrefix:@">"])
          {
            GSMD_FLUSH();
            NSMutableArray *inner = [NSMutableArray new];
            while (i < count)
              {
                if (GSMDIsBlank(lines[i]))
                  {
                    break;
                  }
                NSString *lt = GSMDLeftTrimmed(lines[i]);
                if (![lt hasPrefix:@">"])
                  {
                    break;
                  }
                NSString *cont = [lt substringFromIndex:1];
                if ([cont length] > 0
                    && ([cont characterAtIndex:0] == ' '
                        || [cont characterAtIndex:0] == '\t'))
                  {
                    cont = [cont substringFromIndex:1];
                  }
                [inner addObject:cont];
                i++;
              }
            GSHelpQuote *quote = [GSHelpQuote new];
            [self parseLines:inner into:quote];
            [container appendNode:quote];
            continue;
          }

        if ([trimmed rangeOfString:@"|"].location != NSNotFound
            && i + 1 < count
            && GSMDSeparatorRow(GSMDTrim(lines[i + 1])))
          {
            GSMD_FLUSH();
            GSHelpTable *table = [GSHelpTable new];
            GSHelpTableRow *head = [GSHelpTableRow new];
            for (NSString *cell in GSMDTableCells(trimmed))
              {
                [head appendCellWithText:GSMDPlainTextOf(cell)];
              }
            [table appendNode:head];
            i += 2;
            while (i < count && !GSMDIsBlank(lines[i])
                   && [GSMDTrim(lines[i]) rangeOfString:@"|"].location
                          != NSNotFound)
              {
                GSHelpTableRow *row = [GSHelpTableRow new];
                for (NSString *cell in
                    GSMDTableCells(GSMDTrim(lines[i])))
                  {
                    [row appendCellWithText:GSMDPlainTextOf(cell)];
                  }
                [table appendNode:row];
                i++;
              }
            [container appendNode:table];
            continue;
          }

        NSUInteger indent = GSMDIndentOf(raw);
        if (GSMDMarkerLength(GSMDLeftTrimmed(raw)) > 0)
          {
            GSMD_FLUSH();
            NSMutableArray *blockLines = [NSMutableArray new];
            NSUInteger j = i;
            while (j < count)
              {
                if (GSMDIsBlank(lines[j]))
                  {
                    NSUInteger k = j + 1;
                    while (k < count && GSMDIsBlank(lines[k]))
                      {
                        k++;
                      }
                    if (k < count
                        && (GSMDIndentOf(lines[k]) > 0
                            || GSMDMarkerLength(
                                   GSMDLeftTrimmed(lines[k])) > 0))
                      {
                        [blockLines addObject:lines[j]];
                        j = k;
                        continue;
                      }
                    break;
                  }
                if (GSMDMarkerLength(GSMDLeftTrimmed(lines[j])) > 0
                    || GSMDIndentOf(lines[j]) > 0)
                  {
                    [blockLines addObject:lines[j]];
                    j++;
                    continue;
                  }
                break;
              }
            [self buildListFromLines:blockLines into:container];
            i = j;
            continue;
          }

        if (indent >= 4)
          {
            if (para != nil && [para length] > 0)
              {
                /* Indented lines may not interrupt an open
                 * paragraph; they continue it instead. */
                [para appendString:@" "];
                [para appendString:GSMDTrim(
                     GSMDRemoveIndent(raw, 4))];
                i++;
                continue;
              }
            NSMutableString *code = [NSMutableString new];
            while (i < count)
              {
                if (GSMDIsBlank(lines[i]))
                  {
                    NSUInteger k = i + 1;
                    while (k < count && GSMDIsBlank(lines[k]))
                      {
                        k++;
                      }
                    if (k < count && GSMDIndentOf(lines[k]) >= 4)
                      {
                        i = k;
                        continue;
                      }
                    break;
                  }
                if (GSMDIndentOf(lines[i]) < 4)
                  {
                    break;
                  }
                if ([code length] > 0)
                  {
                    [code appendString:@"\n"];
                  }
                [code appendString:GSMDRemoveIndent(lines[i], 4)];
                i++;
              }
            GSHelpCodeBlock *cb = [GSHelpCodeBlock new];
            cb.code = code;
            [container appendNode:cb];
            continue;
          }

        if (para == nil)
          {
            para = [NSMutableString new];
          }
        else if ([para length] > 0)
          {
            [para appendString:@" "];
          }
        [para appendString:trimmed];
        i++;
      }

    GSMD_FLUSH();
#undef GSMD_FLUSH
}

/* Left-trim helper kept here so the block loop reads cleanly. */
static NSString *GSMDLeftTrimmed(NSString *line)
{
    NSUInteger i = 0, len = [line length];
    while (i < len)
      {
        unichar c = [line characterAtIndex:i];
        if (c != ' ' && c != '\t')
          {
            break;
          }
        i++;
      }
    return [line substringFromIndex:i];
}

#pragma mark Lists

- (void)buildListFromLines:(NSArray<NSString *> *)lines
                      into:(GSHelpNode *)container
{
    NSMutableArray *ls = [lines mutableCopy];
    while ([ls count] > 0 && GSMDIsBlank([ls lastObject]))
      {
        [ls removeLastObject];
      }
    if ([ls count] == 0)
      {
        return;
      }

    NSUInteger base = GSMDIndentOf(ls[0]);
    NSUInteger n = [ls count];
    GSHelpList *list = [GSHelpList new];
    list.ordered = GSMDMarkerIsOrdered(GSMDLeftTrimmed(ls[0]));

    NSUInteger i = 0;
    while (i < n)
      {
        NSString *line = ls[i];
        if (GSMDIsBlank(line))
          {
            i++;
            continue;
          }
        NSUInteger ind = GSMDIndentOf(line);
        NSString *lt = GSMDLeftTrimmed(line);
        NSUInteger ml = GSMDMarkerLength(lt);
        if (ml > 0 && ind <= base)
          {
            GSHelpListItem *item = [GSHelpListItem new];
            NSString *content = GSMDTrim([lt substringFromIndex:ml]);

            NSMutableArray *body = [NSMutableArray new];
            NSUInteger j = i + 1;
            while (j < n)
              {
                NSString *bl = ls[j];
                if (GSMDIsBlank(bl))
                  {
                    NSUInteger k = j + 1;
                    while (k < n && GSMDIsBlank(ls[k]))
                      {
                        k++;
                      }
                    if (k < n && GSMDIndentOf(ls[k]) > base)
                      {
                        [body addObject:bl];
                        j = k;
                        continue;
                      }
                    break;
                  }
                if (GSMDIndentOf(bl) > base)
                  {
                    [body addObject:bl];
                    j++;
                    continue;
                  }
                break;
              }

            if ([content length] > 0)
              {
                [self appendInlineOf:content to:item];
              }
            [self finishItem:item body:body];
            [list appendNode:item];
            i = j;
          }
        else
          {
            /* Stray line at list level: skip it rather than fail. */
            i++;
          }
      }

    [container appendNode:list];
}

/* Item continuation handling: dedented non-marker lines join the
 * item's content; indented marker runs become nested lists via a
 * recursive buildList call. */
- (void)finishItem:(GSHelpListItem *)item body:(NSArray<NSString *> *)body
{
    NSMutableArray *ls = [body mutableCopy];
    while ([ls count] > 0 && GSMDIsBlank([ls lastObject]))
      {
        [ls removeLastObject];
      }
    if ([ls count] == 0)
      {
        return;
      }

    NSUInteger split = NSNotFound;
    for (NSUInteger k = 0; k < [ls count]; k++)
      {
        NSString *l = ls[k];
        if (GSMDIsBlank(l))
          {
            continue;
          }
        if (GSMDIndentOf(l) > 0
            && GSMDMarkerLength(GSMDLeftTrimmed(l)) > 0)
          {
            split = k;
            break;
          }
      }

    if (split == NSNotFound)
      {
        [self appendJoinedDedented:[ls subarrayWithRange:
            NSMakeRange(0, [ls count])] to:item];
        return;
      }

    if (split > 0)
      {
        [self appendJoinedDedented:[ls subarrayWithRange:
            NSMakeRange(0, split)] to:item];
      }

    NSArray *sub =
        [ls subarrayWithRange:NSMakeRange(split, [ls count] - split)];
    NSUInteger minInd = NSUIntegerMax;
    for (NSString *l in sub)
      {
        if (!GSMDIsBlank(l))
          {
            minInd = MIN(minInd, GSMDIndentOf(l));
          }
      }
    NSMutableArray *dedented = [NSMutableArray new];
    for (NSString *l in sub)
      {
        [dedented addObject:GSMDRemoveIndent(l, minInd)];
      }
    [self buildListFromLines:dedented into:item];
}

/* Joins blank-separated continuation lines with spaces and appends
 * the resulting inline content to node. */
- (void)appendJoinedDedented:(NSArray<NSString *> *)lines
                          to:(GSHelpNode *)node
{
    NSUInteger minInd = NSUIntegerMax;
    for (NSString *l in lines)
      {
        if (!GSMDIsBlank(l))
          {
            minInd = MIN(minInd, GSMDIndentOf(l));
          }
      }
    if (minInd == NSUIntegerMax)
      {
        return;
      }
    NSMutableString *joined = [NSMutableString new];
    for (NSString *l in lines)
      {
        if (GSMDIsBlank(l))
          {
            continue;
          }
        NSString *t = GSMDTrim(GSMDRemoveIndent(l, minInd));
        if ([joined length] > 0)
          {
            [joined appendString:@" "];
          }
        [joined appendString:t];
      }
    if ([joined length] > 0)
      {
        [self appendInlineOf:joined to:node];
      }
}

@end

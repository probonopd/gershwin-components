/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSTextParser.h"

#import "GSHelpNode.h"
#import "GSHelpDocument.h"

/* Fraction of non-blank lines that must look terminal-ish for the
 * whole document to be treated as monospaced output. */
static const CGFloat TextMonospaceRatioThreshold = 0.6;

static BOOL IsBlankLine(NSString *line)
{
  return line == nil || [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]].length == 0;
}

/* Terminal-style signals: leading indentation or a shell prompt. */
static BOOL LooksLikeTerminalLine(NSString *content)
{
  if (content.length == 0)
    return NO;
  unichar first = [content characterAtIndex: 0];
  if (first == ' ' || first == '\t')
    return YES;
  if ([content hasPrefix: @"$ "] || [content isEqualToString: @"$"])
    return YES;
  if ([content hasPrefix: @"# "] || [content isEqualToString: @"#"])
    return YES;
  if ([content hasPrefix: @"% "] || [content isEqualToString: @"%"])
    return YES;
  return NO;
}

/* Appends a plain text run unless string is empty. */
static void AppendRun(NSMutableArray<GSHelpNode *> *children,
                      NSString *string)
{
  if (string.length == 0)
    return;
  GSHelpText *run = [GSHelpText new];
  run.string = string;
  run.style = GSHelpTextStylePlain;
  [children addObject: run];
}

static void AppendManLink(NSMutableArray<GSHelpNode *> *children,
                          NSString *command, NSString *section)
{
  GSHelpLink *link = [GSHelpLink new];
  link.target = [NSString stringWithFormat: @"help://man/%@/%@",
                                           command, section];
  [link appendLabelRun:
          [NSString stringWithFormat: @"%@(%@)", command, section]
                   style: GSHelpTextStylePlain];
  [children addObject: link];
}

/* Strict UTF-8 first, Latin-1 as the byte-preserving lossy path:
 * every byte maps to one code point, so decoding never fails. */
static NSString *DecodeLossy(NSData *data)
{
  NSString *utf8 =
      [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
  if (utf8 != nil)
    return utf8;
  return [[NSString alloc] initWithData: data
                               encoding: NSISOLatin1StringEncoding];
}

@class GSTextParser;

/* Private pattern helpers shared with the block assembler below. */
@interface GSTextParser (Patterns)
+ (NSRegularExpression *)manRefAtEndPattern;
+ (NSRegularExpression *)standaloneRefPattern;
@end

/* Assembles one blank-line-delimited block into paragraph children:
 * plain runs interleaved with high-confidence man-reference links. */
@interface GSTextBlockAssembler : NSObject
- (void)appendLineContent:(NSString *)content
               terminator:(NSString *)terminator;
/* Flushes any pending run and hands over the assembled children. */
- (NSArray<GSHelpNode *> *)drainChildren;
@end

@implementation GSTextBlockAssembler
{
  NSMutableArray<GSHelpNode *> *_children;
  NSMutableString *_pending;
}

- (instancetype)init
{
  if ((self = [super init]) != nil)
    {
      _children = [NSMutableArray new];
      _pending = [NSMutableString new];
    }
  return self;
}

- (void)appendLineContent:(NSString *)content
               terminator:(NSString *)terminator
{
  /* Standalone reference: the whole line is just word(N). */
  NSTextCheckingResult *standalone =
      [[GSTextParser standaloneRefPattern]
          firstMatchInString: content options: 0
                       range: NSMakeRange(0, content.length)];
  if (standalone != nil)
    {
      AppendRun(_children, _pending);
      [_pending setString: @""];
      AppendManLink(_children,
                    [content substringWithRange:
                               [standalone rangeAtIndex: 1]],
                    [content substringWithRange:
                               [standalone rangeAtIndex: 2]]);
      return;
    }

  /* End-of-line reference preceded by a boundary so mid-sentence
   * mentions stay plain text. */
  NSTextCheckingResult *atEnd =
      [[GSTextParser manRefAtEndPattern]
          firstMatchInString: content options: 0
                       range: NSMakeRange(0, content.length)];
  if (atEnd != nil)
    {
      NSRange commandRange = [atEnd rangeAtIndex: 2];
      NSString *prefix = [content substringToIndex: commandRange.location];

      BOOL boundaryOK =
          prefix.length == 0
          || [[NSCharacterSet whitespaceCharacterSet]
                 characterIsMember:
                     [prefix characterAtIndex: prefix.length - 1]];
      if (boundaryOK)
        {
          AppendRun(_children, _pending);
          [_pending setString: @""];

          AppendManLink(_children,
                        [content substringWithRange: commandRange],
                        [content substringWithRange:
                                   [atEnd rangeAtIndex: 3]]);
          /* Trailing blanks and the line ending stay in the flow. */
          NSUInteger linkEnd = NSMaxRange([atEnd rangeAtIndex: 3]);
          if (linkEnd < content.length)
            [_pending appendString:
                        [content substringFromIndex: linkEnd]];
          [_pending appendString: terminator];
          return;
        }
    }

  [_pending appendString: content];
  [_pending appendString: terminator];
}

- (NSArray<GSHelpNode *> *)drainChildren
{
  AppendRun(_children, _pending);
  NSArray<GSHelpNode *> *result = _children;
  _children = [NSMutableArray new];
  _pending = [NSMutableString new];
  return result;
}

@end

@implementation GSTextParser

- (BOOL)canParseURL:(NSURL *)url
{
  /* Registry fallback: accepts everything so unknown sources still
   * render as plain text rather than failing outright (SPEC 51). */
  return url != nil;
}

+ (BOOL)isMonospacedContent:(NSString *)text
{
  NSUInteger total = 0;
  NSUInteger signal = 0;
  /* A zero-length range pins getLineStart to the line at pos. */
  NSUInteger pos = 0;
  while (pos < text.length)
    {
      NSUInteger lineEnd = 0;
      NSUInteger contentsEnd = 0;
      [text getLineStart: NULL end: &lineEnd contentsEnd: &contentsEnd
                 forRange: NSMakeRange(pos, 0)];
      NSString *content =
          [text substringWithRange: NSMakeRange(pos,
                                                contentsEnd - pos)];
      if (!IsBlankLine(content))
        {
          total++;
          if (LooksLikeTerminalLine(content))
            signal++;
        }
      pos = (lineEnd > pos) ? lineEnd : pos + 1;
    }
  return total > 0 && (CGFloat) signal / (CGFloat) total
           >= TextMonospaceRatioThreshold;
}

/* word(N) with an alphanumeric section suffix (3x, 3ssl, ...),
 * anchored at end of line; group 1 is the boundary before it
 * (empty at line start), group 2 the command, group 3 the section. */
+ (NSRegularExpression *)manRefAtEndPattern
{
  static NSRegularExpression *pattern = nil;
  if (pattern == nil)
    {
      pattern = [NSRegularExpression
          regularExpressionWithPattern:
              @"(^|[^A-Za-z0-9_])([A-Za-z][A-Za-z0-9_.:+-]*)"
              @"\\(([0-9][A-Za-z0-9+]*)\\)[ \t]*$"
                               options: 0 error: NULL];
    }
  return pattern;
}

/* A line consisting of nothing but word(N): the other high-
 * confidence shape for a man cross-reference. */
+ (NSRegularExpression *)standaloneRefPattern
{
  static NSRegularExpression *pattern = nil;
  if (pattern == nil)
    {
      pattern = [NSRegularExpression
          regularExpressionWithPattern:
              @"^[ \t]*([A-Za-z][A-Za-z0-9_.:+-]*)"
              @"\\(([0-9][A-Za-z0-9+]*)\\)[ \t]*$"
                               options: 0 error: NULL];
    }
  return pattern;
}

- (nullable GSHelpDocument *)parseURL:(NSURL *)url
                                error:(NSError **)error
{
  GSHelpDocument *doc = nil;

  /* Never raise toward the caller (SPEC 76): any failure below turns
   * into nil plus an error. */
  @try
    {
      NSData *data = [NSData dataWithContentsOfURL: url
                                           options: 0
                                             error: error];
      if (data == nil)
        return nil;

      NSString *text = DecodeLossy(data);
      GSHelpSection *root = [GSHelpSection new];

      if ([GSTextParser isMonospacedContent: text])
        {
          /* Terminal-oriented dump: keep it verbatim, line endings
           * included, as one code block. */
          GSHelpCodeBlock *code = [GSHelpCodeBlock new];
          code.code = text;
          [root appendNode: code];
        }
      else
        {
          GSTextBlockAssembler *assembler = [GSTextBlockAssembler new];
          NSUInteger pos = 0;
          while (pos < text.length)
            {
              /* A zero-length range pins getLineStart to the line
               * at pos. */
              NSUInteger lineEnd = 0;
              NSUInteger contentsEnd = 0;
              [text getLineStart: NULL end: &lineEnd
                    contentsEnd: &contentsEnd
                        forRange: NSMakeRange(pos, 0)];
              NSString *content =
                  [text substringWithRange: NSMakeRange(pos,
                                                        contentsEnd - pos)];

              if (IsBlankLine(content))
                {
                  /* Blank (or whitespace-only) line ends the block;
                   * its own line ending is dropped deliberately. */
                  GSHelpParagraph *para = [GSHelpParagraph new];
                  for (GSHelpNode *child in [assembler drainChildren])
                    [para appendNode: child];
                  if (para.children.count > 0)
                    [root appendNode: para];
                }
              else
                {
                  NSString *terminator =
                      [text substringWithRange:
                              NSMakeRange(contentsEnd,
                                          lineEnd - contentsEnd)];
                  [assembler appendLineContent: content
                                    terminator: terminator];
                }

              pos = (lineEnd > pos) ? lineEnd : pos + 1;
            }

          GSHelpParagraph *last = [GSHelpParagraph new];
          for (GSHelpNode *child in [assembler drainChildren])
            [last appendNode: child];
          if (last.children.count > 0)
            [root appendNode: last];
        }

      doc = [GSHelpDocument new];
      doc.rootNode = root;
      doc.sourceType = @"text";
      doc.sourceURL = url;
      doc.title = url.lastPathComponent;
    }
  @catch (NSException *exception)
    {
      if (error != NULL)
        *error = [NSError errorWithDomain: @"GSTextParserErrorDomain"
                                     code: 1
                                 userInfo:
                        @{ NSLocalizedDescriptionKey:
                             exception.reason ?: @"parsing failed" }];
      return nil;
    }

  return doc;
}

@end

/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_Markdown_Edge - malformed input, empty documents, Unicode and
 * pathological nesting for GSMarkdownParser. Nothing may raise;
 * malformed markup degrades to literal text or paragraphs. Headless. */

#import <Foundation/Foundation.h>
#import <unistd.h>
#import "Testing.h"

#import "GSHelpNode.h"
#import "GSHelpDocument.h"
#import "GSMarkdownParser.h"

static NSString *FixturePath(void)
{
  return [NSString stringWithFormat:
      @"%@/gsmdedge_%d.md", NSTemporaryDirectory(), (int)getpid()];
}

static NSURL *WriteFixture(NSString *src)
{
  [[NSFileManager defaultManager] removeItemAtPath: FixturePath()
                                             error: NULL];
  [src writeToFile: FixturePath() atomically: YES
          encoding: NSUTF8StringEncoding error: NULL];
  return [NSURL fileURLWithPath: FixturePath()];
}

static GSHelpDocument *Parse(NSString *src)
{
  return [[GSMarkdownParser new] parseURL: WriteFixture(src) error: nil];
}

static NSString *PlainOf(NSArray *nodes)
{
  NSMutableString *s = [NSMutableString new];
  for (GSHelpNode *n in nodes) {
    if ([n isKindOfClass: [GSHelpText class]]) {
      [s appendString: ((GSHelpText *)n).string];
    } else if ([n isKindOfClass: [GSHelpLink class]]) {
      [s appendString: [(GSHelpLink *)n labelText]];
    }
  }
  return s;
}

static NSArray *NodesOfClass(GSHelpDocument *d, Class c)
{
  NSMutableArray *r = [NSMutableArray new];
  for (GSHelpNode *n in d.rootNode.children) {
    if ([n isKindOfClass: c]) {
      [r addObject: n];
    }
  }
  return r;
}

static GSHelpParagraph *FirstParagraph(GSHelpDocument *d)
{
  for (GSHelpNode *n in d.rootNode.children) {
    if ([n isKindOfClass: [GSHelpParagraph class]]) {
      return (GSHelpParagraph *)n;
    }
  }
  return nil;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("empty documents")
  {
    GSHelpDocument *d = Parse(@"");
    PASS(d != nil && d.rootNode != nil, "empty file yields document");
    PASS(d.rootNode.children.count == 0, "empty file has no content");
    NSString *want = [[FixturePath() lastPathComponent]
        stringByDeletingPathExtension];
    PASS([d.title isEqual: want], "title falls back to filename");

    d = Parse(@"   \n\t\n \n");
    PASS(d != nil && d.rootNode != nil, "whitespace-only file yields doc");
    PASS(d.rootNode.children.count == 0,
         "whitespace-only file has no content nodes");
  }
  END_SET("empty documents")

  START_SET("malformed inline")
  {
    GSHelpDocument *d = Parse(@"**abc\n");
    GSHelpParagraph *p = FirstParagraph(d);
    PASS(p != nil, "unclosed bold yields a paragraph");
    BOOL anyBold = NO;
    for (GSHelpNode *n in p.children) {
      if ([n isKindOfClass: [GSHelpText class]]
          && ((GSHelpText *)n).style & GSHelpTextStyleBold) anyBold = YES;
    }
    PASS(!anyBold, "unclosed bold produces no bold run");
    PASS_EQUAL(PlainOf(p.children), @"**abc",
               "unclosed markers stay as literal text");

    d = Parse(@"a [ b\n");
    PASS_EQUAL(PlainOf(FirstParagraph(d).children), @"a [ b",
               "lone bracket stays literal");

    d = Parse(@"[label](nope\n");
    BOOL hasLink = NO;
    for (GSHelpNode *n in FirstParagraph(d).children) {
      if ([n isKindOfClass: [GSHelpLink class]]) hasLink = YES;
    }
    PASS(!hasLink, "unclosed link target produces no link node");
    PASS_EQUAL(PlainOf(FirstParagraph(d).children), @"[label](nope",
               "unclosed link stays literal text");

    d = Parse(@"![alt](broken\n");
    BOOL hasImage = NO;
    for (GSHelpNode *n in FirstParagraph(d).children) {
      if ([n isKindOfClass: [GSHelpImage class]]) hasImage = YES;
    }
    PASS(!hasImage, "unclosed image produces no image node");

    d = Parse(@"***x** y\n");
    p = FirstParagraph(d);
    PASS(p != nil, "mismatched triple/double emphasis does not raise");
  }
  END_SET("malformed inline")

  START_SET("degenerate blocks")
  {
    GSHelpDocument *d = Parse(@"#\n");
    NSArray *heads =
        NodesOfClass(d, [GSHelpHeading class]);
    PASS(heads.count == 1 && ((GSHelpHeading *)heads[0]).level == 1,
         "bare hash is an empty level-1 heading");
    PASS(((GSHelpHeading *)heads[0]).text != nil, "heading text non-nil");

    d = Parse(@"####### seven\n");
    heads = NodesOfClass(d, [GSHelpHeading class]);
    PASS(heads.count == 0, "seven hashes is not a heading");
    GSHelpParagraph *p = FirstParagraph(d);
    PASS(p != nil && [PlainOf(p.children) containsString: @"seven"],
         "over-long hash run falls back to paragraph text");

    d = Parse(@"~~~\ncode\n~~~\n");
    PASS(NodesOfClass(d, [GSHelpCodeBlock class]).count == 0,
         "tilde fences are not code blocks in this dialect");
    PASS(FirstParagraph(d) != nil, "tilde fence degrades to paragraph");

    d = Parse(@"| only header |\n");
    PASS(NodesOfClass(d, [GSHelpTable class]).count == 0,
         "header without separator row is not a table");

    __block GSHelpDocument *g = nil;
    PASS_RUNS(g = Parse(@"> > > > > deep-ish quote\n"),
              "multi-level quote does not raise");
    PASS(g != nil && g.rootNode != nil, "nested quote yields document");
  }
  END_SET("degenerate blocks")

  START_SET("unicode")
  {
    GSHelpDocument *d = Parse(@"# 安装指南\n\n你好 🎉 世界\n");
    NSArray *heads = NodesOfClass(d, [GSHelpHeading class]);
    PASS(heads.count == 1 && [((GSHelpHeading *)heads[0]).text
        isEqual: @"安装指南"], "CJK heading text preserved");
    PASS(d.anchors[@"安装指南"] != nil,
         "CJK anchor name derived and registered");
    GSHelpParagraph *p = FirstParagraph(d);
    PASS([PlainOf(p.children) containsString: @"你好"]
         && [PlainOf(p.children) containsString: @"🎉"],
         "CJK and emoji body text preserved");

    d = Parse(@"## Q&A: What's New?\n");
    PASS(d.anchors[@"qa-whats-new"] != nil,
         "punctuation stripped, spaces hyphenated in anchor name");

    d = Parse(@"# Über Überschriften\n");
    PASS(d.anchors[@"über-überschriften"] != nil,
         "non-ASCII letters kept in anchor names");
  }
  END_SET("unicode")

  START_SET("line endings")
  {
    GSHelpDocument *d = Parse(@"First\r\n\r\nSecond\r\n");
    NSArray *ps = NodesOfClass(d, [GSHelpParagraph class]);
    PASS(ps.count == 2, "CRLF blank line separates paragraphs");
    if (ps.count == 2) {
      PASS([PlainOf(((GSHelpParagraph *)ps[0]).children)
          isEqual: @"First"], "CR stripped from line ends");
      PASS([PlainOf(((GSHelpParagraph *)ps[1]).children)
          isEqual: @"Second"], "second CRLF paragraph clean");
    }
  }
  END_SET("line endings")

  START_SET("pathological nesting")
  {
    NSMutableString *src =
        [NSMutableString stringWithString: @"deep"];
    for (int lvl = 0; lvl < 30; lvl++) {
      [src setString: [@"> " stringByAppendingString: src]];
    }
    __block GSHelpDocument *d = nil;
    PASS_RUNS(d = Parse(src), "30-level quote nesting does not raise");

    /* walk down the quote chain */
    GSHelpNode *node = d.rootNode;
    int depth = 0;
    while (depth < 40 && node.children.count > 0) {
      BOOL descended = NO;
      for (GSHelpNode *n in node.children) {
        if ([n isKindOfClass: [GSHelpQuote class]]) {
          node = n;
          descended = YES;
          break;
        }
        if ([n isKindOfClass: [GSHelpParagraph class]]
            && depth > 0) {
          PASS([PlainOf(n.children) isEqual: @"deep"],
               "innermost quote text survives nesting");
          descended = YES;
          node = n;
          break;
        }
      }
      if (!descended) break;
      depth++;
    }

    NSMutableString *list = [NSMutableString new];
    for (int lvl = 0; lvl < 20; lvl++) {
      for (int sp = 0; sp < lvl * 2; sp++) {
        [list appendString: @" "];
      }
      [list appendFormat: @"- l%d\n", lvl];
    }
    PASS_RUNS(d = Parse(list), "20-level list nesting does not raise");
  }
  END_SET("pathological nesting")

  START_SET("unreadable input")
  {
    GSMarkdownParser *parser = [GSMarkdownParser new];
    NSString *missing =
        [@"/nonexistent/gsmdedge_" stringByAppendingFormat:
            @"%d.md", (int)getpid()];
    NSError *err = nil;
    GSHelpDocument *d = [parser parseURL:
        [NSURL fileURLWithPath: missing] error: &err];
    PASS(d == nil, "missing file returns nil document");
    PASS(err != nil, "missing file sets error");

    /* invalid UTF-8 bytes must fail cleanly, not crash */
    NSString *badPath = FixturePath();
    [[NSFileManager defaultManager]
        removeItemAtPath: badPath error: NULL];
    NSData *garbage = [NSData dataWithBytes: "\xff\xfe\xfa\xff"
                                     length: 4];
    [garbage writeToFile: badPath atomically: YES];
    err = nil;
    d = [parser parseURL: [NSURL fileURLWithPath: badPath]
                   error: &err];
    PASS(d == nil && err != nil,
         "invalid UTF-8 returns nil plus error, no crash");
    [[NSFileManager defaultManager]
        removeItemAtPath: badPath error: NULL];

    NSURL *nilURL = nil;
    __block GSHelpDocument *nd = nil;
    PASS_RUNS(nd = [parser parseURL: nilURL error: NULL],
              "nil URL does not crash");
    PASS(nd == nil, "nil URL yields no document");
  }
  END_SET("unreadable input")

  [[NSFileManager defaultManager] removeItemAtPath: FixturePath()
                                             error: NULL];

  [arp release];
  return 0;
}

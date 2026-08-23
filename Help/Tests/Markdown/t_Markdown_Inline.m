/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_Markdown_Inline - inline coverage for GSMarkdownParser: bold,
 * italic, combined emphasis, code spans, links (all target kinds),
 * images (local vs remote), backslash escapes and entity refs,
 * plus inline handling inside headings, list items, table cells
 * and blockquotes. Headless. */

#import <Foundation/Foundation.h>
#import <unistd.h>
#import "Testing.h"

#import "GSHelpNode.h"
#import "GSHelpDocument.h"
#import "GSMarkdownParser.h"

static NSString *FixturePath(void)
{
  return [NSString stringWithFormat:
      @"%@/gsmdinline_%d.md", NSTemporaryDirectory(), (int)getpid()];
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

static GSHelpParagraph *FirstParagraph(GSHelpDocument *d)
{
  for (GSHelpNode *n in d.rootNode.children) {
    if ([n isKindOfClass: [GSHelpParagraph class]]) {
      return (GSHelpParagraph *)n;
    }
  }
  return nil;
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

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("emphasis")
  {
    GSHelpDocument *d = Parse(@"pre **bold** post\n");
    NSArray *runs = FirstParagraph(d).children;
    PASS(runs.count == 3, "bold splits paragraph into three runs");
    if (runs.count == 3) {
      GSHelpText *mid = runs[1];
      PASS([mid.string isEqual: @"bold"]
           && mid.style == GSHelpTextStyleBold, "**..** is bold run");
      PASS(((GSHelpText *)runs[0]).style == GSHelpTextStylePlain
           && [((GSHelpText *)runs[0]).string isEqual: @"pre "],
           "text before bold stays plain");
    }

    GSHelpText *first;

    first = FirstParagraph(Parse(@"__under bold__\n")).children[0];
    PASS(first.style == GSHelpTextStyleBold
         && [first.string isEqual: @"under bold"], "__..__ is bold");

    first = FirstParagraph(Parse(@"*ital*\n")).children[0];
    PASS(first.style == GSHelpTextStyleItalic
         && [first.string isEqual: @"ital"], "*..* is italic");

    first = FirstParagraph(Parse(@"_under ital_\n")).children[0];
    PASS(first.style == GSHelpTextStyleItalic
         && [first.string isEqual: @"under ital"], "_.._ is italic");

    runs = FirstParagraph(Parse(@"***both***\n")).children;
    PASS(runs.count == 1, "***..*** is a single run");
    if (runs.count == 1) {
      first = runs[0];
      PASS(first.style == (GSHelpTextStyleBold | GSHelpTextStyleItalic)
           && [first.string isEqual: @"both"],
           "***..*** combines bold and italic");
    }

    runs = FirstParagraph(Parse(@"**bold *inner* tail**\n")).children;
    PASS(runs.count == 3, "nested emphasis produces three runs");
    if (runs.count == 3) {
      GSHelpText *head = runs[0];
      PASS(head.style == GSHelpTextStyleBold
           && [head.string isEqual: @"bold "],
           "outer bold before inner");
      GSHelpText *inner = runs[1];
      PASS(inner.style == (GSHelpTextStyleBold | GSHelpTextStyleItalic)
           && [inner.string isEqual: @"inner"],
           "inner run combines both styles");
      GSHelpText *tail = runs[2];
      PASS(tail.style == GSHelpTextStyleBold
           && [tail.string isEqual: @" tail"], "outer bold after inner");
    }
  }
  END_SET("emphasis")

  START_SET("code spans")
  {
    GSHelpDocument *d = Parse(@"use `help_url` now\n");
    NSArray *runs = FirstParagraph(d).children;
    PASS(runs.count == 3, "code span splits into three runs");
    if (runs.count == 3) {
      GSHelpText *mid = runs[1];
      PASS(mid.style == GSHelpTextStyleCode
           && [mid.string isEqual: @"help_url"], "`..` is code run");
    }

    d = Parse(@"a ` b\n");
    NSArray *plainRuns = FirstParagraph(d).children;
    BOOL anyCode = NO;
    for (GSHelpNode *n in plainRuns) {
      if ([n isKindOfClass: [GSHelpText class]]
          && ((GSHelpText *)n).style & GSHelpTextStyleCode) {
        anyCode = YES;
      }
    }
    PASS(!anyCode, "unmatched backtick stays literal text");
  }
  END_SET("code spans")

  START_SET("links")
  {
    GSHelpDocument *d =
        Parse(@"See [the docs](getting-started.md) now.\n");
    GSHelpLink *link = nil;
    for (GSHelpNode *n in FirstParagraph(d).children) {
      if ([n isKindOfClass: [GSHelpLink class]]) link = (GSHelpLink *)n;
    }
    PASS(link != nil, "link node produced");
    if (link != nil) {
      PASS_EQUAL(link.target, @"getting-started.md",
                 "relative target kept verbatim");
      PASS_EQUAL(link.labelText, @"the docs", "label text kept");
      PASS(link.labelRuns.count == 1
           && link.labelRuns[0].style == GSHelpTextStylePlain,
           "plain label is one plain run");
    }
    PASS_EQUAL(PlainOf(FirstParagraph(d).children),
               @"See the docs now.", "link label flows into sentence");

    /* styled label */
    d = Parse(@"[`NSString`](help://gsdoc/Foundation/NSString)\n");
    link = nil;
    for (GSHelpNode *n in FirstParagraph(d).children) {
      if ([n isKindOfClass: [GSHelpLink class]]) link = (GSHelpLink *)n;
    }
    PASS(link != nil, "code-label link produced");
    if (link != nil) {
      PASS_EQUAL(link.target, @"help://gsdoc/Foundation/NSString",
                 "help:// target kept verbatim");
      PASS(link.labelRuns.count == 1
           && link.labelRuns[0].style == GSHelpTextStyleCode
           && [link.labelRuns[0].string isEqual: @"NSString"],
           "code markup inside label becomes code-styled run");
    }

    NSArray *cases = @[
      @"[rel](sub/dir/doc.md)|sub/dir/doc.md",
      @"[anchor](#intro)|#intro",
      @"[web](https://example.com/x?q=1)|https://example.com/x?q=1",
      @"[scheme](http://example.com/)|http://example.com/"
    ];
    for (NSString *c in cases) {
      NSArray *parts =
          [c componentsSeparatedByString: @"|"];
      d = Parse(parts[0]);
      link = nil;
      for (GSHelpNode *n in FirstParagraph(d).children) {
        if ([n isKindOfClass: [GSHelpLink class]]) link = (GSHelpLink *)n;
      }
      PASS(link != nil && [link.target isEqual: parts[1]],
           "target verbatim");
    }
  }
  END_SET("links")

  START_SET("images")
  {
    GSHelpDocument *d = Parse(@"![Screenshot](images/pref.png)\n");
    GSHelpParagraph *p = FirstParagraph(d);
    GSHelpImage *img = nil;
    for (GSHelpNode *n in p.children) {
      if ([n isKindOfClass: [GSHelpImage class]]) img = (GSHelpImage *)n;
    }
    PASS(img != nil, "local image becomes GSHelpImage");
    if (img != nil) {
      PASS_EQUAL(img.path, @"images/pref.png", "image path kept");
      PASS_EQUAL(img.altText, @"Screenshot", "alt text kept");
    }
    PASS([PlainOf(p.children) isEqual: @""], "no duplicate alt text run");

    d = Parse(@"![alt word](https://ex.com/i.png)\n");
    p = FirstParagraph(d);
    BOOL hasImage = NO;
    for (GSHelpNode *n in p.children) {
      if ([n isKindOfClass: [GSHelpImage class]]) hasImage = YES;
    }
    PASS(!hasImage, "remote image reference produces no image node");
    PASS_EQUAL(PlainOf(p.children), @"alt word",
               "remote image degrades to its alt text");

    d = Parse(@"Before ![i](a.png) after\n");
    p = FirstParagraph(d);
    PASS(p.children.count == 3, "inline image sits between text runs");
    if (p.children.count == 3) {
      GSHelpImage *mid = nil;
      if ([p.children[1] isKindOfClass: [GSHelpImage class]]) {
        mid = (GSHelpImage *)p.children[1];
      }
      PASS(mid != nil, "middle child is the image");
      PASS([PlainOf(@[ p.children[0] ]) isEqual: @"Before "]
           && [PlainOf(@[ p.children[2] ]) isEqual: @" after"],
           "text runs around inline image preserved");
    }
  }
  END_SET("images")

  START_SET("escapes and entities")
  {
    GSHelpDocument *d = Parse(@"a \\*not em\\* b\n");
    GSHelpParagraph *p = FirstParagraph(d);
    PASS_EQUAL(PlainOf(p.children), @"a *not em* b",
               "escaped asterisks stay literal");
    BOOL anyItalic = NO;
    for (GSHelpNode *n in p.children) {
      if ([n isKindOfClass: [GSHelpText class]]
          && ((GSHelpText *)n).style & GSHelpTextStyleItalic) {
        anyItalic = YES;
      }
    }
    PASS(!anyItalic, "escape suppresses emphasis");

    d = Parse(@"\\`notcode\\`\n");
    p = FirstParagraph(d);
    PASS_EQUAL(PlainOf(p.children), @"`notcode`",
               "escaped backticks stay literal");
    for (GSHelpNode *n in p.children) {
      if ([n isKindOfClass: [GSHelpText class]]) {
        PASS(!(((GSHelpText *)n).style & GSHelpTextStyleCode),
             "escape prevents code style");
        break;
      }
    }

    d = Parse(@"&amp; &lt; &gt; &quot;\n");
    PASS_EQUAL(PlainOf(FirstParagraph(d).children), @"& < > \"",
               "entity refs decoded");

    d = Parse(@"AT&T and &bogus; stay\n");
    PASS_EQUAL(PlainOf(FirstParagraph(d).children),
               @"AT&T and &bogus; stay",
               "bare ampersand and unknown entity stay literal");
  }
  END_SET("escapes and entities")

  START_SET("inline inside blocks")
  {
    GSHelpDocument *d = Parse(@"# My **Fancy** _Title_\n");
    GSHelpHeading *h = nil;
    for (GSHelpNode *n in d.rootNode.children) {
      if ([n isKindOfClass: [GSHelpHeading class]]) h = (GSHelpHeading *)n;
    }
    PASS(h != nil && [h.text isEqual: @"My Fancy Title"],
         "heading inline flattened to plain text");

    d = Parse(@"- **big** item\n");
    GSHelpListItem *item = nil;
    for (GSHelpNode *n in d.rootNode.children) {
      if ([n isKindOfClass: [GSHelpList class]]) {
        item = ((GSHelpList *)n).children.firstObject;
      }
    }
    PASS(item != nil && item.children.count == 2,
         "list item has two runs");
    if (item != nil && item.children.count == 2) {
      GSHelpText *first = item.children[0];
      PASS(first.style == GSHelpTextStyleBold
           && [first.string isEqual: @"big"], "item lead run bold");
      PASS([((GSHelpText *)item.children[1]).string isEqual: @" item"],
           "item tail run plain");
    }

    d = Parse(@"| **B** | `c` |\n|---|---|\n| *i* | x |\n");
    GSHelpTable *t = nil;
    for (GSHelpNode *n in d.rootNode.children) {
      if ([n isKindOfClass: [GSHelpTable class]]) t = (GSHelpTable *)n;
    }
    PASS(t != nil && t.rows.count == 2, "table with inline markup parses");
    if (t != nil && t.rows.count == 2) {
      NSArray<GSHelpTableCell *> *head = t.rows[0].cells;
      NSArray<GSHelpTableCell *> *body = t.rows[1].cells;
      PASS(head.count == 2 && [head[0].text isEqual: @"B"]
           && [head[1].text isEqual: @"c"],
           "header cell markup stripped to plain text");
      PASS(body.count == 2 && [body[0].text isEqual: @"i"]
           && [body[1].text isEqual: @"x"], "body cell markup stripped");
    }

    d = Parse(@"> **careful** now\n");
    GSHelpQuote *q = nil;
    for (GSHelpNode *n in d.rootNode.children) {
      if ([n isKindOfClass: [GSHelpQuote class]]) q = (GSHelpQuote *)n;
    }
    PASS(q != nil && q.children.count == 1, "quote with inline markup");
    if (q != nil && q.children.count == 1) {
      NSArray *runs = [q.children[0] children];
      PASS(runs.count == 2
           && ((GSHelpText *)runs[0]).style == GSHelpTextStyleBold,
           "quote paragraph keeps bold run");
    }

    d = Parse(@"[*deep* link](x.md)\n");
    GSHelpLink *link = nil;
    for (GSHelpNode *n in FirstParagraph(d).children) {
      if ([n isKindOfClass: [GSHelpLink class]]) link = (GSHelpLink *)n;
    }
    PASS(link != nil && link.labelRuns.count == 2,
         "styled link label has two runs");
    if (link != nil && link.labelRuns.count == 2) {
      PASS(link.labelRuns[0].style == GSHelpTextStyleItalic
           && [link.labelRuns[0].string isEqual: @"deep"]
           && [link.labelRuns[1].string isEqual: @" link"],
           "label emphasis styles preserved");
    }
  }
  END_SET("inline inside blocks")

  [[NSFileManager defaultManager] removeItemAtPath: FixturePath()
                                             error: NULL];

  [arp release];
  return 0;
}

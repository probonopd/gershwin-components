/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_Markdown_Blocks - block-level coverage for GSMarkdownParser:
 * canParseURL (extension + content sniff), ATX headings with implicit
 * anchors, paragraphs, fenced and indented code blocks, flat and
 * nested lists, blockquotes, pipe tables, horizontal rules and the
 * derived TOC. Headless. */

#import <Foundation/Foundation.h>
#import <unistd.h>
#import "Testing.h"

#import "GSHelpNode.h"
#import "GSHelpDocument.h"
#import "GSMarkdownParser.h"

static NSString *FixturePath(void)
{
  return [NSString stringWithFormat:
      @"%@/gsmdblock_%d.md", NSTemporaryDirectory(), (int)getpid()];
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

static id FirstOfClass(GSHelpDocument *d, Class c)
{
  NSArray *all = NodesOfClass(d, c);
  return [all count] > 0 ? all[0] : nil;
}

static NSString *PlainOf(NSArray *nodes)
{
  NSMutableString *s = [NSMutableString new];
  for (GSHelpNode *n in nodes) {
    if ([n isKindOfClass: [GSHelpText class]]) {
      [s appendString: ((GSHelpText *)n).string];
    }
  }
  return s;
}

static NSString *PlainTextInQuote(GSHelpQuote *q)
{
  NSMutableString *s = [NSMutableString new];
  for (GSHelpNode *n in q.children) {
    if ([n isKindOfClass: [GSHelpParagraph class]]) {
      [s appendString: PlainOf([n children])];
    }
  }
  return s;
}

static NSString *NoExtensionCopyOfFixture(void)
{
  NSString *p = [NSTemporaryDirectory()
      stringByAppendingFormat: @"/gsmdsniff_%d", (int)getpid()];
  [[NSFileManager defaultManager] removeItemAtPath: p error: NULL];
  [[NSFileManager defaultManager]
      moveItemAtPath: FixturePath() toPath: p error: NULL];
  return p;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("canParseURL extensions")
  {
    GSMarkdownParser *p = [GSMarkdownParser new];
    PASS([p canParseURL: [NSURL URLWithString: @"file:///tmp/a.md"]],
         ".md accepted");
    PASS([p canParseURL: [NSURL URLWithString: @"file:///tmp/a.markdown"]],
         ".markdown accepted");
    PASS([p canParseURL: [NSURL URLWithString: @"file:///tmp/a.mdown"]],
         ".mdown accepted");
    PASS(![p canParseURL: [NSURL URLWithString: @"file:///tmp/b.txt"]],
         ".txt rejected by extension");
    NSURL *nilURL = nil;
    PASS(![p canParseURL: nilURL], "nil URL rejected without crash");
  }
  END_SET("canParseURL extensions")

  START_SET("canParseURL content sniff")
  {
    GSMarkdownParser *p = [GSMarkdownParser new];

    WriteFixture(@"# Sniffed Heading\n\nbody\n");
    NSString *h1 = NoExtensionCopyOfFixture();
    PASS([p canParseURL: [NSURL fileURLWithPath: h1]],
         "extension-less file with # heading accepted");

    WriteFixture(@"```\nsay_hi\n```\n");
    NSString *fence = NoExtensionCopyOfFixture();
    PASS([p canParseURL: [NSURL fileURLWithPath: fence]],
         "extension-less file with fence accepted");

    WriteFixture(@"just plain words\nmore words\n");
    NSString *plain = NoExtensionCopyOfFixture();
    PASS(![p canParseURL: [NSURL fileURLWithPath: plain]],
         "plain extension-less file rejected");

    NSString *missing =
        [@"/nonexistent/gsmd_" stringByAppendingFormat:
            @"%d", (int)getpid()];
    PASS(![p canParseURL: [NSURL fileURLWithPath: missing]],
         "missing extension-less file rejected without crash");

    [[NSFileManager defaultManager] removeItemAtPath: h1 error: NULL];
    [[NSFileManager defaultManager] removeItemAtPath: fence error: NULL];
    [[NSFileManager defaultManager] removeItemAtPath: plain error: NULL];
  }
  END_SET("canParseURL content sniff")

  START_SET("headings and anchors")
  {
    GSHelpDocument *d = Parse(@"# Title One\n\n## Sub Section\n");
    PASS(d != nil, "document produced");
    PASS([d.sourceType isEqualToString: @"markdown"], "sourceType markdown");
    NSArray *heads = NodesOfClass(d, [GSHelpHeading class]);
    PASS(heads.count == 2, "two headings");
    if (heads.count == 2) {
      GSHelpHeading *h1 = heads[0];
      GSHelpHeading *h2 = heads[1];
      PASS(h1.level == 1 && [h1.text isEqual: @"Title One"],
           "H1 text and level");
      PASS(h2.level == 2, "H2 level");
    }
    PASS_EQUAL(d.title, @"Title One", "title is first H1 text");
    PASS(d.anchors[@"title-one"] != nil, "anchor title-one derived");
    PASS(d.anchors[@"sub-section"] != nil, "anchor sub-section derived");
    PASS([d.rootNode.children[0] isKindOfClass: [GSHelpAnchor class]]
         && [d.rootNode.children[1] isKindOfClass: [GSHelpHeading class]],
         "anchor emitted immediately before its heading");

    d = Parse(@"#### Four\n##### Five\n###### Six\n");
    heads = NodesOfClass(d, [GSHelpHeading class]);
    PASS(heads.count == 3, "ATX headings past level 4 kept as headings");
    BOOL clamped = YES;
    for (GSHelpHeading *h in heads) {
      if (h.level != 4) clamped = NO;
    }
    PASS(clamped, "levels above 4 clamp to 4");

    d = Parse(@"## Trailing ##\n");
    GSHelpHeading *h = FirstOfClass(d, [GSHelpHeading class]);
    PASS(h != nil && [h.text isEqual: @"Trailing"],
         "closing hashes stripped from heading");

    d = Parse(@"# My **Fancy** Title\n");
    h = FirstOfClass(d, [GSHelpHeading class]);
    PASS(h != nil && [h.text isEqual: @"My Fancy Title"],
         "heading inline markup flattened to plain text");
  }
  END_SET("headings and anchors")

  START_SET("paragraphs")
  {
    GSHelpDocument *d = Parse(@"First para here.\n\nSecond para.\n");
    NSArray *ps = NodesOfClass(d, [GSHelpParagraph class]);
    PASS(ps.count == 2, "blank line separates paragraphs");
    if (ps.count == 2) {
      PASS_EQUAL(PlainOf(((GSHelpParagraph *)ps[0]).children),
                 @"First para here.", "first paragraph text");
    }

    d = Parse(@"line one\nline two\n");
    ps = NodesOfClass(d, [GSHelpParagraph class]);
    PASS(ps.count == 1, "consecutive lines join into one paragraph");
    if (ps.count == 1) {
      PASS_EQUAL(PlainOf(((GSHelpParagraph *)ps[0]).children),
                 @"line one line two", "soft-wrapped lines joined");
    }
  }
  END_SET("paragraphs")

  START_SET("fenced code")
  {
    GSHelpDocument *d =
        Parse(@"```objc\nint main(void)\n{\n  return 0;\n}\n```\n\nAfter.\n");
    GSHelpCodeBlock *cb = FirstOfClass(d, [GSHelpCodeBlock class]);
    PASS(cb != nil, "fenced block produced");
    if (cb != nil) {
      PASS_EQUAL(cb.language, @"objc", "fence info string is language");
      PASS_EQUAL(cb.code, @"int main(void)\n{\n  return 0;\n}",
                 "code lines preserved verbatim");
    }
    PASS(NodesOfClass(d, [GSHelpParagraph class]).count == 1,
         "text after closing fence is prose again");

    d = Parse(@"```js\nlet x = 1;\n");
    cb = FirstOfClass(d, [GSHelpCodeBlock class]);
    PASS(cb != nil, "unterminated fence still yields code block");
    if (cb != nil) {
      PASS_EQUAL(cb.code, @"let x = 1;", "unterminated fence runs to EOF");
      PASS_EQUAL(cb.language, @"js", "unterminated fence keeps language");
    }
  }
  END_SET("fenced code")

  START_SET("indented code")
  {
    GSHelpDocument *d =
        Parse(@"Intro:\n\n    indented line\n    second line\n\nOutro.\n");
    GSHelpCodeBlock *cb = FirstOfClass(d, [GSHelpCodeBlock class]);
    PASS(cb != nil, "4-space indented block is code");
    if (cb != nil) {
      PASS_EQUAL(cb.code, @"indented line\nsecond line",
                 "indentation stripped, inner spacing kept");
    }
    PASS(NodesOfClass(d, [GSHelpParagraph class]).count == 2,
         "surrounding prose intact");
  }
  END_SET("indented code")

  START_SET("flat lists")
  {
    GSHelpDocument *d = Parse(@"- alpha\n- beta\n- gamma\n");
    GSHelpList *list = FirstOfClass(d, [GSHelpList class]);
    PASS(list != nil, "unordered list produced");
    if (list != nil) {
      PASS(list.isOrdered == NO, "dash list is unordered");
      PASS(list.children.count == 3, "three items");
      if (list.children.count == 3) {
        PASS_EQUAL(PlainOf([list.children[0] children]), @"alpha",
                   "first item text");
      }
    }

    d = Parse(@"* star one\n* star two\n");
    list = FirstOfClass(d, [GSHelpList class]);
    PASS(list != nil && list.children.count == 2, "asterisk markers work");

    d = Parse(@"+ plus one\n+ plus two\n");
    list = FirstOfClass(d, [GSHelpList class]);
    PASS(list != nil && list.children.count == 2, "plus markers work");

    d = Parse(@"1. one\n2. two\n3. three\n");
    list = FirstOfClass(d, [GSHelpList class]);
    PASS(list != nil && list.isOrdered == YES, "numeric list is ordered");
    PASS(list.children.count == 3, "ordered list has three items");

    d = Parse(@"10. ten\n11. eleven\n");
    list = FirstOfClass(d, [GSHelpList class]);
    PASS(list != nil && list.isOrdered && list.children.count == 2,
         "multi-digit ordered markers work");
  }
  END_SET("flat lists")

  START_SET("nested lists")
  {
    GSHelpDocument *d = Parse(@"- a\n- b\n  - b1\n  - b2\n- c\n");
    GSHelpList *outer = FirstOfClass(d, [GSHelpList class]);
    PASS(outer != nil && outer.children.count == 3,
         "outer list has three items");
    if (outer != nil && outer.children.count == 3) {
      GSHelpListItem *b = outer.children[1];
      GSHelpList *sub = nil;
      for (GSHelpNode *n in b.children) {
        if ([n isKindOfClass: [GSHelpList class]]) sub = (GSHelpList *)n;
      }
      PASS(sub != nil, "item b holds a nested list");
      if (sub != nil) {
        PASS(sub.children.count == 2, "nested list has two items");
        if (sub.children.count == 2) {
          PASS_EQUAL(PlainOf([sub.children[0] children]), @"b1",
                     "nested item text");
        }
      }
      PASS_EQUAL(PlainOf(b.children), @"b",
                 "item text precedes nested list content");
    }

    d = Parse(@"- top\n  - mid\n    - low\n");
    outer = FirstOfClass(d, [GSHelpList class]);
    PASS(outer != nil && outer.children.count == 1, "three-deep: outer");
    if (outer != nil && outer.children.count == 1) {
      GSHelpList *mid = nil;
      for (GSHelpNode *n in [outer.children[0] children]) {
        if ([n isKindOfClass: [GSHelpList class]]) mid = (GSHelpList *)n;
      }
      PASS(mid != nil && mid.children.count == 1,
           "three-deep: middle list");
      if (mid != nil && mid.children.count == 1) {
        GSHelpList *low = nil;
        for (GSHelpNode *n in [mid.children[0] children]) {
          if ([n isKindOfClass: [GSHelpList class]]) low = (GSHelpList *)n;
        }
        PASS(low != nil && low.children.count == 1,
             "three-deep: innermost list");
        if (low != nil && low.children.count == 1) {
          PASS_EQUAL(PlainOf([low.children[0] children]), @"low",
                     "three-deep: innermost text");
        }
      }
    }

    d = Parse(@"1. x\n   - y\n");
    outer = FirstOfClass(d, [GSHelpList class]);
    PASS(outer != nil && outer.isOrdered && outer.children.count == 1,
         "ordered parent with nested child parses");
    if (outer != nil && outer.children.count == 1) {
      GSHelpList *sub = nil;
      for (GSHelpNode *n in [outer.children[0] children]) {
        if ([n isKindOfClass: [GSHelpList class]]) sub = (GSHelpList *)n;
      }
      PASS(sub != nil && !sub.isOrdered && sub.children.count == 1,
           "nested unordered list under ordered item");
    }

    d = Parse(@"- keep\n\n- resume\n");
    NSUInteger listCount =
        NodesOfClass(d, [GSHelpList class]).count;
    PASS(listCount >= 1, "blank line between items does not crash");
  }
  END_SET("nested lists")

  START_SET("blockquotes")
  {
    GSHelpDocument *d = Parse(@"> quoted words\n\nafter\n");
    GSHelpQuote *q = FirstOfClass(d, [GSHelpQuote class]);
    PASS(q != nil, "blockquote produced");
    if (q != nil) {
      PASS(q.children.count == 1
           && [q.children[0] isKindOfClass: [GSHelpParagraph class]],
           "quote holds one paragraph");
      if (q.children.count == 1) {
        PASS_EQUAL(PlainOf([q.children[0] children]), @"quoted words",
                   "quote paragraph text");
      }
    }
    PASS(NodesOfClass(d, [GSHelpParagraph class]).count == 1,
         "text after quote stays outside the quote");

    d = Parse(@"> line one\n> line two\n");
    q = FirstOfClass(d, [GSHelpQuote class]);
    PASS(q != nil && q.children.count == 1
         && [PlainTextInQuote(q) isEqual: @"line one line two"],
         "multi-line quote joins into one paragraph");

    d = Parse(@"> outer\n> > inner\n");
    q = FirstOfClass(d, [GSHelpQuote class]);
    PASS(q != nil && q.children.count == 2, "nested quote has two children");
    if (q != nil && q.children.count == 2) {
      PASS([q.children[1] isKindOfClass: [GSHelpQuote class]],
           "second child is the inner quote");
      GSHelpQuote *inner = q.children[1];
      PASS(inner.children.count == 1
           && [PlainTextInQuote(inner) isEqual: @"inner"],
           "inner quote text");
    }
  }
  END_SET("blockquotes")

  START_SET("pipe tables")
  {
    GSHelpDocument *d = Parse(
        @"| Name | Value |\n|------|-------|\n| a | 1 |\n| b | 2 |\n\ndone\n");
    GSHelpTable *t = FirstOfClass(d, [GSHelpTable class]);
    PASS(t != nil, "table produced from header + separator + rows");
    if (t != nil) {
      PASS(t.rows.count == 3, "header plus two body rows");
      if (t.rows.count == 3) {
        NSArray<GSHelpTableCell *> *head = t.rows[0].cells;
        PASS(head.count == 2
             && [head[0].text isEqual: @"Name"]
             && [head[1].text isEqual: @"Value"], "header cell texts");
        NSArray<GSHelpTableCell *> *row1 = t.rows[1].cells;
        PASS(row1.count == 2
             && [row1[0].text isEqual: @"a"]
             && [row1[1].text isEqual: @"1"], "body row cells");
      }
    }

    d = Parse(@"| L | R |\n| :-- | --: |\n| x | y |\n");
    t = FirstOfClass(d, [GSHelpTable class]);
    PASS(t != nil && t.rows.count == 2,
         "alignment colons in separator row tolerated");

    d = Parse(@"| a | b |\nnot a separator\n");
    PASS(FirstOfClass(d, [GSHelpTable class]) == nil,
         "row without separator line does not become a table");
    NSArray *ps = NodesOfClass(d, [GSHelpParagraph class]);
    PASS(ps.count == 1, "bad table degrades to paragraph");
  }
  END_SET("pipe tables")

  START_SET("horizontal rules")
  {
    NSArray *sources =
        @[ @"---\n", @"***\n", @"___\n", @"- - -\n", @"* * *\n" ];
    for (NSString *src in sources) {
      GSHelpDocument *d = Parse(src);
      GSHelpParagraph *p = FirstOfClass(d, [GSHelpParagraph class]);
      PASS(p != nil && p.children.count == 1,
           "rule line becomes single-run paragraph");
      if (p != nil && p.children.count == 1) {
        GSHelpText *run = p.children[0];
        PASS([run.string isEqual: @"---"]
             && run.style == GSHelpTextStylePlain,
             "rule rendered as plain --- run");
      }
    }

    GSHelpDocument *d = Parse(@"above\n\n---\n\nbelow\n");
    PASS(NodesOfClass(d, [GSHelpParagraph class]).count == 3,
         "rule between paragraphs keeps prose intact");

    d = Parse(@"**bold line***\n");
    GSHelpParagraph *p = FirstOfClass(d, [GSHelpParagraph class]);
    PASS(p != nil, "asterisk-heavy text is not mistaken for a rule");
  }
  END_SET("horizontal rules")

  START_SET("table of contents")
  {
    GSHelpDocument *d = Parse(@"# A\n\n## B\n\n## C\n\n### D\n");
    NSArray<GSHelpTOCEntry *> *toc = d.tableOfContents;
    PASS(toc.count == 4, "TOC has one entry per heading");
    if (toc.count == 4) {
      PASS(toc[0].level == 1 && toc[1].level == 2
           && toc[2].level == 2 && toc[3].level == 3,
           "TOC levels follow heading levels");
      PASS([toc[0].heading.text isEqual: @"A"]
           && [toc[3].heading.text isEqual: @"D"],
           "TOC entries reference headings in order");
    }
  }
  END_SET("table of contents")

  [[NSFileManager defaultManager] removeItemAtPath: FixturePath()
                                             error: NULL];

  [arp release];
  return 0;
}


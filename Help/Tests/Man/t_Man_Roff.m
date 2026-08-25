/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_Man_Roff - roff macro coverage for GSManParser: .TH metadata,
 * .SH/.SS headings, .PP breaks, font macros, .TP, .IP/.HP lists,
 * .nf/.fi, escapes, comments, unknown macros, cross-references,
 * malformed and empty input. Headless. */

#import <Foundation/Foundation.h>
#import <unistd.h>
#import "Testing.h"

#import "GSHelpNode.h"
#import "GSHelpDocument.h"
#import "GSHelpURL.h"
#import "GSManParser.h"

static NSString *FixturePath(void)
{
  return [NSString stringWithFormat:
      @"%@/gsmanroff_%d_1", NSTemporaryDirectory(), (int)getpid()];
}

static void RemoveFixture(void)
{
  [[NSFileManager defaultManager] removeItemAtPath: FixturePath()
                                             error: NULL];
}

static NSString *WritePage(NSString *src)
{
  RemoveFixture();
  [src writeToFile: FixturePath() atomically: YES
         encoding: NSUTF8StringEncoding error: NULL];
  return FixturePath();
}

static GSHelpDocument *Parse(NSString *src)
{
  NSURL *url = [NSURL fileURLWithPath: WritePage(src)];
  return [[GSManParser new] parseURL: url error: nil];
}

static GSHelpHeading *HeadingNamed(GSHelpDocument *d, NSString *name)
{
  for (GSHelpNode *n in d.rootNode.children) {
    if ([n isKindOfClass: [GSHelpHeading class]]
        && [((GSHelpHeading *)n).text isEqual: name]) {
      return (GSHelpHeading *)n;
    }
  }
  return nil;
}

static NSArray<GSHelpParagraph *> *Paragraphs(GSHelpDocument *d)
{
  NSMutableArray *r = [NSMutableArray new];
  for (GSHelpNode *n in d.rootNode.children) {
    if ([n isKindOfClass: [GSHelpParagraph class]]) {
      [r addObject: (GSHelpParagraph *)n];
    }
  }
  return r;
}

static NSString *PlainOf(id nodesOrSection)
{
  NSArray<GSHelpNode *> *nodes = [nodesOrSection isKindOfClass: [NSArray class]]
      ? nodesOrSection : [nodesOrSection children];
  NSMutableString *s = [NSMutableString new];
  for (GSHelpNode *n in nodes) {
    if ([n isKindOfClass: [GSHelpText class]]) {
      [s appendString: ((GSHelpText *)n).string];
    }
  }
  return s;
}

static GSHelpTextStyle StyleOfFirstRun(GSHelpDocument *d, NSUInteger paragraphIndex)
{
  GSHelpParagraph *p = Paragraphs(d)[paragraphIndex];
  for (GSHelpNode *n in p.children) {
    if ([n isKindOfClass: [GSHelpText class]]) {
      return ((GSHelpText *)n).style;
    }
  }
  return GSHelpTextStylePlain;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("canParseURL")
  {
    GSManParser *p = [GSManParser new];
    PASS([p canParseURL: [NSURL URLWithString: @"file:///tmp/foo.1"]],
         "foo.1 accepted");
    PASS([p canParseURL: [NSURL URLWithString: @"file:///usr/share/man/foo.3x"]],
         "letter-suffixed section foo.3x accepted");
    PASS([p canParseURL: [NSURL URLWithString: @"file:///tmp/foo.1.gz"]],
         "compressed foo.1.gz accepted");
    PASS([p canParseURL: [NSURL fileURLWithPath: @"/tmp/gsmanx.2.bz2"]],
         "foo.2.bz2 accepted");
    PASS([p canParseURL: [NSURL fileURLWithPath: @"/tmp/gsmanx.7.xz"]],
         "foo.7.xz accepted");
    PASS (![p canParseURL: [NSURL URLWithString: @"file:///tmp/README.md"]],
          "README.md rejected");
    PASS (![p canParseURL: [NSURL URLWithString: @"file:///tmp/plainfile"]],
          "extension-less name rejected");
    NSURL *nilURL = nil;
    BOOL nilOk = [p canParseURL: nilURL];
    PASS(!nilOk, "nil URL rejected without crash");
  }
  END_SET("canParseURL")

  START_SET(".TH metadata")
  {
    GSHelpDocument *d = Parse(
        @".TH LS 1 \"May 2023\" \"Utilities\" \"User Commands\"\n"
        @".SH NAME\n"
        @"ls \\- list directory contents\n");
    PASS(d != nil, "document produced");
    PASS([d.sourceType isEqualToString: @"man"], "sourceType is man");
    PASS_EQUAL(d.metadata[@"command"], @"LS", "command from .TH arg 1");
    PASS_EQUAL(d.metadata[@"section"], @"1", "section from .TH arg 2");
    PASS_EQUAL(d.metadata[@"shortDescription"], @"list directory contents",
               "shortDescription from NAME split");
    PASS_EQUAL(d.title, @"LS(1)", "title is cmd(section)");
    GSHelpHeading *h = HeadingNamed(d, @"NAME");
    PASS(h != nil, "NAME heading exists");
    PASS(h.level == 1, "NAME heading level 1");
  }
  END_SET(".TH metadata")

  START_SET("headings")
  {
    GSHelpDocument *d = Parse(
        @".TH T 1\n.SH FILES\nbody\n.SS Examples\nsub body\n");
    GSHelpHeading *h1 = HeadingNamed(d, @"FILES");
    GSHelpHeading *h2 = HeadingNamed(d, @"Examples");
    PASS(h1 != nil && h1.level == 1, ".SH yields level 1 heading");
    PASS(h2 != nil && h2.level == 2, ".SS yields level 2 heading");
    PASS(Paragraphs(d).count == 2, "bodies became two paragraphs");
  }
  END_SET("headings")

  START_SET("paragraph breaks")
  {
    GSHelpDocument *d = Parse(
        @".TH T 1\n.SH DESCRIPTION\none\n.PP\ntwo\n.LP\nthree\n.P\nfour\n");
    PASS(Paragraphs(d).count == 4,
         ".PP/.LP/.P each start a new paragraph");
  }
  END_SET("paragraph breaks")

  START_SET("font macros")
  {
    GSHelpDocument *d = Parse(@".TH T 1\n.B ls\n");
    PASS_EQUAL(PlainOf(Paragraphs(d)[0].children), @"ls", ".B text kept");
    PASS(StyleOfFirstRun(d, 0) == GSHelpTextStyleBold, ".B run is bold");

    d = Parse(@".TH T 1\n.I opt\n");
    PASS(StyleOfFirstRun(d, 0) == GSHelpTextStyleItalic, ".I run is italic");

    /* .BI alternates bold/italic across space-separated args */
    d = Parse(@".TH T 1\n.BI one two three\n");
    NSArray *runs = Paragraphs(d)[0].children;
    PASS(runs.count == 3, ".BI made one run per arg");
    PASS(StyleOfFirstRun(d, 0) == GSHelpTextStyleBold
         && ((GSHelpText *)runs[1]).style == GSHelpTextStyleItalic
         && ((GSHelpText *)runs[2]).style == GSHelpTextStyleBold,
         ".BI alternates bold/italic/bold");

    d = Parse(@".TH T 1\n.RB a b\n");
    NSArray *rb = Paragraphs(d)[0].children;
    PASS(((GSHelpText *)rb[0]).style == GSHelpTextStylePlain
         && ((GSHelpText *)rb[1]).style == GSHelpTextStyleBold,
         ".RB alternates roman/bold");

    d = Parse(@".TH T 1\n.IR a b\n");
    NSArray *ir = Paragraphs(d)[0].children;
    PASS(((GSHelpText *)ir[0]).style == GSHelpTextStyleItalic
         && ((GSHelpText *)ir[1]).style == GSHelpTextStylePlain,
         ".IR alternates italic/roman");

    d = Parse(@".TH T 1\n.SB small\n");
    PASS(StyleOfFirstRun(d, 0) == GSHelpTextStyleBold, ".SB renders bold");

    d = Parse(@".TH T 1\n.SM tiny\n");
    PASS(StyleOfFirstRun(d, 0) == GSHelpTextStylePlain, ".SM renders plain");

    /* synopsis shape: bold command line followed by plain operands */
    d = Parse(@".TH ls 1\n.SH SYNOPSIS\n.B ls\n[OPTION]... [FILE]...\n");
    NSArray *syn = Paragraphs(d)[0].children;
    PASS(syn.count == 2, "bold command + plain operands are two runs");
    PASS(((GSHelpText *)syn[0]).style == GSHelpTextStyleBold
         && ((GSHelpText *)syn[0]).string != nil,
         "first synopsis run bold");
    /* Roff fill mode joins a macro line and the following text line
     * with a space: nroff renders "ls [OPTION]... [FILE]...". */
    PASS_EQUAL(PlainOf(syn), @"ls [OPTION]... [FILE]...",
               "synopsis runs concatenated");
  }
  END_SET("font macros")

  START_SET(".TP tagged paragraph")
  {
    GSHelpDocument *d = Parse(
        @".TH T 1\n.TP\n.B \\-v\nverbose mode output\n");
    NSArray<GSHelpParagraph *> *ps = Paragraphs(d);
    PASS(ps.count == 1, ".TP block is a single paragraph");
    NSArray *runs = ps[0].children;
    PASS(runs.count >= 2, "tag plus body runs present");
    PASS(((GSHelpText *)runs[0]).style == GSHelpTextStyleBold,
         "tag line rendered bold");
    /* The joiner space between tag and body lives on the tag run. */
    PASS_EQUAL(((GSHelpText *)runs[0]).string, @"-v ",
               "\\- in tag unescaped to hyphen");
    BOOL bodyPlain = NO;
    for (GSHelpNode *n in runs) {
      if ([n isKindOfClass: [GSHelpText class]]
          && [((GSHelpText *)n).string isEqualToString: @"verbose mode output"]
          && ((GSHelpText *)n).style == GSHelpTextStylePlain) {
        bodyPlain = YES;
      }
    }
    PASS(bodyPlain, "body after tag is plain text");
  }
  END_SET(".TP tagged paragraph")

  START_SET(".IP list")
  {
    GSHelpDocument *d = Parse(
        @".TH T 1\n.IP opt1\ndesc one\n.IP opt2\ndesc two\n.IP opt3\ndesc three\n");
    GSHelpList *list = nil;
    for (GSHelpNode *n in d.rootNode.children) {
      if ([n isKindOfClass: [GSHelpList class]]) {
        list = (GSHelpList *)n;
      }
    }
    PASS(list != nil, "consecutive .IP grouped into one list");
    PASS(list.isOrdered == NO, "list is unordered");
    PASS(list.children.count == 3, "three .IP -> three items");
    GSHelpListItem *item0 = list.children[0];
    PASS(item0.children.count >= 2, "item holds tag and description");
    GSHelpText *tag = item0.children[0];
    PASS(tag.style == GSHelpTextStyleBold && [tag.string isEqual: @"opt1 "],
         "tag is bold first run");
    PASS_EQUAL(PlainOf(item0.children), @"opt1 desc one",
               "description kept in same item");

    /* a .PP between .IP groups starts a fresh list */
    d = Parse(@".TH T 1\n.IP a\nx\n.PP\n.IP b\ny\n");
    NSUInteger lists = 0;
    for (GSHelpNode *n in d.rootNode.children) {
      if ([n isKindOfClass: [GSHelpList class]]) {
        lists++;
      }
    }
    PASS(lists == 2, ".PP interrupts list grouping");
  }
  END_SET(".IP list")

  START_SET(".HP hanging paragraphs")
  {
    GSHelpDocument *d = Parse(
        @".TH T 1\n.HP\nfirst hanging\n.HP\nsecond hanging\n");
    GSHelpList *list = nil;
    for (GSHelpNode *n in d.rootNode.children) {
      if ([n isKindOfClass: [GSHelpList class]]) {
        list = (GSHelpList *)n;
      }
    }
    PASS(list != nil && list.children.count == 2,
         "two .HP grouped into one two-item list");
  }
  END_SET(".HP hanging paragraphs")

  START_SET(".nf/.fi verbatim")
  {
    GSHelpDocument *d = Parse(
        @".TH T 1\n.nf\nusage: ls [-l]\n    indent kept\n.fi\nafter fi\n");
    GSHelpCodeBlock *cb = nil;
    for (GSHelpNode *n in d.rootNode.children) {
      if ([n isKindOfClass: [GSHelpCodeBlock class]]) {
        cb = (GSHelpCodeBlock *)n;
      }
    }
    PASS(cb != nil, ".nf..fi produced a code block");
    PASS_EQUAL(cb.code, @"usage: ls [-l]\n    indent kept\n",
               "verbatim lines preserved including indentation");
    PASS(Paragraphs(d).count == 1, "text after .fi is prose again");
  }
  END_SET(".nf/.fi verbatim")

  START_SET("escapes")
  {
    GSHelpDocument *d = Parse(
        @".TH T 1\n.SH DESCRIPTION\na \\- b \\(em c \\&d \\\\e \\(zz \\fBx\\fP y\n");
    PASS_EQUAL(PlainOf(Paragraphs(d)[0].children),
               @"a - b - c d \\e zz x y",
               "escapes: \\- \\(em dropped \\& literal \\\\ unknown \\(zz, \\f switches removed");

    d = Parse(@".TH T 1\n.SH NAME\np \\- \\(aqquoted\\(aq \\(dqD\\(dq\n");
    PASS_EQUAL(d.metadata[@"shortDescription"], @"'quoted' \"D\"",
               "\(aq and \(dq mapped to ASCII quotes");
  }
  END_SET("escapes")

  START_SET("comments skipped")
  {
    GSHelpDocument *d = Parse(
        @".\\\" top comment\n"
        @".TH T 1\n"
        @".\" mid comment\n"
        @".SH NAME\n"
        @"page \\- test\n"
        @".' trailing comment\n"
        @"real line\n");
    NSString *all = PlainOf(d.rootNode);
    PASS(![all containsString: @"comment"],
         "no comment text leaked into document");
    GSHelpHeading *h = HeadingNamed(d, @"NAME");
    PASS(h != nil, "structure intact around comments");
  }
  END_SET("comments skipped")

  START_SET("unknown macro ignored")
  {
    __block GSHelpDocument *d = nil;
    PASS_RUNS(d = Parse(@".FOO junk here\n.TH T 1\n.SH NAME\nt \\- d\n"),
              "unknown macro does not raise");
    NSString *all = PlainOf(d.rootNode);
    PASS(![all containsString: @"junk"], "unknown macro args not injected");
  }
  END_SET("unknown macro ignored")

  START_SET("cross references")
  {
    GSHelpDocument *d = Parse(
        @".TH T 1\n.SH DESCRIPTION\nUse printf(3) and ls(1) tools. See section 5 docs.\n");
    GSHelpParagraph *p = Paragraphs(d)[0];
    NSMutableArray<GSHelpLink *> *links = [NSMutableArray new];
    for (GSHelpNode *n in p.children) {
      if ([n isKindOfClass: [GSHelpLink class]]) {
        [links addObject: (GSHelpLink *)n];
      }
    }
    PASS(links.count == 2, "exactly two word(section) refs linked");
    if (links.count == 2) {
      GSHelpLink *l0 = links[0];
      PASS_EQUAL(l0.labelText, @"printf(3)", "ref label keeps written form");
      PASS([l0.target isEqualToString:
          @"help://man/printf/3"], "target help://man/printf/3");
      PASS([links[1].target isEqualToString: @"help://man/ls/1"],
           "target help://man/ls/1");
    }
    NSString *plain = PlainOf(p.children);
    PASS(![plain containsString: @"printf(3)"],
         "linked ref no longer plain text");

    /* request-line form with leading zero-width escape */
    d = Parse(@".TH T 1\n.SH SEE ALSO\n\\& foo(1)\n");
    GSHelpParagraph *p2 = Paragraphs(d)[0];
    NSUInteger nLinks = 0;
    for (GSHelpNode *n in p2.children) {
      if ([n isKindOfClass: [GSHelpLink class]]
          && [((GSHelpLink *)n).target isEqualTo: @"help://man/foo/1"]) {
        nLinks++;
      }
    }
    PASS(nLinks == 1, "\\& foo(1) request line linked");

    /* negative: bare numbers or non-numeric sections stay text */
    d = Parse(@".TH T 1\n.SH DESCRIPTION\nversion 5 and x(y) remain.\n");
    GSHelpParagraph *p3 = Paragraphs(d)[0];
    NSUInteger none = 0;
    for (GSHelpNode *n in p3.children) {
      if ([n isKindOfClass: [GSHelpLink class]]) {
        none++;
      }
    }
    PASS(none == 0, "non man-ref patterns not linked");
  }
  END_SET("cross references")

  START_SET("malformed roff")
  {
    __block GSHelpDocument *d = nil;
    PASS_RUNS(d = Parse(@"@#$%^ garbage\n... random text\n.BROKEN stuff\n"),
              "garbage roff does not raise");
    PASS(d != nil && d.rootNode != nil,
         "garbage still yields a document with a root");
    PASS_RUNS(d = Parse(@".B\n"), "truncated macro does not raise");
    PASS_RUNS(d = Parse(@".TH\nstray\n.IP\n.IP\n"),
              "argument-less .TH and bare .IP do not raise");
  }
  END_SET("malformed roff")

  START_SET("empty file")
  {
    __block GSHelpDocument *d = nil;
    PASS_RUNS(d = Parse(@""), "empty page does not raise");
    PASS(d != nil && d.rootNode != nil, "empty page yields document+root");
    PASS(d.rootNode.children.count == 0, "empty page has no content nodes");
  }
  END_SET("empty file")

  START_SET("missing file errors")
  {
    GSManParser *p = [GSManParser new];
    NSError *err = nil;
    GSHelpDocument *d =
        [p parseURL: [NSURL fileURLWithPath:
            [NSString stringWithFormat: @"/nonexistent/gsman_%d.1",
                (int)getpid()]]
              error: &err];
    PASS(d == nil, "unreadable page returns nil");
    PASS(err != nil, "unreadable page sets error");
  }
  END_SET("missing file errors")

  RemoveFixture();

  [arp release];
  return 0;
}

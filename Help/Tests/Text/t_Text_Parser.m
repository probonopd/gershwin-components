/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_Text_Parser - GSTextParser: paragraph grouping, monospace
 * heuristic, man-reference links, empty/unreadable input, UTF-8.
 * Links Core + Parsers sources as separate objects. */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "GSHelpNode.h"
#import "GSHelpDocument.h"
#import "GSTextParser.h"

static NSString *fixtureDir(void)
{
  return [NSString stringWithFormat: @"/tmp/opencode/gshelp_text_%d", getpid()];
}

static NSURL *writeFixture(NSString *name, NSString *content)
{
  NSString *dir = fixtureDir();
  [[NSFileManager defaultManager] createDirectoryAtPath: dir
      withIntermediateDirectories: YES attributes: nil error: NULL];
  NSString *path = [dir stringByAppendingPathComponent: name];
  [content writeToFile: path atomically: YES
              encoding: NSUTF8StringEncoding error: NULL];
  return [NSURL fileURLWithPath: path];
}

static void cleanupFixtures(void)
{
  [[NSFileManager defaultManager] removeItemAtPath: fixtureDir() error: NULL];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("paragraph grouping")
  {
    NSURL *url = writeFixture(@"prose.txt",
      @"First paragraph line one\ncontinues here.\n"
      @"\n"
      @"Second paragraph.\n"
      @"\n"
      @"   \n"
      @"Third after whitespace-only line.\n");

    GSTextParser *parser = [GSTextParser new];
    GSHelpDocument *doc = [parser parseURL: url error: NULL];
    PASS(doc != nil, "document parsed");
    PASS(doc.rootNode != nil, "root node exists");
    PASS(doc.rootNode.children.count == 3,
         "three blank-line-separated paragraphs");
    if (doc.rootNode.children.count == 3)
      {
        PASS([doc.rootNode.children[0] isKindOfClass: [GSHelpParagraph class]],
             "first block is a paragraph");
        GSHelpParagraph *p0 = doc.rootNode.children[0];
        NSString *t0 = p0.children.count == 1
            ? ((GSHelpText *) p0.children[0]).string : nil;
        PASS_EQUAL(t0, @"First paragraph line one\ncontinues here.\n",
                   "first paragraph preserves internal newline");
        GSHelpParagraph *p2 = doc.rootNode.children[2];
        PASS_EQUAL(((GSHelpText *) p2.children.firstObject).string,
                   @"Third after whitespace-only line.\n",
                   "whitespace-only line acts as separator");
      }
  }
  END_SET("paragraph grouping")

  START_SET("monospaced detection positive")
  {
    NSURL *url = writeFixture(@"terminal.txt",
      @"$ ls -l\n"
      @"  total 4\n"
      @"  -rw-r--r-- 1 user group 42 notes.txt\n"
      @"$ cat notes.txt\n"
      @"  remember the milk\n");

    GSTextParser *parser = [GSTextParser new];
    GSHelpDocument *doc = [parser parseURL: url error: NULL];
    PASS(doc != nil && doc.rootNode != nil, "document parsed");
    PASS(doc.rootNode.children.count == 1,
         "one top-level node for terminal content");
    if (doc.rootNode.children.count == 1)
      {
        PASS([doc.rootNode.children[0] isKindOfClass: [GSHelpCodeBlock class]],
             "terminal content becomes a code block");
        GSHelpCodeBlock *cb = doc.rootNode.children[0];
        PASS([cb.code rangeOfString: @"\n"].location != NSNotFound,
             "line endings preserved inside code block");
        PASS([cb.code hasSuffix: @"remember the milk\n"],
             "code block ends exactly like the source");
      }
  }
  END_SET("monospaced detection positive")

  START_SET("monospaced detection negative")
  {
    /* Only one of five non-blank lines is indented: prose. */
    NSURL *url = writeFixture(@"plain_prose.txt",
      @"This is a plain sentence.\n"
      @"Another sentence follows right here.\n"
      @"The third line wraps around normally.\n"
      @"  One single indented line among prose.\n"
      @"Final prose line comes last.\n");

    GSTextParser *parser = [GSTextParser new];
    GSHelpDocument *doc = [parser parseURL: url error: NULL];
    PASS(doc != nil, "document parsed");
    BOOL hasCode = NO;
    for (GSHelpNode *child in doc.rootNode.children)
      if ([child isKindOfClass: [GSHelpCodeBlock class]])
        hasCode = YES;
    PASS(hasCode == NO, "mostly-prose content stays paragraphs");
    PASS(doc.rootNode.children.count == 1,
         "no blank lines means a single paragraph");
  }
  END_SET("monospaced detection negative")

  START_SET("CRLF preserved in code block")
  {
    NSURL *url = writeFixture(@"crlf.txt",
      @"  indented alpha\r\n  indented beta\r\n  indented gamma\r\n");

    GSTextParser *parser = [GSTextParser new];
    GSHelpDocument *doc = [parser parseURL: url error: NULL];
    PASS(doc != nil && doc.rootNode.children.count == 1,
         "one node for CRLF terminal dump");
    if (doc.rootNode.children.count == 1)
      {
        GSHelpCodeBlock *cb = doc.rootNode.children[0];
        NSUInteger crlf = [[cb code] componentsSeparatedByString:
                            @"\r\n"].count - 1;
        PASS(crlf == 3, "all three CRLF endings survive verbatim");
      }
  }
  END_SET("CRLF preserved in code block")

  START_SET("man reference links")
  {
    NSURL *url = writeFixture(@"manrefs.txt",
      @"See the tools below:\n"
      @"ls(1)\n"
      @"printf(3) is nice\n"
      @"grep(1)\n");

    GSTextParser *parser = [GSTextParser new];
    GSHelpDocument *doc = [parser parseURL: url error: NULL];
    PASS(doc != nil && doc.rootNode.children.count == 1,
         "single block parsed");
    if (doc.rootNode.children.count == 1)
      {
        GSHelpParagraph *para = doc.rootNode.children[0];
        NSMutableArray<GSHelpLink *> *links = [NSMutableArray new];
        for (GSHelpNode *child in para.children)
          if ([child isKindOfClass: [GSHelpLink class]])
            [links addObject: (GSHelpLink *) child];
        PASS(links.count == 2, "two end-of-line/standalone man refs linked");
        if (links.count == 2)
          {
            PASS_EQUAL(links[0].target, @"help://man/ls/1", "ls(1) target");
            PASS_EQUAL(links[0].labelText, @"ls(1)", "ls(1) label");
            PASS_EQUAL(links[1].target, @"help://man/grep/1",
                       "grep(1) standalone target");
          }
        BOOL midSentenceLinked = NO;
        for (GSHelpLink *link in links)
          if ([link.target isEqualToString: @"help://man/printf/3"])
            midSentenceLinked = YES;
        PASS(midSentenceLinked == NO,
             "mid-sentence reference stays plain text");
      }
  }
  END_SET("man reference links")

  START_SET("man reference section letters")
  {
    NSURL *url = writeFixture(@"mansec.txt", @"tgetent(3x)\n");

    GSTextParser *parser = [GSTextParser new];
    GSHelpDocument *doc = [parser parseURL: url error: NULL];
    GSHelpLink *link = nil;
    if (doc.rootNode.children.count == 1
        && doc.rootNode.children[0].children.count == 1)
      link = doc.rootNode.children[0].children[0];
    PASS([link isKindOfClass: [GSHelpLink class]],
         "standalone token becomes a link");
    PASS_EQUAL(link.target, @"help://man/tgetent/3x",
               "alphanumeric man section kept in target");
  }
  END_SET("man reference section letters")

  START_SET("empty and unreadable input")
  {
    NSURL *empty = writeFixture(@"empty.txt", @"");

    GSTextParser *parser = [GSTextParser new];
    GSHelpDocument *doc = [parser parseURL: empty error: NULL];
    PASS(doc != nil, "empty file yields a document");
    PASS_EQUAL(doc.sourceType, @"text", "sourceType is text");
    PASS(doc.rootNode != nil && doc.rootNode.children.count == 0,
         "empty file yields an empty root");
    PASS_EQUAL(doc.title, @"empty.txt", "title is the filename");

    NSError *err = nil;
    __block GSHelpDocument *missingDoc = nil;
    NSURL *missing = [NSURL URLWithString:
        [NSString stringWithFormat: @"file:///tmp/opencode/gshelp_no_%d.txt",
                                    getpid()]];
    PASS_RUNS(missingDoc = [parser parseURL: missing error: &err],
              "unreadable file does not raise");
    PASS(missingDoc == nil, "unreadable file yields nil document");
    PASS(err != nil, "unreadable file reports an error");
  }
  END_SET("empty and unreadable input")

  START_SET("canParseURL is the fallback")
  {
    GSTextParser *parser = [GSTextParser new];
    PASS([parser canParseURL:
            [NSURL URLWithString: @"file:///tmp/x.anything"]],
         "accepts file URLs");
    PASS([parser canParseURL:
            [NSURL URLWithString: @"help://man/ls/1"]],
         "accepts help URLs");
  }
  END_SET("canParseURL is the fallback")

  START_SET("UTF-8 content")
  {
    NSURL *url = writeFixture(@"utf8.txt",
      @"Gr\00fc\00dfe aus M\00fcnchen\n"
      @"\n"
      @"Zusammenfassung: \00c4nderungen \00fcbernehmen\n");

    GSTextParser *parser = [GSTextParser new];
    GSHelpDocument *doc = [parser parseURL: url error: NULL];
    PASS(doc != nil && doc.rootNode.children.count == 2,
         "UTF-8 document parsed into two paragraphs");
    if (doc.rootNode.children.count == 2)
      {
        GSHelpParagraph *p0 = doc.rootNode.children[0];
        PASS_EQUAL(((GSHelpText *) p0.children.firstObject).string,
                   @"Gr\00fc\00dfe aus M\00fcnchen\n",
                   "non-ASCII text survives the round trip");
      }
  }
  END_SET("UTF-8 content")

  cleanupFixtures();
  [arp release];
  return 0;
}

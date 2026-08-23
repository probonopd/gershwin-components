/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_GSdoc_Parser - GSdoc XML into the shared document model:
 * structure mapping (chapter/section/subsect), inline styles, lists,
 * example blocks, API declaration reconstruction, links, and
 * malformed-input handling. */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "GSGSDocParser.h"
#import "GSHelpDocument.h"
#import "GSHelpNode.h"

static NSURL *WriteGSdoc(NSString *xml)
{
    NSString *dir =
        [NSString stringWithFormat: @"/tmp/opencode/gsdoc-%d", (int)getpid()];
    [[NSFileManager defaultManager] removeFileAtPath: dir handler: nil];
    [[NSFileManager defaultManager]
        createDirectoryAtPath: dir withIntermediateDirectories: YES
                   attributes: nil error: NULL];
    NSString *path = [dir stringByAppendingPathComponent: @"t.gsdoc"];
    [xml writeToFile: path atomically: YES encoding: NSUTF8StringEncoding
              error: NULL];
    return [NSURL fileURLWithPath: path];
}

/* First node of a kind anywhere in the tree. */
static GSHelpNode *FirstOfKind(NSArray *nodes, Class klass)
{
    for (GSHelpNode *node in nodes)
      {
        if ([node isKindOfClass: klass])
          {
            return node;
          }
        GSHelpNode *deep =
            FirstOfKind([node children], klass);
        if (deep != nil)
          {
            return deep;
          }
      }
    return nil;
}

static NSArray *AllOfKind(NSArray *nodes, Class klass)
{
    NSMutableArray *found = [NSMutableArray new];
    for (GSHelpNode *node in nodes)
      {
        if ([node isKindOfClass: klass])
          {
            [found addObject: node];
          }
        [found addObjectsFromArray: AllOfKind([node children], klass)];
      }
    return found;
}

int main(void)
{
    NSAutoreleasePool *arp = [NSAutoreleasePool new];
    (void)arp;

    GSGSDocParser *parser = [GSGSDocParser new];

    START_SET("url acceptance")
    {
        PASS([parser canParseURL:
                  [NSURL fileURLWithPath: @"/x/NSString.gsdoc"]],
             "accepts .gsdoc");
        PASS(![parser canParseURL:
                       [NSURL fileURLWithPath: @"/x/NSString.md"]],
             "rejects .md");
    }
    END_SET("url acceptance")

    START_SET("head metadata and title")
    {
        NSURL *url = WriteGSdoc(
            @"<?xml version=\"1.0\"?>\n"
             "<gsdoc base=\"X\"><head><title>Sample Docs</title>"
             "<author name=\"Jane Doe\"/>"
             "<version>1.2</version></head>"
             "<body><chapter><heading>Intro</heading>"
             "<p>Hello.</p></chapter></body></gsdoc>");
        NSError *error = nil;
        GSHelpDocument *document =
            [parser parseURL: url error: &error];

        PASS(document != nil, "parses without error");
        PASS([[document title] isEqualToString: @"Sample Docs"],
             "title from head/title");
        PASS([[[document metadata] objectForKey: @"author"]
                  isEqualToString: @"Jane Doe"],
             "author name into metadata");
        PASS([[[document metadata] objectForKey: @"version"]
                  isEqualToString: @"1.2"],
             "version into metadata");

        NSArray *headings =
            AllOfKind([[document rootNode] children],
                      [GSHelpHeading class]);
        PASS([headings count] == 1, "one heading");
        GSHelpHeading *first = headings[0];
        PASS([first level] == 1, "chapter maps to level 1 heading");
        PASS([[first text] isEqualToString: @"Intro"],
             "heading text from <heading>");
    }
    END_SET("head metadata and title")

    START_SET("structure levels")
    {
        NSURL *url = WriteGSdoc(
            @"<gsdoc><head><title>T</title></head><body>"
             "<chapter><heading>A</heading><p>a</p>"
             "<section><heading>B</heading><p>b</p>"
             "<subsect><heading>C</heading><p>c</p></subsect>"
             "</section></chapter></body></gsdoc>");
        GSHelpDocument *document = [parser parseURL: url error: nil];
        NSArray *headings =
            AllOfKind([[document rootNode] children],
                      [GSHelpHeading class]);
        PASS([headings count] == 3, "three headings");
        PASS([(GSHelpHeading *)headings[0] level] == 1
                 && [(GSHelpHeading *)headings[1] level] == 2
                 && [(GSHelpHeading *)headings[2] level] == 3,
             "chapter/section/subsect nest to levels 1/2/3");
        PASS([[document tableOfContents] count] == 3,
             "TOC derived from the headings");
    }
    END_SET("structure levels")

    START_SET("paragraphs and inline runs")
    {
        NSURL *url = WriteGSdoc(
            @"<gsdoc><head><title>T</title></head><body><p>"
             "plain <code>YES</code> and <em>emph</em> plus "
             "<strong>bold</strong> done"
             "</p></body></gsdoc>");
        GSHelpDocument *document = [parser parseURL: url error: nil];
        GSHelpParagraph *par = (GSHelpParagraph *)
            FirstOfKind([[document rootNode] children],
                        [GSHelpParagraph class]);
        PASS(par != nil, "paragraph exists");
        BOOL sawPlain = NO, sawCode = NO, sawItalic = NO, sawBold = NO;
        for (GSHelpText *run in [par children])
          {
            if ([run style] == GSHelpTextStyleCode
                    && [[run string] isEqualToString: @"YES"])
              {
                sawCode = YES;
              }
            if ([run style] == GSHelpTextStyleItalic
                    && [[run string] isEqualToString: @"emph"])
              {
                sawItalic = YES;
              }
            if ([run style] == GSHelpTextStyleBold
                    && [[run string] isEqualToString: @"bold"])
              {
                sawBold = YES;
              }
            if ([run style] == GSHelpTextStylePlain
                    && [[run string] containsString: @"plain"])
              {
                sawPlain = YES;
              }
          }
        PASS(sawPlain, "plain text run kept");
        PASS(sawCode, "<code> becomes code run");
        PASS(sawItalic, "<em> becomes italic run");
        PASS(sawBold, "<strong> becomes bold run");
    }
    END_SET("paragraphs and inline runs")

    START_SET("lists")
    {
        NSURL *url = WriteGSdoc(
            @"<gsdoc><head><title>T</title></head><body>"
             "<list><item>one</item><item>two"
             "<list><item>nested</item></list></item></list>"
             "</body></gsdoc>");
        GSHelpDocument *document = [parser parseURL: url error: nil];
        GSHelpList *list = (GSHelpList *)
            FirstOfKind([[document rootNode] children],
                        [GSHelpList class]);
        PASS(list != nil, "list exists");
        PASS(![list isOrdered], "list is unordered by default");
        PASS([[list children] count] == 2, "two items");
        GSHelpListItem *second = [list children][1];
        GSHelpList *nested = (GSHelpList *)
            FirstOfKind([second children], [GSHelpList class]);
        PASS(nested != nil && [[nested children] count] == 1,
             "nested list inside second item");
    }
    END_SET("lists")

    START_SET("example blocks")
    {
        NSURL *url = WriteGSdoc(
            @"<gsdoc><head><title>T</title></head><body>"
             "<example>STContext *ctx;\n[ctx doIt];</example>"
             "</body></gsdoc>");
        GSHelpDocument *document = [parser parseURL: url error: nil];
        GSHelpCodeBlock *code = (GSHelpCodeBlock *)
            FirstOfKind([[document rootNode] children],
                        [GSHelpCodeBlock class]);
        PASS(code != nil, "example becomes code block");
        PASS([[code code] isEqualToString:
                  @"STContext *ctx;\n[ctx doIt];"],
             "example text preserved verbatim");
    }
    END_SET("example blocks")

    START_SET("method declarations")
    {
        NSURL *url = WriteGSdoc(
            @"<gsdoc><head><title>T</title></head><body>"
             "<class name=\"STContext\" super=\"NSObject\">"
             "<declared>StepTalk/STContext.h</declared>"
             "<desc><p>A context.</p></desc>"
             "<ivariable type=\"BOOL\" name=\"flag\"/>"
             "<method type=\"BOOL\"><sel>createsUnknownObjects</sel>"
             "<desc>Returns <code>YES</code>.</desc></method>"
             "<method type=\"void\"><sel>addObjects:</sel>"
             "<arg type=\"NSDictionary*\">dict</arg>"
             "<desc>Adds.</desc></method>"
             "<method type=\"id\" factory=\"yes\"><sel>new</sel>"
             "<desc>Makes one.</desc></method>"
             "</class></body></gsdoc>");
        GSHelpDocument *document = [parser parseURL: url error: nil];
        NSArray *blocks =
            AllOfKind([[document rootNode] children],
                      [GSHelpCodeBlock class]);
        PASS([blocks count] >= 4, "class, ivar and methods rendered");

        NSMutableString *joined = [NSMutableString new];
        for (GSHelpCodeBlock *block in blocks)
          {
            [joined appendFormat: @"\n%@", [block code]];
          }
        PASS([joined containsString:
                   @"@interface STContext : NSObject"],
             "class header reconstructed");
        PASS([joined containsString: @"StepTalk/STContext.h"],
             "declared header mentioned");
        PASS([joined containsString: @"BOOL flag;"],
             "ivariable rendered as declaration line");
        PASS([joined containsString: @"- (BOOL)createsUnknownObjects"],
             "instance method signature");
        PASS([joined containsString:
                   @"- (void)addObjects:(NSDictionary*)dict"],
             "method with argument reconstruction");
        PASS([joined containsString: @"+ (id)new"],
             "factory method gets + prefix");

        /* Method descriptions become prose after their declarations. */
        NSArray *paragraphs =
            AllOfKind([[document rootNode] children],
                      [GSHelpParagraph class]);
        BOOL sawDesc = NO;
        for (GSHelpParagraph *p in paragraphs)
          {
            for (GSHelpText *run in [p children])
              {
                if ([[run string] containsString: @"Returns"])
                  {
                    sawDesc = YES;
                  }
              }
          }
        PASS(sawDesc, "method desc prose kept");
    }
    END_SET("method declarations")

    START_SET("function declarations")
    {
        NSURL *url = WriteGSdoc(
            @"<gsdoc><head><title>T</title></head><body>"
             "<function type=\"NSString*\" name=\"STFindResource\">"
             "<arg type=\"NSString*\">name</arg>"
             "<arg type=\"NSString*\">dir</arg>"
             "<desc>Finds.</desc></function>"
             "</body></gsdoc>");
        GSHelpDocument *document = [parser parseURL: url error: nil];
        GSHelpCodeBlock *code = (GSHelpCodeBlock *)
            FirstOfKind([[document rootNode] children],
                        [GSHelpCodeBlock class]);
        PASS(code != nil, "function declaration block exists");
        PASS([[code code] containsString:
                   @"NSString* STFindResource(NSString* name, "
                   @"NSString* dir)"],
             "C function signature reconstructed");
    }
    END_SET("function declarations")

    START_SET("links")
    {
        NSURL *url = WriteGSdoc(
            @"<gsdoc><head><title>T</title></head><body><p>"
             "see <url url=\"http://gnustep.org\">GNUstep</url> and "
             "<ref base=\"StepTalk\" class=\"STContext\">the context"
             "</ref>"
             "</p></body></gsdoc>");
        GSHelpDocument *document = [parser parseURL: url error: nil];
        GSHelpLink *link = (GSHelpLink *)
            FirstOfKind([[document rootNode] children],
                        [GSHelpLink class]);
        PASS(link != nil, "link node exists");
        PASS([[link target] isEqualToString: @"http://gnustep.org"],
             "external url target kept");
        PASS([[[link labelRuns][0] string]
                  isEqualToString: @"GNUstep"],
             "url label text kept");
    }
    END_SET("links")

    START_SET("malformed input")
    {
        NSURL *url = WriteGSdoc(
            @"<gsdoc><head><title>Broken</title></head><body><p>oops");
        NSError *error = nil;
        GSHelpDocument *document =
            [parser parseURL: url error: &error];
        PASS(document == nil, "malformed XML yields no document");
        PASS(error != nil, "error reported");
        PASS_RUNS([parser parseURL:
                            [NSURL fileURLWithPath: @"/nonexistent.gsdoc"]
                            error: NULL],
                  "missing file does not raise");
    }
    END_SET("malformed input")

    [arp release];
    return 0;
}

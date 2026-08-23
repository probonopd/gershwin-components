/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Structural mapping: headings, lists, example blocks kept verbatim,
 * url/ref links and autogsdoc API entities. */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "GSGSdocParser.h"
#import "GSHelpDocument.h"
#import "GSHelpNode.h"

static GSHelpDocument *Parse(NSString *xml)
{
    NSString *tmp = @"/tmp/opencode/gsdoc_struct.gsdoc";
    [[NSFileManager defaultManager] createDirectoryAtPath:
        @"/tmp/opencode" withIntermediateDirectories: YES
        attributes: nil error: NULL];
    [xml writeToFile: tmp atomically: YES encoding:
        NSUTF8StringEncoding error: NULL];
    return [[GSGSdocParser new] parseURL:
        [NSURL fileURLWithPath: tmp] error: NULL];
}

int main(int argc, char **argv)
{
    (void)argc; (void)argv;

    /* Headings + list + example verbatim. */
    GSHelpDocument *doc = Parse(
        @"<gsdoc><body>"
        @"<chapter><heading>Chapter One</heading>"
        @"<list><item>alpha</item><item>beta</item></list>"
        @"<example>  keep   this\n\t  spacing </example>"
        @"<p>see <url url=\"https://example.org\">the site</url></p>"
        @"</chapter></body></gsdoc>");
    PASS(doc != nil, "structure fixture parses");

    __block NSUInteger headings = 0, lists = 0, codeBlocks = 0;
    __block BOOL exampleVerbatim = NO, hasLink = NO;
    for (GSHelpNode *n in doc.rootNode.children)
      {
        if ([n isKindOfClass: [GSHelpHeading class]])
          {
            headings++;
            PASS_EQUAL(((GSHelpHeading *)n).text, @"Chapter One",
                       "chapter heading text normalized");
          }
        else if ([n isKindOfClass: [GSHelpList class]]) lists++;
        else if ([n isKindOfClass: [GSHelpCodeBlock class]])
          {
            codeBlocks++;
            exampleVerbatim = [((GSHelpCodeBlock *)n).code
                containsString: @"  keep   this"];
          }
        else if ([n isKindOfClass: [GSHelpParagraph class]])
          {
            for (GSHelpNode *c in n.children)
              if ([c isKindOfClass: [GSHelpLink class]]) hasLink = YES;
          }
      }
    PASS(headings == 1, "one heading emitted");
    PASS(lists == 1, "list mapped");
    PASS(codeBlocks == 1 && exampleVerbatim,
         "<example> kept verbatim (whitespace intact)");
    PASS(hasLink, "<url> became a link inside a paragraph");

    /* autogsdoc API entity. */
    GSHelpDocument *api = Parse(
        @"<gsdoc><body><class name=\"NSObject\" super=\"\">"
        @"<declared>Foundation/NSObject.h</declared>"
        @"<desc><p>The root class.</p></desc>"
        @"</class></body></gsdoc>");
    PASS(api != nil, "API fixture parses");
    __block BOOL sawSignature = NO, sawDeclared = NO;
    for (GSHelpNode *n in api.rootNode.children)
      {
        if ([n isKindOfClass: [GSHelpHeading class]] &&
            [((GSHelpHeading *)n).text containsString: @"NSObject"])
          sawSignature = YES;
        if ([n isKindOfClass: [GSHelpParagraph class]])
          {
            for (GSHelpNode *c in ((GSHelpParagraph *)n).children)
              if ([c isKindOfClass: [GSHelpText class]] &&
                  [((GSHelpText *)c).string containsString:
                      @"Declared in Foundation/NSObject.h"])
                sawDeclared = YES;
          }
      }
    PASS(sawSignature, "class signature heading present");
    PASS(sawDeclared, "declared-in line present");

    return 0;
}

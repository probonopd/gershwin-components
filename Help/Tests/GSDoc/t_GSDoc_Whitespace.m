/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* The whole point of the gsdoc parser: source-layout whitespace (tabs,
 * indentation, line wraps inside <p> text) must collapse to single
 * spaces instead of leaking into rendered prose. */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "GSGSdocParser.h"
#import "GSHelpDocument.h"
#import "GSHelpNode.h"

static NSString * const Fixture =
@"<?xml version=\"1.0\"?>\n"
@"<gsdoc>\n"
@"  <head><title>GNUstep.conf</title></head>\n"
@"  <body>\n"
@"    <p>\n"
@"\tThis file is the master configuration file for GNUstep.\n"
@"\t    It can be used to set the base location of all the standard\n"
@"\t    paths that GNUstep programs use or know about.\n"
@"    </p>\n"
@"    <p>Second paragraph with   collapsed      runs.</p>\n"
@"  </body>\n"
@"</gsdoc>\n";

static NSString *Flatten(GSHelpSection *root)
{
    NSMutableString *out = [NSMutableString new];
    for (GSHelpNode *node in root.children)
      {
        if ([node isKindOfClass: [GSHelpParagraph class]])
          {
            for (GSHelpText *run in node.children)
              [out appendString: run.string];
            [out appendString: @"\u00b6"];
          }
      }
    return out;
}

int main(int argc, char **argv)
{
    (void)argc; (void)argv;

    GSGSdocParser *parser = [GSGSdocParser new];

    /* Feed the fixture through a temporary file so parseURL's normal
     * read path is exercised too. */
    NSString *tmp = @"/tmp/opencode/gsdoc_fixture.gsdoc";
    [[NSFileManager defaultManager] createDirectoryAtPath:
        @"/tmp/opencode" withIntermediateDirectories: YES
        attributes: nil error: NULL];
    [Fixture writeToFile: tmp atomically: YES encoding:
        NSUTF8StringEncoding error: NULL];

    NSError *error = nil;
    GSHelpDocument *doc = [parser parseURL:
        [NSURL fileURLWithPath: tmp] error: &error];
    PASS(doc != nil, "gsdoc fixture parses");
    PASS_EQUAL(doc.title, @"GNUstep.conf", "head/title becomes the title");

    NSString *flat = Flatten(doc.rootNode);
    PASS([flat rangeOfString: @"configuration file for GNUstep. It can be used"]
           .location != NSNotFound,
         "tab+space run collapses to a single space");
    PASS([flat containsString: @"with collapsed runs."],
         "multiple spaces collapse");
    PASS([flat containsString: @"Second paragraph"],
         "second paragraph present");
    PASS(![flat containsString: @"\t"], "no tab survives anywhere");
    return 0;
}

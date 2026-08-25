/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* Fast non-GUI conversion check: parse documents with the same
 * registry + renderer the app uses, then print the rendered
 * NSAttributedString as annotated plain text plus model-level defect
 * flags. One terminal line per rendered output line, so whole corpora
 * can be screened with grep/diff instead of driving the GUI. */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#import "GSHelpParserRegistry.h"
#import "GSHelpDocument.h"
#import "GSHelpNode.h"
#import "GSHelpRenderer.h"

#import "GSGSdocParser.h"
#import "GSTextParser.h"
#import "GSHelpFormatDetector.h"

#if defined(__has_include)
#  if __has_include("GSMarkdownParser.h")
#    import "GSMarkdownParser.h"
#    define HAVE_MARKDOWN 1
#  endif
#  if __has_include("GSManParser.h")
#    import "GSManParser.h"
#    define HAVE_MAN 1
#  endif
#endif

static BOOL isWordChar(unichar c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_' || c == '-';
}

/* Per-block check: consecutive text runs inside one block must not
 * glue two words together at the run boundary (man pages hard-wrap
 * their source lines, so a lost joiner space is a common defect). */
static void checkGluedRuns(GSHelpNode *node, NSMutableArray *defects)
{
    GSHelpText *prev = nil;
    for (GSHelpNode *kid in [node children])
      {
        if ([kid isKindOfClass:[GSHelpText class]])
          {
            GSHelpText *t = (GSHelpText *)kid;
            if (prev != nil && [prev string].length > 0
                && [t string].length > 0)
              {
                unichar a = [[prev string]
                    characterAtIndex: [prev string].length - 1];
                unichar b = [[t string] characterAtIndex: 0];
                if (isWordChar(a) && isWordChar(b))
                  {
                    NSString *tail = [prev string];
                    if (tail.length > 24)
                      {
                        tail = [tail substringFromIndex: tail.length - 24];
                      }
                    [defects addObject: [NSString stringWithFormat:
                        @"GLUED: ...%@%@", tail, [t string]]];
                  }
              }
            prev = t;
          }
        else
          {
            prev = nil;
          }
      }
}

/* Walk every block node exactly once collecting defects. */
static void walkDefects(GSHelpNode *node, NSMutableArray *defects)
{
    checkGluedRuns(node, defects);
    for (GSHelpNode *kid in [node children])
      {
        walkDefects(kid, defects);
      }
}

static NSString *fontFlags(NSAttributedString *s, NSUInteger i)
{
    NSFont *f = [s attribute: NSFontAttributeName atIndex: i
              effectiveRange: NULL];
    NSMutableString *out = [NSMutableString new];
    if (f == nil)
      {
        return @"nofont";
      }
    [out appendFormat: @"%.0f", [f pointSize]];
    NSFontManager *fm = [NSFontManager sharedFontManager];
    NSFontTraitMask traits = [fm traitsOfFont: f];
    if (traits & NSBoldFontMask)
      {
        [out appendString: @"B"];
      }
    if (traits & NSItalicFontMask)
      {
        [out appendString: @"I"];
      }
    /* Mono detection via the fixed-pitch user font of the same size. */
    NSFont *mono = [NSFont userFixedPitchFontOfSize: [f pointSize]];
    if (mono != nil && [[mono familyName] isEqual: [f familyName]])
      {
        [out appendString: @"M"];
      }
    return out;
}

static void dumpRendered(NSAttributedString *as)
{
    NSUInteger len = [as length];
    NSUInteger i = 0;
    while (i < len)
      {
        NSRange line = [as.string lineRangeForRange: NSMakeRange(i, 0)];
        NSString *text = [as.string substringWithRange:
            NSMakeRange(line.location,
                        line.length > 0 ? line.length - 1 : 0)];
        NSDictionary *attrs = [as attributesAtIndex: line.location
                                     effectiveRange: NULL];
        NSParagraphStyle *ps = attrs[NSParagraphStyleAttributeName];
        const char *bg = (attrs[NSBackgroundColorAttributeName] != nil)
            ? " BG" : "";
        const char *link = (attrs[NSLinkAttributeName] != nil)
            ? " LINK" : "";
        if (ps != nil)
          {
            printf("  [i%.0f h%.0f s%.0f/a%.0f f%s%s%s] %s\n",
                   ps.headIndent, ps.firstLineHeadIndent,
                   ps.paragraphSpacingBefore, ps.paragraphSpacing,
                   [fontFlags(as, line.location) UTF8String],
                   bg, link, [text UTF8String]);
          }
        else
          {
            printf("  [f%s%s%s] %s\n",
                   [fontFlags(as, line.location) UTF8String],
                   bg, link, [text UTF8String]);
          }
        i = NSMaxRange(line);
      }
}

static void dumpDocument(NSString *path)
{
    NSURL *url = [NSURL fileURLWithPath: path];
    GSHelpParserRegistry *registry = [GSHelpParserRegistry new];
    [registry registerParser: [GSGSdocParser new]];
#ifdef HAVE_MARKDOWN
    [registry registerParser: [GSMarkdownParser new]];
#endif
#ifdef HAVE_MAN
    [registry registerParser: [GSManParser new]];
#endif
    [registry registerParser: [GSTextParser new]];

    id <GSHelpParser> parser = [registry parserForURL: url];
    if (parser == nil)
      {
        printf("== %s: NO PARSER\n", [path UTF8String]);
        return;
      }

    NSError *error = nil;
    GSHelpDocument *doc = [parser parseURL: url error: &error];
    if (doc == nil)
      {
        printf("== %s: PARSE FAILED: %s\n", [path UTF8String],
               [error.localizedDescription UTF8String]);
        return;
      }

    printf("== %s\n", [path UTF8String]);
    printf("   type=%s title=[%s] toc=%lu\n",
           [doc.sourceType UTF8String], [doc.title UTF8String],
           (unsigned long)[doc.tableOfContents count]);

    NSMutableArray *defects = [NSMutableArray new];
    walkDefects([doc rootNode], defects);
    for (NSString *d in defects)
      {
        printf("   DEFECT %s\n", [d UTF8String]);
      }

    GSHelpRenderer *renderer = [GSHelpRenderer new];
    NSAttributedString *as = [renderer renderedStringForDocument: doc];
    dumpRendered(as);
    printf("\n");
}

int main(int argc, char **argv)
{
    /* Font metrics need the backend; creating the app object is enough
     * (no windows, no run loop) so this stays scriptable headless. */
    [NSApplication sharedApplication];
    if (argc < 2)
      {
        printf("usage: renderdump <file> [file ...]\n");
        return 2;
      }
    for (int i = 1; i < argc; i++)
      {
        @autoreleasepool
          {
            @try
              {
                dumpDocument([NSString stringWithUTF8String: argv[i]]);
              }
            @catch (NSException *e)
              {
                printf("== %s: EXCEPTION %s: %s\n", argv[i],
                       [e.name UTF8String], [e.reason UTF8String]);
              }
          }
      }
    return 0;
}

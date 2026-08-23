/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSGSdocParser.h"

#import "GSHelpParser.h"
#import "GSHelpNode.h"
#import "GSHelpDocument.h"
#import "GSHelpFormatDetector.h"

#import <math.h>

/* Error domain for gsdoc parse failures. */
static NSString * const GSGSdocErrorDomain = @"GSGSdocErrorDomain";

/* Whitespace runs in gsdoc prose are artifacts of the source layout:
 * collapse every run of spaces/tabs/newlines to one space.  Applied to
 * all mixed-content text; <example> content bypasses this and is kept
 * verbatim. */
static NSString *NormalizeWhitespace(NSString *text)
{
    if (text.length == 0)
        return text;
    /* Lazy init behind an uncontended lock; dispatch_once is banned by
     * project policy. */
    static NSRegularExpression *regex = nil;
    @synchronized([GSGSdocParser class])
      {
        if (regex == nil)
          regex = [NSRegularExpression
            regularExpressionWithPattern: @"[ \\t\\r\\n]+"
                                 options: 0
                                   error: NULL];
      }
    return [regex stringByReplacingMatchesInString: text
                                           options: 0
                                             range: NSMakeRange(0, text.length)
                                      withTemplate: @" "];
}

/* Trimmed variant for element boundaries. */
static NSString *NormalizedTrim(NSString *text)
{
    return [NormalizeWhitespace(text)
        stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
}

@interface GSGSdocParser ()
@end

@implementation GSGSdocParser

- (BOOL)canParseURL:(NSURL *)url
{
    if (url == nil || !url.isFileURL)
        return NO;
    NSString *extension = url.pathExtension;
    return extension != nil &&
        [extension caseInsensitiveCompare: @"gsdoc"] == NSOrderedSame;
}

- (nullable GSHelpDocument *)parseURL:(NSURL *)url
                                error:(NSError **)error
{
    if (url == nil || !url.isFileURL)
        {
            if (error != nil)
                *error = [NSError errorWithDomain: GSGSdocErrorDomain
                                             code: 1
                                         userInfo: @{
                    NSLocalizedDescriptionKey :
                        NSLocalizedString(@"No file was given.", nil)}];
            return nil;
        }

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfFile: url.path
                                          options: 0
                                            error: &readError];
    if (data == nil)
        {
            if (error != nil)
                *error = readError;
            return nil;
        }

    NSError *xmlError = nil;
    /* Options 0: gsdoc documents are well-formed XML in practice, and
     * validation against the public DTD would require network access we
     * must not depend on. */
    NSXMLDocument *xml = [[NSXMLDocument alloc]
        initWithData: data
             options: 0
               error: &xmlError];
    NSXMLElement *root = xml.rootElement;
    BOOL isGSDoc = xml != nil && root != nil &&
        [root.name caseInsensitiveCompare: @"gsdoc"] == NSOrderedSame;
    if (!isGSDoc)
        {
            if (error != nil)
                *error = xmlError ?: [NSError errorWithDomain:
                                                GSGSdocErrorDomain
                                                           code: 2
                                                       userInfo: @{
                    NSLocalizedDescriptionKey :
                        NSLocalizedString(@"The file is not a gsdoc "
                                          @"document.", nil)}];
            return nil;
        }

    GSHelpDocument *document = [GSHelpDocument new];
    document.sourceURL = url;
    document.sourceType = GSHelpFormatGSDoc;

    GSHelpSection *rootSection = [GSHelpSection new];
    document.rootNode = rootSection;

    /* <head> contributes title and metadata only. */
    NSXMLElement *head = [self childElementNamed: @"head" ofElement: root];
    if (head != nil)
        {
            NSString *title =
                NormalizedTrim([self textOfChildElementNamed: @"title"
                                                   ofElement: head]);
            if (title.length > 0)
                document.title = title;
            NSMutableDictionary *metadata = [NSMutableDictionary new];
            for (NSString *key in @[@"author", @"date", @"version"])
                {
                    NSXMLElement *element =
                        [self childElementNamed: key ofElement: head];
                    NSString *value =
                        element != nil ? NormalizedTrim(element.stringValue) : nil;
                    if (element != nil && value.length > 0)
                        metadata[key] = element.attributes.count > 0
                            ? ([element attributeForName: @"name"].stringValue
                               ?: value)
                            : value;
                }
            document.metadata = metadata;
        }
    if (document.title.length == 0)
        document.title = url.lastPathComponent.stringByDeletingPathExtension;

    /* Body carries the actual content; fall back to walking the whole
     * root for documents without a <body> wrapper. */
    NSXMLElement *body = [self childElementNamed: @"body" ofElement: root];
    NSArray<NSXMLNode *> *topNodes =
        body != nil ? body.children : root.children;
    NSInteger headingDepth = 0;
    [self appendContentOfNodes: topNodes
                       intoNode: rootSection
                  inDocument: document
                 headingDepth: &headingDepth];

    if (rootSection.children.count == 0)
        {
            if (error != nil)
                *error = [NSError errorWithDomain: GSGSdocErrorDomain
                                             code: 3
                                         userInfo: @{
                    NSLocalizedDescriptionKey :
                        NSLocalizedString(@"The gsdoc document has no "
                                          @"renderable content.", nil)}];
            return nil;
        }
    return document;
}

#pragma mark - Structure helpers

- (NSXMLElement *)childElementNamed:(NSString *)name
                          ofElement:(NSXMLElement *)element
{
    if (element == nil)
        return nil;
    for (NSXMLNode *child in element.children)
        {
            if ([child isKindOfClass: [NSXMLElement class]] &&
                [[(NSXMLElement *)child name] caseInsensitiveCompare: name]
                    == NSOrderedSame)
                return (NSXMLElement *)child;
        }
    return nil;
}

- (NSString *)textOfChildElementNamed:(NSString *)name
                            ofElement:(NSXMLElement *)element
{
    NSXMLElement *child = [self childElementNamed: name ofElement: element];
    return child != nil ? child.stringValue : @"";
}

/* Heading level from the structural nesting of chapter/section wrappers,
 * clamped to the model's 1...4 range (SPEC 16). */
- (NSUInteger)levelForHeadingAtDepth:(NSInteger)depth
{
    if (depth < 1) return 1;
    if (depth > 4) return 4;
    return (NSUInteger)depth;
}

#pragma mark - Content walker

/* Appends the inline content of `nodes` into `container`.  Text is
 * accumulated into pending GSHelpParagraph children so that mixed
 * content ("<p>text <em>x</em> more</p>") keeps its flow while every
 * run gets normalized whitespace. */
- (void)appendInlineNodes:(NSArray<NSXMLNode *> *)nodes
                 intoBlock:(GSHelpNode *)block
              currentParagraph:(GSHelpParagraph **)pending
                   style:(GSHelpTextStyle)style
{
    /* When `block` is itself an inline container (paragraph, link), text
     * runs go straight into its children - wrapping them in yet another
     * paragraph produced nested garbage ("does not recognize string").
     * The pending-paragraph accumulator is only for stray mixed-content
     * text arriving at section level. */
    BOOL blockIsInline = [block isKindOfClass: [GSHelpParagraph class]] ||
        [block isKindOfClass: [GSHelpLink class]];

    for (NSXMLNode *node in nodes)
        {
            if ([node isKindOfClass: [NSXMLNode class]] && node.kind == NSXMLTextKind)
                {
                    NSString *piece = NormalizeWhitespace(node.stringValue);
                    if ([piece isEqualToString: @" "] ||
                        piece.length == 0)
                        continue;
                    GSHelpText *run = [GSHelpText new];
                    run.string = piece;
                    run.style = style;
                    if (blockIsInline)
                      {
                        [block appendNode: run];
                      }
                    else
                      {
                        if (*pending == nil)
                          {
                            GSHelpParagraph *paragraph = [GSHelpParagraph new];
                            [block appendNode: paragraph];
                            *pending = paragraph;
                          }
                        [*pending appendNode: run];
                      }
                }
            else if ([node isKindOfClass: [NSXMLElement class]])
                {
                    [self appendInlineElement: (NSXMLElement *)node
                                    intoBlock: block
                             currentParagraph: pending
                                        style: style];
                }
        }
}

/* Inline elements map onto styled runs or links; unknown ones recurse
 * transparently with the inherited style. */
- (void)appendInlineElement:(NSXMLElement *)element
                   intoBlock:(GSHelpNode *)block
            currentParagraph:(GSHelpParagraph **)pending
                      style:(GSHelpTextStyle)style
{
    NSString *name = element.name.lowercaseString;

    GSHelpTextStyle nested = style;
    if ([name isEqualToString: @"em"] || [name isEqualToString: @"i"] ||
        [name isEqualToString: @"italic"])
        nested |= GSHelpTextStyleItalic;
    else if ([name isEqualToString: @"strong"] ||
             [name isEqualToString: @"b"] ||
             [name isEqualToString: @"bold"])
        nested |= GSHelpTextStyleBold;
    else if ([name isEqualToString: @"code"] ||
             [name isEqualToString: @"file"] ||
             [name isEqualToString: @"var"] ||
             [name isEqualToString: @"const"])
        nested |= GSHelpTextStyleCode;

    if (nested != style)
        {
            [self appendInlineNodes: element.children
                           intoBlock: block
                    currentParagraph: pending
                              style: nested];
            return;
        }

    if ([name isEqualToString: @"url"])
        {
            NSString *target =
                [element attributeForName: @"url"].stringValue ?:
                [element attributeForName: @"href"].stringValue;
            GSHelpLink *link = [GSHelpLink new];
            link.target = target ?: NormalizedTrim(element.stringValue);
            [self appendInlineNodes: element.children
                           intoBlock: link
                    currentParagraph: pending
                              style: style | GSHelpTextStyleCode];
            if (link.labelRuns.count == 0 && link.target.length > 0)
                [link appendLabelRun: link.target style: style];
            [block appendNode: link];
            return;
        }

    if ([name isEqualToString: @"ref"])
        {
            /* <ref function="cmd" section="3"> renders as a man link. */
            NSString *command =
                [element attributeForName: @"function"].stringValue ?:
                [element attributeForName: @"command"].stringValue ?:
                [element attributeForName: @"name"].stringValue;
            NSString *section =
                [element attributeForName: @"section"].stringValue ?: @"3";
            if (command.length > 0)
                {
                    GSHelpLink *link = [GSHelpLink new];
                    link.target = [NSString stringWithFormat:
                        @"help://man/%@/%@", command, section];
                    [link appendLabelRun:
                        NormalizedTrim(element.stringValue).length > 0
                            ? NormalizedTrim(element.stringValue)
                            : [NSString stringWithFormat: @"%@(%@)",
                                                          command, section]
                                  style: style];
                    [block appendNode: link];
                    return;
                }
        }

    /* Unknown or container-only element: walk transparently. */
    [self appendInlineNodes: element.children
                   intoBlock: block
            currentParagraph: pending
                      style: style];
}

/* Flushes a pending paragraph before a block boundary. */
- (void)flushParagraph:(GSHelpParagraph **)pending
{
    /* Empty paragraphs are dropped by keeping only ones with children;
     * nothing to do here beyond clearing the accumulator reference. */
    *pending = nil;
}

/* Block-level walker: maps known gsdoc structure, recurses through
 * everything else. `headingDepth` tracks chapter/section nesting. */
- (void)appendContentOfNodes:(NSArray<NSXMLNode *> *)nodes
                    intoNode:(GSHelpNode *)container
                     inDocument:(GSHelpDocument *)document
                    headingDepth:(NSInteger *)headingDepth
{
    GSHelpParagraph *pending = nil;

    for (NSXMLNode *node in nodes)
        {
            if ([node isKindOfClass: [NSXMLNode class]] && node.kind == NSXMLTextKind)
                {
                    /* Stray mixed-content text between blocks becomes its
                     * own paragraph so it cannot vanish. */
                    NSString *piece = NormalizedTrim(node.stringValue);
                    if (piece.length == 0)
                        continue;
                    [self flushParagraph: &pending];
                    GSHelpParagraph *paragraph = [GSHelpParagraph new];
                    GSHelpText *run = [GSHelpText new];
                    run.string = piece;
                    run.style = GSHelpTextStylePlain;
                    [paragraph appendNode: run];
                    [container appendNode: paragraph];
                    continue;
                }
            if (![node isKindOfClass: [NSXMLElement class]])
                continue;

            NSXMLElement *element = (NSXMLElement *)node;
            NSString *name = element.name.lowercaseString;

            /* Metadata-only wrappers. */
            if ([name isEqualToString: @"head"])
                continue;
            if ([name isEqualToString: @"front"])
                {
                    /* <front><contents/> holds the generated table of
                     * contents; the renderer derives its own TOC from
                     * headings, so this is intentionally dropped. */
                    continue;
                }

            /* Preformatted content keeps its whitespace verbatim. */
            if ([name isEqualToString: @"example"] ||
                [name isEqualToString: @"pre"])
                {
                    [self flushParagraph: &pending];
                    GSHelpCodeBlock *code = [GSHelpCodeBlock new];
                    code.code = element.stringValue ?: @"";
                    [container appendNode: code];
                    continue;
                }

            /* Structural containers with a <heading> child. */
            if ([name isEqualToString: @"chapter"] ||
                [name isEqualToString: @"section"] ||
                [name isEqualToString: @"s1"] || [name isEqualToString: @"s2"] ||
                [name isEqualToString: @"s3"] || [name isEqualToString: @"s4"])
                {
                    [self flushParagraph: &pending];
                    NSInteger depth = *headingDepth + 1;
                    NSXMLElement *headingElement =
                        [self childElementNamed: @"heading" ofElement: element];
                    if (headingElement != nil)
                        {
                            GSHelpHeading *heading = [GSHelpHeading new];
                            heading.text =
                                NormalizedTrim(headingElement.stringValue);
                            heading.level =
                                [self levelForHeadingAtDepth: depth];
                            [container appendNode: heading];
                        }
                    NSInteger innerDepth = depth;
                    NSMutableArray *rest = [NSMutableArray array];
                    for (NSXMLNode *child in element.children)
                        {
                            if (child == headingElement) continue;
                            /* Nested chapters/sections restart at their own
                             * depth relative to this container. */
                            [rest addObject: child];
                        }
                    [self appendContentOfNodes: rest
                                      intoNode: container
                                       inDocument: document
                                  headingDepth: &innerDepth];
                    *headingDepth = depth - 1;
                    continue;
                }

            if ([name isEqualToString: @"heading"])
                {
                    [self flushParagraph: &pending];
                    GSHelpHeading *heading = [GSHelpHeading new];
                    heading.text = NormalizedTrim(element.stringValue);
                    heading.level =
                        [self levelForHeadingAtDepth: *headingDepth + 1];
                    [container appendNode: heading];
                    continue;
                }

            /* Prose. */
            if ([name isEqualToString: @"p"] ||
                [name isEqualToString: @"abstract"])
                {
                    [self flushParagraph: &pending];
                    GSHelpParagraph *paragraph = [GSHelpParagraph new];
                    [self appendInlineNodes: element.children
                                  intoBlock: paragraph
                           currentParagraph: &pending
                                     style: GSHelpTextStylePlain];
                    [self flushParagraph: &pending];
                    [container appendNode: paragraph];
                    continue;
                }

            /* Lists: gsdoc uses <list> (and <olist> for ordered); items are
             * <item> children that contain further blocks. */
            if ([name isEqualToString: @"list"] ||
                [name isEqualToString: @"olist"] ||
                [name isEqualToString: @"itemizedlist"] ||
                [name isEqualToString: @"orderedlist"])
                {
                    [self flushParagraph: &pending];
                    GSHelpList *list = [GSHelpList new];
                    list.ordered = ![name isEqualToString: @"list"];
                    for (NSXMLNode *child in element.children)
                        {
                            if (![child isKindOfClass: [NSXMLElement class]])
                                continue;
                            NSXMLElement *childElement =
                                (NSXMLElement *)child;
                            if (![childElement.name.lowercaseString
                                      isEqualToString: @"item"] &&
                                ![childElement.name.lowercaseString
                                      isEqualToString: @"li"])
                                continue;
                            GSHelpListItem *item = [GSHelpListItem new];
                            GSHelpParagraph *itemPending = nil;
                            [self appendInlineNodes: childElement.children
                                          intoBlock: item
                                   currentParagraph: &itemPending
                                             style: GSHelpTextStylePlain];
                            [self flushParagraph: &itemPending];
                            [list appendNode: item];
                        }
                    [container appendNode: list];
                    continue;
                }

            /* Definition lists: <term>/<def> pairs become a paragraph of
             * bold term followed by definition text. */
            if ([name isEqualToString: @"dlist"] ||
                [name isEqualToString: @"deflist"])
                {
                    [self flushParagraph: &pending];
                    NSString *term =
                        NormalizedTrim([self textOfChildElementNamed:
                                             @"term" ofElement: element]);
                    NSMutableString *line =
                        [NSMutableString stringWithString: term ?: @""];
                    GSHelpParagraph *paragraph = [GSHelpParagraph new];
                    if (line.length > 0)
                        {
                            GSHelpText *run = [GSHelpText new];
                            run.string = [line stringByAppendingString: @" - "];
                            run.style = GSHelpTextStyleBold;
                            [paragraph appendNode: run];
                        }
                    NSXMLElement *def =
                        [self childElementNamed: @"def" ofElement: element];
                    if (def != nil)
                        {
                            GSHelpText *run = [GSHelpText new];
                            run.string =
                                NormalizeWhitespace(def.stringValue);
                            run.style = GSHelpTextStylePlain;
                            [paragraph appendNode: run];
                        }
                    [container appendNode: paragraph];
                    continue;
                }

            /* API documentation entities (autogsdoc output): render a
             * bold signature/heading plus declared line, then recurse so
             * descriptions and nested entities follow. */
            if ([name isEqualToString: @"class"] ||
                [name isEqualToString: @"method"] ||
                [name isEqualToString: @"function"] ||
                [name isEqualToString: @"macro"] ||
                [name isEqualToString: @"ivariable"] ||
                [name isEqualToString: @"type"] ||
                [name isEqualToString: @"constant"] ||
                [name isEqualToString: @"variable"])
                {
                    [self flushParagraph: &pending];
                    NSString *signature =
                        [self signatureForEntity: element kind: name];
                    GSHelpHeading *heading = [GSHelpHeading new];
                    heading.text = signature;
                    heading.level = 3;
                    [container appendNode: heading];

                    NSString *declared = NormalizedTrim(
                        [self textOfChildElementNamed: @"declared"
                                            ofElement: element]);
                    if (declared.length > 0)
                        {
                            GSHelpParagraph *declaredParagraph =
                                [GSHelpParagraph new];
                            GSHelpText *run = [GSHelpText new];
                            run.string =
                                [NSString stringWithFormat:
                                    NSLocalizedString(@"Declared in %@",
                                                      nil), declared];
                            run.style = GSHelpTextStyleCode;
                            [declaredParagraph appendNode: run];
                            [container appendNode: declaredParagraph];
                        }

                    NSMutableArray *rest = [NSMutableArray array];
                    for (NSXMLNode *child in element.children)
                        {
                            NSXMLElement *ce = nil;
                            if ([child isKindOfClass: [NSXMLElement class]])
                                ce = (NSXMLElement *)child;
                            if (ce != nil &&
                                [ce.name.lowercaseString
                                    isEqualToString: @"declared"])
                                continue;
                            [rest addObject: child];
                        }
                    NSInteger innerDepth = *headingDepth;
                    [self appendContentOfNodes: rest
                                      intoNode: container
                                       inDocument: document
                                  headingDepth: &innerDepth];
                    continue;
                }

            /* Everything else (back, quote, image, ...) recurses into its
             * children; passing the element itself would loop forever. */
            if ([element.children count] > 0)
                [self appendContentOfNodes: element.children
                                  intoNode: container
                                   inDocument: document
                              headingDepth: headingDepth];
        }
    [self flushParagraph: &pending];
}

/* Composes a readable signature line for autogsdoc API entities. */
- (NSString *)signatureForEntity:(NSXMLElement *)element
                            kind:(NSString *)kind
{
    NSString *kindLabel = kind.capitalizedString;
    if ([kind isEqualToString: @"ivariable"]) kindLabel = @"Instance variable";
    if ([kind isEqualToString: @"method"])
        {
            NSString *type = [element attributeForName: @"type"].stringValue;
            NSString *sel = NormalizedTrim(
                [self textOfChildElementNamed: @"sel" ofElement: element]);
            NSString *name = [element attributeForName: @"name"].stringValue;
            NSString *core = sel.length > 0 ? sel : (name ?: @"");
            return type.length > 0
                ? [NSString stringWithFormat: @"%@ %@", type, core]
                : core;
        }
    NSString *nameAttr = [element attributeForName: @"name"].stringValue;
    if (nameAttr.length > 0)
        return [NSString stringWithFormat: @"%@ %@", kindLabel, nameAttr];
    NSString *text = NormalizedTrim(element.stringValue);
    return text.length > 0
        ? [NSString stringWithFormat: @"%@ %@", kindLabel, text]
        : kindLabel;
}

@end

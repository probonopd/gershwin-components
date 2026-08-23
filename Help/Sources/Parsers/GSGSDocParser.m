/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSGSDocParser.h"

#import "GSHelpDocument.h"
#import "GSHelpNode.h"

static NSString *const GSGSDocErrorDomain = @"GSGSDocParserErrorDomain";

#pragma mark - String helpers

/* Collapses whitespace runs so multi-line XML source text renders as
 * one flowing line where the DTD means prose. */
static NSString *GSDocSqueeze(NSString *string)
{
    if (string == nil)
      {
        return @"";
      }
    NSMutableString *out =
        [[string stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]]
            mutableCopy];
    while (YES)
      {
        NSRange range = [out rangeOfCharacterFromSet:
            [NSCharacterSet newlineCharacterSet]];
        if (range.location == NSNotFound)
          {
            break;
          }
        [out replaceCharactersInRange: range withString: @" "];
      }
    return out;
}

/* A heading anchor name stable enough for in-document links. */
static NSString *GSDocSlug(NSString *text)
{
    return [[GSDocSqueeze(text).lowercaseString
        stringByReplacingOccurrencesOfString: @" "
                                  withString: @"-"] mutableCopy];
}

/* Value of an attribute, squeezed and defaulted. */
static NSString *GSDocAttr(NSXMLElement *element, NSString *name)
{
    return GSDocSqueeze([[element attributeForName: name] stringValue]);
}

@implementation GSGSDocParser

#pragma mark - GSHelpParser

- (BOOL)canParseURL:(NSURL *)url
{
    if (url == nil)
      {
        return NO;
      }
    return [[[url pathExtension] lowercaseString]
        isEqualToString: @"gsdoc"];
}

- (nullable GSHelpDocument *)parseURL:(NSURL *)url
                                error:(NSError **)error
{
    if (![self canParseURL: url])
      {
        if (error != NULL)
          {
            *error = [NSError errorWithDomain: GSGSDocErrorDomain
                                         code: 1
                                     userInfo:
                          @{ NSLocalizedDescriptionKey :
                                 @"Not a GSdoc file" }];
          }
        return nil;
      }

    if (![[NSFileManager defaultManager]
            fileExistsAtPath: [url path]])
      {
        if (error != NULL)
          {
            *error = [NSError errorWithDomain: GSGSDocErrorDomain
                                         code: 3
                                     userInfo:
                          @{ NSLocalizedDescriptionKey :
                                 [NSString stringWithFormat:
                                       @"%@ does not exist",
                                       [url path]] }];
          }
        return nil;
      }

    NSError *xmlError = nil;
    NSXMLDocument *xml = [[NSXMLDocument alloc]
        initWithContentsOfURL: url
                      options: 0
                        error: &xmlError];
    NSXMLElement *root = [xml rootElement];
    if (root == nil || ![[root name] isEqualToString: @"gsdoc"])
      {
        if (error != NULL)
          {
            *error = [NSError errorWithDomain: GSGSDocErrorDomain
                                         code: 2
                                     userInfo:
                          @{ NSLocalizedDescriptionKey :
                                 [NSString stringWithFormat:
                                       @"%@ is not valid GSdoc XML",
                                       [url path]] }];
          }
        return nil;
      }

    GSHelpDocument *document = [GSHelpDocument new];
    document.sourceURL = url;
    document.sourceType = @"gsdoc";
    GSHelpSection *body = [GSHelpSection new];
    document.rootNode = body;

    NSXMLElement *head = [[root elementsForName: @"head"] firstObject];
    if (head != nil)
      {
        [self consumeHead: head into: document];
      }

    NSXMLElement *bodyElement =
        [[root elementsForName: @"body"] firstObject];
    if (bodyElement != nil)
      {
        [self consumeBlocksOf: bodyElement into: body level: 0];
      }

    return document;
}

#pragma mark - Head metadata

- (void)consumeHead:(NSXMLElement *)head into:(GSHelpDocument *)document
{
    NSXMLElement *title = [[head elementsForName: @"title"] firstObject];
    if (title != nil)
      {
        document.title = GSDocSqueeze([title stringValue]);
      }

    NSMutableDictionary<NSString *, id> *metadata =
        [document.metadata mutableCopy] ?: [NSMutableDictionary new];

    for (NSXMLNode *node in [head children])
      {
        if ([node kind] != NSXMLElementKind)
          {
            continue;
          }
        NSXMLElement *element = (NSXMLElement *)node;
        NSString *name = [element name];
        if ([name isEqualToString: @"author"])
          {
            NSString *author = GSDocAttr(element, @"name");
            if ([author length] > 0)
              {
                metadata[@"author"] = author;
              }
          }
        else if ([name isEqualToString: @"version"]
                     || [name isEqualToString: @"date"])
          {
            NSString *value = GSDocSqueeze([element stringValue]);
            if ([value length] > 0)
              {
                metadata[name] = value;
              }
          }
      }
    document.metadata = metadata;
}

#pragma mark - Block structure

/* chapter/section/subsect/subsubsect map to heading levels; all
 * content lands flat under the single root section, matching how
 * the Markdown parser structures documents. */
- (NSUInteger)levelOfStructureElement:(NSString *)name
{
    if ([name isEqualToString: @"chapter"])
      {
        return 1;
      }
    if ([name isEqualToString: @"section"])
      {
        return 2;
      }
    if ([name isEqualToString: @"subsect"])
      {
        return 3;
      }
    if ([name isEqualToString: @"subsubsect"])
      {
        return 4;
      }
    return 0;
}

- (BOOL)isStructureElement:(NSString *)name
{
    return [self levelOfStructureElement: name] > 0;
}

- (void)consumeBlocksOf:(NSXMLElement *)container
                   into:(GSHelpSection *)into
                  level:(NSUInteger)level
{
    NSUInteger headingLevel = MIN(level + 1, (NSUInteger)4);

    for (NSXMLNode *node in [container children])
      {
        if ([node kind] != NSXMLElementKind)
          {
            continue;
          }
        NSXMLElement *element = (NSXMLElement *)node;
        NSString *name = [element name];

        if ([self isStructureElement: name])
          {
            NSXMLElement *headingElement =
                [[element elementsForName: @"heading"] firstObject];
            NSString *text = GSDocSqueeze([headingElement stringValue]);
            if ([text length] == 0)
              {
                text = name;
              }
            GSHelpAnchor *anchor = [GSHelpAnchor new];
            anchor.name = GSDocSlug(text);
            [into appendNode: anchor];
            GSHelpHeading *heading = [GSHelpHeading new];
            heading.text = text;
            heading.level = headingLevel;
            [into appendNode: heading];
            [self consumeBlocksOf: element into: into level: headingLevel];
            continue;
          }
        [self consumeContentElement: element into: into];
      }
}

#pragma mark - Content elements

- (void)consumeContentElement:(NSXMLElement *)element
                         into:(GSHelpSection *)into
{
    NSString *name = [element name];

    if ([name isEqualToString: @"p"])
      {
        GSHelpParagraph *paragraph = [GSHelpParagraph new];
        [self consumeInlinesOf: element intoTarget: paragraph];
        [into appendNode: paragraph];
      }
    else if ([name isEqualToString: @"list"])
      {
        [into appendNode: [self listFrom: element ordered: NO]];
      }
    else if ([name isEqualToString: @"example"])
      {
        GSHelpCodeBlock *block = [GSHelpCodeBlock new];
        block.code = [self trimmedExampleText: [element stringValue]];
        block.language = @"";
        [into appendNode: block];
      }
    else if ([name isEqualToString: @"class"]
                 || [name isEqualToString: @"category"]
                 || [name isEqualToString: @"protocol"]
                 || [name isEqualToString: @"function"]
                 || [name isEqualToString: @"method"]
                 || [name isEqualToString: @"ivariable"]
                 || [name isEqualToString: @"variable"]
                 || [name isEqualToString: @"constant"]
                 || [name isEqualToString: @"macro"]
                 || [name isEqualToString: @"type"])
      {
        [self consumeAPIDeclaration: element into: into];
      }
    else if ([name isEqualToString: @"desc"])
      {
        [self consumeDesc: element into: into];
      }
    /* front/back/index/contents are autogsdoc-generated navigation;
     * our sidebar rebuilds that information itself. */
}

/* Trims shared indentation so indented XML sources render tight. */
- (NSString *)trimmedExampleText:(NSString *)raw
{
    NSArray *lines = [raw componentsSeparatedByString: @"\n"];
    NSMutableArray *kept = [NSMutableArray new];
    NSUInteger minIndent = NSUIntegerMax;
    for (NSString *line in lines)
      {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed length] == 0)
          {
            continue;
          }
        minIndent = MIN(minIndent,
                        [line length] - [trimmed length]);
        [kept addObject: line];
      }
    if (minIndent == NSUIntegerMax)
      {
        return @"";
      }
    NSMutableString *out = [NSMutableString new];
    for (NSString *line in kept)
      {
        [out appendString:
            [line substringFromIndex: MIN(minIndent, [line length])]];
        [out appendString: @"\n"];
      }
    while ([out hasSuffix: @"\n"])
      {
        [out deleteCharactersInRange: NSMakeRange([out length] - 1, 1)];
      }
    return out;
}

- (GSHelpList *)listFrom:(NSXMLElement *)element ordered:(BOOL)ordered
{
    GSHelpList *list = [GSHelpList new];
    list.ordered = ordered;
    for (NSXMLNode *node in [element children])
      {
        if ([node kind] != NSXMLElementKind
            || ![[node name] isEqualToString: @"item"])
          {
            continue;
          }
        GSHelpListItem *item = [GSHelpListItem new];
        /* Items mix raw text with inline tags, <p>, nested lists
         * and examples; keep document order. */
        for (NSXMLNode *child in [node children])
          {
            if ([child kind] == NSXMLTextKind)
              {
                NSString *text = GSDocSqueeze([child stringValue]);
                if ([text length] > 0)
                  {
                    [item appendNode:
                        [self runWith: text
                                style: GSHelpTextStylePlain]];
                  }
                continue;
              }
            if ([child kind] != NSXMLElementKind)
              {
                continue;
              }
            NSXMLElement *element = (NSXMLElement *)child;
            NSString *name = [element name];
            if ([name isEqualToString: @"list"])
              {
                [item appendNode:
                          [self listFrom: element ordered: NO]];
              }
            else if ([name isEqualToString: @"example"])
              {
                GSHelpCodeBlock *block = [GSHelpCodeBlock new];
                block.code =
                    [self trimmedExampleText: [element stringValue]];
                block.language = @"";
                [item appendNode: block];
              }
            else
              {
                [self consumeInline: element intoTarget: item];
              }
          }
        [list appendNode: item];
      }
    return list;
}

- (void)consumeDesc:(NSXMLElement *)desc into:(GSHelpSection *)into
{
    BOOL sawBlockChild = NO;
    for (NSXMLNode *node in [desc children])
      {
        if ([node kind] != NSXMLElementKind)
          {
            continue;
          }
        NSXMLElement *element = (NSXMLElement *)node;
        if ([[element name] isEqualToString: @"p"])
          {
            sawBlockChild = YES;
            GSHelpParagraph *paragraph = [GSHelpParagraph new];
            [self consumeInlinesOf: element intoTarget: paragraph];
            [into appendNode: paragraph];
          }
        else if ([[element name] isEqualToString: @"list"])
          {
            sawBlockChild = YES;
            [into appendNode: [self listFrom: element ordered: NO]];
          }
      }
    if (!sawBlockChild)
      {
        /* Bare inline description text. */
        GSHelpParagraph *paragraph = [GSHelpParagraph new];
        [self consumeInlinesOf: desc intoTarget: paragraph];
        if ([[paragraph children] count] > 0)
          {
            [into appendNode: paragraph];
          }
      }
}

#pragma mark - Inline runs

- (GSHelpText *)runWith:(NSString *)string style:(GSHelpTextStyle)style
{
    GSHelpText *run = [GSHelpText new];
    run.string = string;
    run.style = style;
    return run;
}

/* The target accepts runs via appendNode:, so paragraphs and list
 * items share this path. */
- (void)consumeInlinesOf:(NSXMLElement *)container
             intoTarget:(GSHelpNode *)target
{
    for (NSXMLNode *node in [container children])
      {
        if ([node kind] == NSXMLTextKind)
          {
            NSString *text = GSDocSqueeze([node stringValue]);
            if ([text length] > 0)
              {
                [target appendNode:
                    [self runWith: text style: GSHelpTextStylePlain]];
              }
          }
        else if ([node kind] == NSXMLElementKind)
          {
            [self consumeInline: (NSXMLElement *)node intoTarget: target];
          }
      }
}

- (void)consumeInline:(NSXMLElement *)element
           intoTarget:(GSHelpNode *)target
{
    NSString *name = [element name];
    GSHelpTextStyle style = GSHelpTextStylePlain;

    if ([name isEqualToString: @"em"] || [name isEqualToString: @"var"])
      {
        style = GSHelpTextStyleItalic;
      }
    else if ([name isEqualToString: @"strong"])
      {
        style = GSHelpTextStyleBold;
      }
    else if ([name isEqualToString: @"code"]
                 || [name isEqualToString: @"sel"]
                 || [name isEqualToString: @"type"])
      {
        style = GSHelpTextStyleCode;
      }
    else if ([name isEqualToString: @"br"])
      {
        [target appendNode:
            [self runWith: @"\n" style: GSHelpTextStylePlain]];
        return;
      }
    else if ([name isEqualToString: @"url"]
                 || [name isEqualToString: @"uref"])
      {
        NSString *href = GSDocAttr(element, @"url");
        NSString *label = GSDocSqueeze([element stringValue]);
        GSHelpLink *link = [GSHelpLink new];
        link.target = [href length] > 0 ? href : label;
        [link appendLabelRun: [label length] > 0 ? label : href
                       style: GSHelpTextStylePlain];
        [target appendNode: link];
        return;
      }
    else if ([name isEqualToString: @"ref"])
      {
        /* Cross references without resolvable targets stay plain
         * until the gsdoc resolver (SPEC 28) exists. */
        [self consumeInlinesOf: element intoTarget: target];
        return;
      }
    else if ([name isEqualToString: @"email"])
      {
        NSString *address = GSDocAttr(element, @"address");
        if ([address length] == 0)
          {
            address = GSDocSqueeze([element stringValue]);
          }
        [target appendNode:
            [self runWith: address style: GSHelpTextStylePlain]];
        return;
      }

    /* Style wrappers and anything unknown keep their content. */
    NSString *text = GSDocSqueeze([element stringValue]);
    if ([text length] > 0)
      {
        [target appendNode: [self runWith: text style: style]];
      }
    else
      {
        [self consumeInlinesOf: element intoTarget: target];
      }
}

#pragma mark - API declarations

/* Reconstructs readable signatures (SPEC 27): every API element
 * becomes a monospace declaration followed by its description as
 * prose. The semantic API browser stays future work. */
- (void)consumeAPIDeclaration:(NSXMLElement *)element
                         into:(GSHelpSection *)into
{
    NSString *kind = [element name];
    GSHelpCodeBlock *block = [GSHelpCodeBlock new];
    block.language = @"objc";

    if ([kind isEqualToString: @"class"])
      {
        block.code = [self classSignature: element];
      }
    else if ([kind isEqualToString: @"category"])
      {
        block.code = [NSString stringWithFormat:
                           @"@interface %@ (%@)",
                           GSDocAttr(element, @"name"),
                           GSDocAttr(element, @"super")];
      }
    else if ([kind isEqualToString: @"protocol"])
      {
        block.code = [NSString stringWithFormat:
                           @"@protocol %@",
                           GSDocAttr(element, @"name")];
      }
    else
      {
        block.code = [self signatureForAPI: element];
      }
    [into appendNode: block];
    [self consumeAPIDescriptionChildren: element into: into];
}

- (NSString *)classSignature:(NSXMLElement *)element
{
    NSMutableString *decl = [NSMutableString new];
    NSString *name = GSDocAttr(element, @"name");
    [decl appendFormat: @"@interface %@",
         [name length] > 0 ? name : @"?"];
    NSString *superName = GSDocAttr(element, @"super");
    if ([superName length] > 0)
      {
        [decl appendFormat: @" : %@", superName];
      }
    [decl appendString: @"\n{\n"];
    for (NSXMLNode *node in [element children])
      {
        if ([node kind] == NSXMLElementKind
            && [[node name] isEqualToString: @"ivariable"])
          {
            NSXMLElement *ivar = (NSXMLElement *)node;
            [decl appendFormat: @"    %@ %@;\n",
                 GSDocAttr(ivar, @"type"),
                 GSDocAttr(ivar, @"name")];
          }
      }
    [decl appendString: @"}"];
    NSXMLElement *declared =
        [[element elementsForName: @"declared"] firstObject];
    if (declared != nil)
      {
        [decl appendFormat: @"\n// declared in %@",
             GSDocSqueeze([declared stringValue])];
      }
    return decl;
}

/* Methods and functions nest inside class/protocol blocks; their
 * descriptions become prose right after each declaration. */
- (void)consumeAPIDescriptionChildren:(NSXMLElement *)element
                                 into:(GSHelpSection *)into
{
    for (NSXMLNode *node in [element children])
      {
        if ([node kind] != NSXMLElementKind)
          {
            continue;
          }
        NSXMLElement *child = (NSXMLElement *)node;
        NSString *name = [child name];
        if ([name isEqualToString: @"desc"])
          {
            [self consumeDesc: child into: into];
          }
        else if ([name isEqualToString: @"method"]
                     || [name isEqualToString: @"function"]
                     || [name isEqualToString: @"constant"]
                     || [name isEqualToString: @"macro"]
                     || [name isEqualToString: @"variable"]
                     || [name isEqualToString: @"type"])
          {
            [self consumeAPIDeclaration: child into: into];
          }
        else if ([name isEqualToString: @"p"])
          {
            GSHelpParagraph *paragraph = [GSHelpParagraph new];
            [self consumeInlinesOf: child intoTarget: paragraph];
            [into appendNode: paragraph];
          }
      }
}

- (NSString *)signatureForAPI:(NSXMLElement *)element
{
    NSString *kind = [element name];

    if ([kind isEqualToString: @"method"])
      {
        return [self methodSignature: element];
      }

    if ([kind isEqualToString: @"function"])
      {
        NSString *returnType = GSDocAttr(element, @"type");
        NSString *name = GSDocAttr(element, @"name");
        NSArray *args = [element elementsForName: @"arg"];
        NSMutableArray *params = [NSMutableArray new];
        for (NSXMLElement *arg in args)
          {
            NSString *argType =
                GSDocAttr(arg, @"type");
            if ([argType length] == 0)
              {
                argType = @"id";
              }
            NSString *argName = GSDocSqueeze([arg stringValue]);
            if ([argName length] == 0)
              {
                argName = @"_";
              }
            [params addObject:
                [NSString stringWithFormat: @"%@ %@", argType, argName]];
          }
        return [NSString stringWithFormat:
                         @"%@ %@(%@)",
                         [returnType length] > 0 ? returnType : @"void",
                         [name length] > 0 ? name : @"?",
                         [params componentsJoinedByString: @", "]];
      }

    if ([kind isEqualToString: @"ivariable"]
            || [kind isEqualToString: @"variable"]
            || [kind isEqualToString: @"type"]
            || [kind isEqualToString: @"constant"]
            || [kind isEqualToString: @"macro"])
      {
        NSString *type = GSDocAttr(element, @"type");
        NSString *name = GSDocAttr(element, @"name");
        if ([name length] == 0)
          {
            name = GSDocSqueeze([element stringValue]);
          }
        return [type length] > 0
                   ? [NSString stringWithFormat: @"%@ %@;", type, name]
                   : [NSString stringWithFormat: @"%@;", name];
      }

    return @"";
}

/* "- (Ret)selPart:(Arg)a part:(Arg)b"; factory="yes" gives '+'. */
- (NSString *)methodSignature:(NSXMLElement *)element
{
    NSXMLElement *selElement =
        [[element elementsForName: @"sel"] firstObject];
    NSString *selector = GSDocSqueeze([selElement stringValue]);
    if ([selector length] == 0)
      {
        return @"";
      }
    NSString *prefix =
        [GSDocAttr(element, @"factory")
            isEqualToString: @"yes"] ? @"+" : @"-";
    NSString *returnType = GSDocAttr(element, @"type");
    if ([returnType length] == 0)
      {
        returnType = @"id";
      }

    NSArray *parts = [selector componentsSeparatedByString: @":"];
    NSArray *args = [element elementsForName: @"arg"];

    NSMutableString *sig = [NSMutableString new];
    [sig appendFormat: @"%@ (%@)", prefix, returnType];
    if ([parts count] <= 1)
      {
        [sig appendString: selector];
        return sig;
      }
    for (NSUInteger i = 0; i + 1 < [parts count]; i++)
      {
        NSString *label = parts[i];
        NSString *type = @"id";
        NSString *name = parts[i + 1];
        if (i < [args count])
          {
            NSXMLElement *arg = args[i];
            NSString *argType = GSDocAttr(arg, @"type");
            if ([argType length] > 0)
              {
                type = argType;
              }
            NSString *argName = GSDocSqueeze([arg stringValue]);
            if ([argName length] > 0)
              {
                name = argName;
              }
          }
        if ([name length] == 0)
          {
            name = @"_";
          }
        /* First part follows the return type directly; later parts
         * are space separated. */
        [sig appendFormat: @"%s%@:(%@)%@",
             i == 0 ? "" : " ",
             [label length] > 0 ? label : @"", type, name];
      }
    return sig;
}

@end

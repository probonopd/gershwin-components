/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSHelpNode.h"

#pragma mark - Case normalization

NSString *GSHelpTitleCased(NSString *string)
{
    if (string == nil)
      {
        return nil;
      }
    /* Only transform strings whose letters are all uppercase, so mixed
     * headings like "Getting Started" or "API" are left untouched. */
    BOOL hasLetter = NO;
    BOOL allUpper = YES;
    for (NSUInteger i = 0; i < [string length]; i++)
      {
        unichar c = [string characterAtIndex: i];
        if (c > 127)
          {
            continue;
          }
        if (isalpha((int)c))
          {
            hasLetter = YES;
            if (islower((int)c))
              {
                allUpper = NO;
                break;
              }
          }
      }
    if (!hasLetter || !allUpper)
      {
        return string;
      }

    /* Title case: capitalise the first letter of every
     * whitespace-separated word, lowercase the rest. */
    NSArray<NSString *> *words =
        [string componentsSeparatedByCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray<NSString *> *out =
        [NSMutableArray arrayWithCapacity: [words count]];
    for (NSString *word in words)
      {
        if ([word length] == 0)
          {
            [out addObject: word];
            continue;
          }
        NSString *first = [word substringToIndex: 1];
        NSString *rest = [word substringFromIndex: 1];
        [out addObject:
            [[first uppercaseString]
                stringByAppendingString: [rest lowercaseString]]];
      }
    return [out componentsJoinedByString: @" "];
}

@implementation GSHelpNode
{
    NSMutableArray<GSHelpNode *> *_children;
}

- (instancetype)init
{
    self = [super init];
    if (self != nil)
      {
        _children = [NSMutableArray new];
      }
    return self;
}

- (NSArray<__kindof GSHelpNode *> *)children
{
    return [_children copy];
}

- (void)appendNode:(GSHelpNode *)node
{
    /* Silently ignore nil so parsers can append conditionally without
     * guarding every call site. */
    if (node == nil || node == self)
      {
        return;
      }
    node.parent = self;
    [_children addObject:node];
}

@end

@implementation GSHelpSection
@end

@implementation GSHelpHeading

- (void)setLevel:(NSUInteger)level
{
    /* SPEC 16 defines H1...H4 only; clamp instead of storing junk. */
    if (level < 1)
      {
        level = 1;
      }
    else if (level > 4)
      {
        level = 4;
      }
    _level = level;
}

@end

@implementation GSHelpParagraph
@end

@implementation GSHelpText
@end

@implementation GSHelpCodeBlock
@end

@implementation GSHelpList
@end

@implementation GSHelpListItem
@end

@implementation GSHelpTableCell
@end

@implementation GSHelpTableRow

- (void)appendCellWithText:(NSString *)text
{
    GSHelpTableCell *cell = [GSHelpTableCell new];
    cell.text = text;
    [self appendNode:cell];
}

- (NSArray<GSHelpTableCell *> *)cells
{
    NSMutableArray *result = [NSMutableArray new];
    for (GSHelpNode *child in [self children])
      {
        if ([child isKindOfClass:[GSHelpTableCell class]])
          {
            [result addObject:child];
          }
      }
    return result;
}

@end

@implementation GSHelpTable

- (NSArray<GSHelpTableRow *> *)rows
{
    NSMutableArray *result = [NSMutableArray new];
    for (GSHelpNode *child in [self children])
      {
        if ([child isKindOfClass:[GSHelpTableRow class]])
          {
            [result addObject:child];
          }
      }
    return result;
}

@end

@implementation GSHelpImage
@end

@implementation GSHelpLink

- (void)appendLabelRun:(NSString *)text style:(GSHelpTextStyle)style
{
    GSHelpText *run = [GSHelpText new];
    run.string = text;
    run.style = style;
    [self appendNode:run];
}

- (NSArray<GSHelpText *> *)labelRuns
{
    NSMutableArray *result = [NSMutableArray new];
    for (GSHelpNode *child in [self children])
      {
        if ([child isKindOfClass:[GSHelpText class]])
          {
            [result addObject:child];
          }
      }
    return result;
}

- (NSString *)labelText
{
    NSMutableString *result = [NSMutableString new];
    for (GSHelpText *run in [self labelRuns])
      {
        if (run.string != nil)
          {
            [result appendString:run.string];
          }
      }
    return result;
}

@end

@implementation GSHelpQuote
@end

@implementation GSHelpAnchor
@end

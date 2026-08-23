/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSHelpNode.h"

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

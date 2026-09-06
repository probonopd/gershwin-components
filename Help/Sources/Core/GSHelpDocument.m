/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSHelpDocument.h"

@class GSHelpAnchor;

@interface GSHelpDocument ()
/* Backing storage for the lazily derived readonly properties; the
 * getters are hand-written, so no ivars are auto-synthesized. */
@property (nonatomic, strong, nullable)
    NSArray<GSHelpTOCEntry *> *tableOfContents;
@property (nonatomic, strong, nullable)
    NSDictionary<NSString *, GSHelpNode *> *anchors;
@end

@implementation GSHelpTOCEntry

- (instancetype)initWithLevel:(NSUInteger)level
                      heading:(GSHelpHeading *)heading
{
    self = [super init];
    if (self != nil)
      {
        _level = level;
        _heading = heading;
      }
    return self;
}

@end

@implementation GSHelpDocument

- (instancetype)init
{
    self = [super init];
    if (self != nil)
      {
        _metadata = @{};
      }
    return self;
}

- (void)setMetadata:(NSDictionary<NSString *, id> *)metadata
{
    _metadata = [metadata copy] ?: @{};
}

- (void)setRootNode:(GSHelpSection *)rootNode
{
    /* Derived data must never outlive the root it came from. */
    if (_rootNode != rootNode)
      {
        _rootNode = rootNode;
        _tableOfContents = nil;
        _anchors = nil;
      }
}

/* Single ordered walk so TOC and anchors agree on document order. */
- (void)collectFromNode:(GSHelpNode *)node
              intoTOC:(NSMutableArray<GSHelpTOCEntry *> *)toc
           intoAnchors:(NSMutableDictionary *)anchors
{
    for (GSHelpNode *child in [node children])
      {
        if ([child isKindOfClass:[GSHelpHeading class]])
          {
            GSHelpHeading *heading = (GSHelpHeading *)child;
            [toc addObject:[[GSHelpTOCEntry alloc]
                               initWithLevel:heading.level
                                     heading:heading]];
          }
        else if ([child isKindOfClass:[GSHelpAnchor class]])
          {
            GSHelpAnchor *anchor = (GSHelpAnchor *)child;
            NSString *name = anchor.name;
            if (name.length > 0 && anchors[name] == nil)
              {
                anchors[name] = anchor;
              }
          }
        [self collectFromNode:child intoTOC:toc intoAnchors:anchors];
      }
}

- (NSArray<GSHelpTOCEntry *> *)tableOfContents
{
    if (_tableOfContents == nil)
      {
        if (_rootNode == nil)
          {
            return @[];
          }
        NSMutableArray *toc = [NSMutableArray new];
        NSMutableDictionary *anchors = [NSMutableDictionary new];
        [self collectFromNode:_rootNode intoTOC:toc intoAnchors:anchors];
        /* Cache anchors too so one traversal serves both accessors. */
        _anchors = anchors;
        _tableOfContents = toc;
      }
    return _tableOfContents;
}

- (NSDictionary<NSString *, __kindof GSHelpNode *> *)anchors
{
    /* Touching tableOfContents fills both caches. */
    [self tableOfContents];
    return _anchors ?: @{};
}

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EPUBTOCEntry.h"

@implementation EPUBTOCEntry

- (instancetype)init
{
    self = [super init];
    if (self)
    {
        _children = [NSArray array];
    }
    return self;
}

- (NSArray<EPUBTOCEntry *> *)flattenedEntries
{
    NSMutableArray<EPUBTOCEntry *> *result = [NSMutableArray array];
    [result addObject:self];
    for (EPUBTOCEntry *child in self.children)
    {
        [result addObjectsFromArray:[child flattenedEntries]];
    }
    return result;
}

- (id)copyWithZone:(NSZone *)zone
{
    EPUBTOCEntry *copy = [[EPUBTOCEntry allocWithZone:zone] init];
    copy.title = self.title;
    copy.contentPath = self.contentPath;
    copy.playOrder = self.playOrder;
    NSMutableArray<EPUBTOCEntry *> *kids = [NSMutableArray arrayWithCapacity:self.children.count];
    for (EPUBTOCEntry *child in self.children)
    {
        [kids addObject:[child copyWithZone:zone]];
    }
    copy.children = kids;
    return copy;
}

@end

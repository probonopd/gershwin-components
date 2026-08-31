/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "OPDSEntry.h"

@implementation OPDSEntry

+ (instancetype)entryWithTitle:(NSString *)title
                        author:(NSString *)author
{
  OPDSEntry *e = [[OPDSEntry alloc] init];
  e.title = title;
  e.author = author;
  return e;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<%@: %@ by %@>", [self class],
            self.title ?: @"", self.author ?: @""];
}

@end

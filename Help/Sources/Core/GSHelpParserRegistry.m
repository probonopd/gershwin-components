/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSHelpParserRegistry.h"

@implementation GSHelpParserRegistry
{
    NSMutableArray<id<GSHelpParser>> *_parsers;
}

- (instancetype)init
{
    self = [super init];
    if (self != nil)
      {
        _parsers = [NSMutableArray new];
      }
    return self;
}

- (void)registerParser:(id<GSHelpParser>)parser
{
    /* A parser registered twice would just be asked twice; keep the
     * order list free of duplicates instead. */
    if (parser == nil || [_parsers containsObject:parser])
      {
        return;
      }
    [_parsers addObject:parser];
}

- (void)unregisterParser:(id<GSHelpParser>)parser
{
    [_parsers removeObject:parser];
}

- (id<GSHelpParser>)parserForURL:(NSURL *)url
{
    for (id<GSHelpParser> parser in _parsers)
      {
        if ([parser canParseURL:url])
          {
            return parser;
          }
      }
    return nil;
}

- (NSArray<id<GSHelpParser>> *)parsers
{
    return [_parsers copy];
}

@end

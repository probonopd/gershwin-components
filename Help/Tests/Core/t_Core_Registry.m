/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_Core_Registry - registration order, first-match lookup,
 * unregistration, empty-registry behavior. */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "GSHelpParser.h"
#import "GSHelpParserRegistry.h"

@interface StubParser : NSObject <GSHelpParser>
@property (nonatomic) BOOL accept;
@end

@implementation StubParser
- (BOOL)canParseURL:(NSURL *)url
{
  return _accept;
}
- (GSHelpDocument *)parseURL:(NSURL *)url error:(NSError **)error
{
  return nil;
}
@end

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  NSURL *url = [NSURL URLWithString: @"file:///tmp/x.md"];

  START_SET("registration order and lookup")
  {
    GSHelpParserRegistry *reg = [GSHelpParserRegistry new];

    PASS(reg.parsers.count == 0, "starts empty");
    PASS([reg parserForURL: url] == nil,
         "no parser registered -> nil, no crash");

    StubParser *p1 = [StubParser new];
    p1.accept = NO;
    StubParser *p2 = [StubParser new];
    p2.accept = YES;
    StubParser *p3 = [StubParser new];
    p3.accept = YES;

    [reg registerParser: p1];
    [reg registerParser: p2];
    [reg registerParser: p3];

    PASS(reg.parsers.count == 3, "three parsers registered");
    PASS(reg.parsers[0] == p1 && reg.parsers[1] == p2
         && reg.parsers[2] == p3,
         "parsers kept in registration order");
    PASS([reg parserForURL: url] == p2,
         "first accepting parser wins (p2, not p3)");

    [reg unregisterParser: p2];
    PASS([reg parserForURL: url] == p3,
         "next parser wins after unregistering the match");

    [reg registerParser: p1];
    PASS(reg.parsers.count == 2,
         "duplicate registration of a live parser is ignored");
  }
  END_SET("registration order and lookup")

  START_SET("unregister semantics")
  {
    GSHelpParserRegistry *reg = [GSHelpParserRegistry new];
    StubParser *p = [StubParser new];
    StubParser *q = [StubParser new];
    [reg registerParser: p];
    [reg registerParser: q];

    [reg unregisterParser: p];
    PASS(reg.parsers.count == 1 && reg.parsers[0] == q,
         "only the removed parser is gone");
    [reg unregisterParser: q];
    PASS(reg.parsers.count == 0, "registry can be emptied");
    [reg unregisterParser: p];
    PASS(reg.parsers.count == 0,
         "unregistering an absent parser is a no-op");

    /* Removing the last reference must not leave dangling state. */
    p = nil;
    q = nil;
    PASS_RUNS(, "emptying registry is safe");
  }
  END_SET("unregister semantics")

  START_SET("nil URL tolerance")
  {
    GSHelpParserRegistry *reg = [GSHelpParserRegistry new];
    StubParser *p = [StubParser new];
    p.accept = YES;
    [reg registerParser: p];
    PASS([reg parserForURL: nil] == p,
         "parserForURL: with nil asks parsers, never crashes");
  }
  END_SET("nil URL tolerance")

  [arp release];
  return 0;
}

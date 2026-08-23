/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_Core_URL - help:// URL building, decomposition, round-trips and
 * malformed-input tolerance (nil/error, never crash). */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "GSHelpURL.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("building app URLs")
  {
    NSURL *u = [GSHelpURL appURLWithApplication: @"MyApplication"
                                       document: @"index"];
    PASS(u != nil, "app URL built");
    PASS_EQUAL([u absoluteString], @"help://app/MyApplication/index",
               "app URL spelling");
    PASS_EQUAL([u host], @"app", "kind is the host");

    PASS([GSHelpURL appURLWithApplication: nil
                                 document: @"index"] == nil,
         "nil application -> nil URL");
    PASS([GSHelpURL appURLWithApplication: @"App"
                                 document: @""] == nil,
         "empty document -> nil URL");
    PASS([GSHelpURL appURLWithApplication: @"a/b"
                                 document: @"c"] == nil,
         "slash in component rejected");
  }
  END_SET("building app URLs")

  START_SET("building man URLs")
  {
    NSURL *u = [GSHelpURL manURLWithCommand: @"ls" section: @"1"];
    PASS_EQUAL([u absoluteString], @"help://man/ls/1",
               "man URL spelling");

    PASS([GSHelpURL manURLWithCommand: @"ls" section: nil] == nil,
         "nil section -> nil URL");
    PASS([GSHelpURL manURLWithCommand: @"" section: @"1"] == nil,
         "empty command -> nil URL");
  }
  END_SET("building man URLs")

  START_SET("building gsdoc URLs")
  {
    NSURL *u = [GSHelpURL gsdocURLWithFramework: @"Foundation"
                                         symbol: @"NSString"];
    PASS_EQUAL([u absoluteString],
               @"help://gsdoc/Foundation/NSString",
               "gsdoc URL spelling");

    PASS([GSHelpURL gsdocURLWithFramework: @"F" symbol: @""] == nil,
         "empty symbol -> nil URL");
    PASS([GSHelpURL gsdocURLWithFramework: nil symbol: @"S"] == nil,
         "nil framework -> nil URL");
  }
  END_SET("building gsdoc URLs")

  START_SET("round-trips")
  {
    NSURL *a = [GSHelpURL appURLWithApplication: @"MyApp"
                                       document: @"getting-started"];
    PASS([GSHelpURL isHelpURL: a], "built URL is a help URL");
    PASS_EQUAL([GSHelpURL kindOfURL: a], @"app", "kind app");
    PASS_EQUAL([GSHelpURL applicationOfURL: a], @"MyApp",
               "application decomposed");
    PASS_EQUAL([GSHelpURL documentOfURL: a], @"getting-started",
               "document decomposed");
    PASS([GSHelpURL commandOfURL: a] == nil,
         "app URL has no command component");

    NSURL *m = [GSHelpURL manURLWithCommand: @"printf" section: @"3"];
    PASS_EQUAL([GSHelpURL kindOfURL: m], @"man", "kind man");
    PASS_EQUAL([GSHelpURL commandOfURL: m], @"printf",
               "command decomposed");
    PASS_EQUAL([GSHelpURL sectionOfURL: m], @"3", "section decomposed");
    PASS([GSHelpURL applicationOfURL: m] == nil,
         "man URL has no application component");

    NSURL *g = [GSHelpURL gsdocURLWithFramework: @"Foundation"
                                         symbol: @"NSString"];
    PASS_EQUAL([GSHelpURL frameworkOfURL: g], @"Foundation",
               "framework decomposed");
    PASS_EQUAL([GSHelpURL symbolOfURL: g], @"NSString",
               "symbol decomposed");

    NSURL *spaced =
        [GSHelpURL appURLWithApplication: @"My App"
                                document: @"my doc"];
    NSString *spacedDoc = [GSHelpURL documentOfURL: spaced];
    PASS(spaced != nil, "components with spaces are escaped");
    PASS_EQUAL(spacedDoc, @"my doc",
               "spaces survive the round-trip");
  }
  END_SET("round-trips")

  START_SET("malformed URLs")
  {
    NSURL *http = [NSURL URLWithString: @"http://example.com/x"];
    PASS(![GSHelpURL isHelpURL: http], "http URL is not a help URL");
    PASS([GSHelpURL kindOfURL: http] == nil,
         "non-help URL has no kind");

    NSURL *unknown = [NSURL URLWithString: @"help://wiki/Page"];
    PASS([GSHelpURL isHelpURL: unknown],
         "unknown kind still uses the help scheme");
    PASS([GSHelpURL kindOfURL: unknown] == nil,
         "unknown kind -> nil");
    PASS([GSHelpURL applicationOfURL: unknown] == nil,
         "unknown kind -> no components");

    NSURL *shortMan = [NSURL URLWithString: @"help://man/ls"];
    PASS([GSHelpURL sectionOfURL: shortMan] == nil,
         "missing section -> nil");
    PASS_EQUAL([GSHelpURL commandOfURL: shortMan], @"ls",
               "command still readable from incomplete man URL");

    NSURL *longApp = [NSURL URLWithString:
                          @"help://app/A/B/C"];
    PASS([GSHelpURL applicationOfURL: longApp] == nil,
         "too many path components -> nil application");
    PASS([GSHelpURL documentOfURL: longApp] == nil,
         "too many path components -> nil document");

    NSURL *trailing = [NSURL URLWithString: @"help://man/ls/1/"];
    PASS_EQUAL([GSHelpURL sectionOfURL: trailing], @"1",
               "trailing slash tolerated");

    /* Nil and unparseable input must never raise. */
    PASS(![GSHelpURL isHelpURL: nil], "nil URL is not a help URL");
    PASS([GSHelpURL kindOfURL: nil] == nil, "nil URL -> nil kind");
    PASS([GSHelpURL componentsOfURL: nil] == nil,
         "nil URL -> nil components");
    PASS([GSHelpURL symbolOfURL: nil] == nil,
         "nil URL -> nil symbol");
  }
  END_SET("malformed URLs")

  [arp release];
  return 0;
}

/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_Navigation_History - back/forward stack semantics (SPEC 44):
 * push clears the forward stack, goBack/goForward return nil at the
 * ends, canBack/canForward mirror the position. */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "GSHelpHistory.h"
#import "GSHelpURL.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  NSURL *a = [NSURL fileURLWithPath: @"/tmp/a.md"];
  NSURL *b = [NSURL fileURLWithPath: @"/tmp/b.md"];
  NSURL *c = [NSURL fileURLWithPath: @"/tmp/c.md"];

  START_SET("empty history")
  {
    GSHelpHistory *history = [GSHelpHistory new];

    PASS([history canBack] == NO, "fresh history cannot go back");
    PASS([history canForward] == NO,
         "fresh history cannot go forward");
    PASS([history goBack] == nil, "goBack on empty -> nil");
    PASS([history goForward] == nil, "goForward on empty -> nil");
    PASS([history currentURL] == nil,
         "empty history has no current URL");
  }
  END_SET("empty history")

  START_SET("pushing and going back")
  {
    GSHelpHistory *history = [GSHelpHistory new];
    [history pushURL: a];

    PASS([history canBack] == NO,
         "single entry cannot go back");
    PASS([history canForward] == NO,
         "single entry cannot go forward");
    PASS([[history currentURL] isEqual: a],
         "first pushed URL is current");

    [history pushURL: b];
    PASS([[history currentURL] isEqual: b],
         "second push becomes current");
    PASS([history canBack] == YES, "can go back after second push");
    PASS([history canForward] == NO,
         "still cannot go forward at the end");

    PASS([[history goBack] isEqual: a],
         "goBack returns the previous URL");
    PASS([[history currentURL] isEqual: a],
         "position moved back");
    PASS([history canBack] == NO, "back at the start");
    PASS([history goBack] == nil, "goBack past the start -> nil");
    PASS([history canForward] == YES,
         "forward available after going back");

    PASS([[history goForward] isEqual: b],
         "goForward returns the URL left behind");
    PASS([[history currentURL] isEqual: b], "position moved forward");
    PASS([history goForward] == nil, "goForward past the end -> nil");
  }
  END_SET("pushing and going back")

  START_SET("push clears forward stack")
  {
    GSHelpHistory *history = [GSHelpHistory new];
    [history pushURL: a];
    [history pushURL: b];
    PASS([history goBack] != nil, "stepped back");

    [history pushURL: c];
    PASS([history canForward] == NO,
         "pushing after back-navigation drops the forward branch");
    PASS([history goForward] == nil,
         "no URL behind the dropped branch");
    PASS([[history currentURL] isEqual: c],
         "newly pushed URL is current");
    PASS([history canBack] == YES,
         "older branch still reachable backwards");
    PASS([[history goBack] isEqual: a],
         "back leads along the kept branch");
  }
  END_SET("push clears forward stack")

  START_SET("tolerated input")
  {
    GSHelpHistory *history = [GSHelpHistory new];
    PASS_RUNS([history pushURL: nil], "nil push does not raise");
    PASS([history currentURL] == nil,
         "nil push leaves history empty");

    /* help:// URLs are first-class history citizens alongside
     * file URLs. */
    NSURL *man = [GSHelpURL manURLWithCommand: @"ls" section: @"1"];
    [history pushURL: man];
    PASS_EQUAL([history currentURL], man,
               "internal help URL stored verbatim");
  }
  END_SET("tolerated input")

  [arp release];
  return 0;
}

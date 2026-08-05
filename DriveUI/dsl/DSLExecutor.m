/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Executor for the GNUstep UI Automation DSL (see DSL.h / Executor.md).
 *
 * Walks DSLProgram.commands sequentially, translating each DSLCommand into a
 * semantic query on the DSLQueryEngine.  Contains no GNUstep-specific logic;
 * all accessibility lives in the engine.  Implements the on_error policy and
 * produces a per-command timed log (Executor.md sections 15/19).
 *
 * Durations ("100ms", "2s", "5m") are parsed here to seconds.
 */

#import "DSL.h"

@implementation DSLExecutor

- (id)initWithProgram:(DSLProgram *)program engine:(DSLQueryEngine *)engine
{
  if ((self = [super init]))
    {
      program_ = [program retain];
      engine_ = [engine retain];
      policy_ = @"stop";
      retryCount_ = 0;
      log_ = [[NSMutableString alloc] init];
    }
  return self;
}
- (void)dealloc
{
  [program_ release];
  [engine_ release];
  [policy_ release];
  [log_ release];
  [super dealloc];
}
- (NSString *)log { return log_; }

/* Parse a duration "100ms"/"2s"/"5m" to seconds. */
+ (double)durationForString:(NSString *)s
{
  if (!s) return 0;
  if ([s hasSuffix: @"ms"]) return [[s substringToIndex: [s length] - 2] doubleValue] / 1000.0;
  if ([s hasSuffix: @"s"])  return [[s substringToIndex: [s length] - 1] doubleValue];
  if ([s hasSuffix: @"m"])  return [[s substringToIndex: [s length] - 1] doubleValue] * 60.0;
  return [s doubleValue];
}

static void SleepSeconds(double sec)
{
  if (sec <= 0) return;
  struct timespec ts;
  ts.tv_sec = (time_t)sec;
  ts.tv_nsec = (long)((sec - (double)ts.tv_sec) * 1e9);
  nanosleep(&ts, NULL);
}

static NSString *CommandName(DSLCommandType t)
{
  switch (t)
    {
      case DDSCmdActivate:    return @"activate application";
      case DDSCmdFocusWindow: return @"focus window";
      case DDSCmdSelectMenu:  return @"select menu";
      case DDSCmdClick:       return @"click";
      case DDSCmdDoubleClick: return @"doubleclick";
      case DDSCmdRightClick:  return @"rightclick";
      case DDSCmdType:        return @"type";
      case DDSCmdClear:       return @"clear";
      case DDSCmdPress:       return @"press";
      case DDSCmdWait:        return @"wait";
      case DDSCmdWaitUntil:   return @"wait until";
      case DDSCmdAssert:      return @"assert";
      case DDSCmdCapture:     return @"capture screenshot";
      case DDSCmdLog:         return @"log";
      case DDSCmdOptions:     return @"on_error";
      default:                return @"?";
    }
}

- (NSString *)formatCommand:(DSLCommand *)cmd
{
  NSMutableString *s = [NSMutableString stringWithString: CommandName(cmd.type)];
  if ((cmd.type == DDSCmdClick || cmd.type == DDSCmdDoubleClick ||
       cmd.type == DDSCmdRightClick || cmd.type == DDSCmdClear) &&
      cmd.role != DDSRoleAny)
    {
      [s appendFormat: @" %@", [[DSLRoleClassName(cmd.role) lowercaseString]
        stringByReplacingOccurrencesOfString: @"ns" withString: @"ns"]];
    }
  if (cmd.string) [s appendFormat: @" \"%@\"", cmd.string];
  return s;
}

/* Execute one command.  On success returns 0; otherwise an exit code and
 * reason.  This is the Executor.md "execute(node)" step. */
- (int)execute:(DSLCommand *)cmd reason:(NSString **)reason
{
  NSString *err = nil;
  NSDate *start = nil;
  int rc = 0;

  /* free-form duration timeout for wait-until is carried in words[1] */
  double cTimeout = 30.0;
  if (cmd.type == DDSCmdWaitUntil && [[cmd words] count] > 1)
    {
      NSString *durTok = [[cmd words] objectAtIndex: 1];
      cTimeout = [durTok doubleValue];
    }
  (void)cTimeout;

  start = [NSDate date];
  switch (cmd.type)
    {
    case DDSCmdActivate:
      if ([engine_ resolveApplication: cmd.string error: &err] &&
          [engine_ activate: &err]) rc = 0;
      else rc = DDSAccessibilityError;
      break;
    case DDSCmdFocusWindow:
      if ([engine_ pid] == 0)
        rc = ([engine_ resolveApplication: cmd.string error: &err])
          ? 0 : DDSAccessibilityError;
      else rc = ([engine_ focusMainWindow: &err]) ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdSelectMenu:
      if (!cmd.string) { err = @"select menu needs a path (use \"Top/Sub\")"; rc = 1; break; }
      rc = ([engine_ selectMenuPath: cmd.string error: &err])
        ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdClick:
    case DDSCmdDoubleClick:
    case DDSCmdRightClick:
      {
        int btn = (cmd.type == DDSCmdRightClick) ? 3 : 1;
        int cnt = (cmd.type == DDSCmdDoubleClick) ? 2 : 1;
        rc = [engine_ clickRole: cmd.role title: cmd.string button: btn
          count: cnt error: &err] ? 0 : DDSAccessibilityError;
      }
      break;
    case DDSCmdType:
      rc = [engine_ type: cmd.string error: &err] ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdClear:
      rc = [engine_ clearRole: cmd.role title: cmd.string error: &err]
        ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdPress:
      rc = [engine_ pressKeyCombo: cmd.string error: &err] ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdWait:
      SleepSeconds([DSLExecutor durationForString: cmd.string]);
      rc = 0;
      break;
    case DDSCmdWaitUntil:
      {
        double to = cTimeout;
        BOOL ok = NO;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: to];
        /* positive: wait until the widget exists; negative (assertKind
         * NotExists): wait until it disappears. */
        while ([[NSDate date] compare: deadline] == NSOrderedAscending)
          {
            BOOL present = [engine_ doesWidgetExist: cmd.role title: cmd.string
              contains: nil error: &err];
            ok = (cmd.assertKind == DDSAssertNotExists) ? !present : present;
            if (ok) break;
            usleep(100000);
          }
        rc = ok ? 0 : DDSTimeout;
        if (!ok) err = @"timed out waiting for condition";
      }
      break;
    case DDSCmdAssert:
      if ([engine_ pid] == 0) { err = @"assert needs a target application"; rc = 2; break; }
      rc = [engine_ assertRole: cmd.role title: cmd.string kind: cmd.assertKind
        needle: cmd.string error: &err] ? 0 : DDSAssertFailed;
      break;
    case DDSCmdCapture:
      {
        NSString *outPath = nil;
        rc = [engine_ captureScreenshotToPath: cmd.string outPath: &outPath
          error: &err] ? 0 : DDSAccessibilityError;
        if (rc == 0 && outPath)
          fprintf(stderr, "[dsl] screenshot saved to %s\n", [outPath UTF8String]);
      }
      break;
    case DDSCmdLog:
      fprintf(stderr, "[dsl] %s\n", [cmd.string ?: @"" UTF8String]);
      rc = 0;
      break;
    case DDSCmdOptions:
      if ([[cmd words] count] > 0)
        policy_ = [[cmd words] objectAtIndex: 0];
      retryCount_ = 0;
      if ([[cmd words] count] > 1)
        retryCount_ = [[[cmd words] objectAtIndex: 1] intValue];
      rc = 0;
      break;
    default:
      rc = 1;
      err = @"unhandled command";
    }

  double ms = -[start timeIntervalSinceNow] * 1000.0;
  if ([log_ length]) [log_ appendString: @"\n"];
  if (rc == 0)
    [log_ appendFormat: @"%.3f %@\n  SUCCESS  %.0f ms", ms / 1000.0,
      [self formatCommand: cmd], ms];
  else
    [log_ appendFormat: @"%.3f %@\n  %@  %.0f ms", ms / 1000.0,
      [self formatCommand: cmd], err ?: @"runtime error", ms];
  if (reason) *reason = err;
  return rc;
}

/* Walk the AST, applying the error policy.  (Executor.md section 15.) */
- (int)run
{
  int rc = 0;
  int retries = 0;
  for (DSLCommand *cmd in program_.commands)
    {
      NSString *reason = nil;
      rc = [self execute: cmd reason: &reason];
      if (rc != 0)
        {
          if ([policy_ caseInsensitiveCompare: @"continue"] == NSOrderedSame)
            continue;
          else if ([policy_ caseInsensitiveCompare: @"retry"] == NSOrderedSame &&
                   retries < retryCount_)
            {
              retries++;
              /* re-run the failed command */
              rc = [self execute: cmd reason: &reason];
              if (rc == 0) { retries = 0; continue; }
              return rc;
            }
          return rc;  /* stop (default) */
        }
      retries = 0;
    }
  return 0;
}

@end
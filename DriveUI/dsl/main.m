/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * drive_script - command-line runner for the GNUstep UI Automation DSL.
 *
 * Usage: drive_script [--drive-ui /path/to/drive_ui] script.dsl
 *
 * Parses the script into a DSLProgram, hands it to the DSLExecutor, and exits
 * with the DSL exit-code convention (see Executor.md section 20).
 */

#import <Foundation/Foundation.h>
#import "DSL.h"

int main(int argc, const char *argv[])
{
  setenv("GNUSTEP_SYSTEM_ROOT", "/System", 1);
  setenv("GNUSTEP_LOCAL_ROOT", "/Local", 1);
  setenv("GNUSTEP_NETWORK_ROOT", "/Network", 1);
  setenv("GNUSTEP_USER_ROOT", "/Local/Users/admin/.GNUstep", 1);
  setbuf(stdout, NULL);

  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  NSString *driveTool = @"/System/Library/Tools/drive_ui";
  NSString *script = nil;
  for (int i = 1; i < argc; i++)
    {
      NSString *a = [NSString stringWithUTF8String: argv[i]];
      if ([a isEqualToString: @"--drive-tool"] && i + 1 < argc)
        driveTool = [NSString stringWithUTF8String: argv[++i]];
      else if ([a hasSuffix: @".dsl"] || script == nil)
        script = a;
    }

  if (!script)
    {
      fprintf(stderr, "Usage: drive_script [--drive-tool /path/to/drive_ui] script.dsl\n");
      [pool release];
      return DDSParseError;
    }

  DSLParser *parser = [[[DSLParser alloc] init] autorelease];
  NSString *err = nil;
  DSLProgram *prog = [parser parseFile: script error: &err];
  if (!prog)
    {
      fprintf(stderr, "drive_script: %s\n", [err UTF8String]);
      [pool release];
      return DDSParseError;
    }

  DSLQueryEngine *engine = [[[DSLQueryEngine alloc] initWithDriveTool: driveTool]
    autorelease];
  DSLExecutor *exec = [[[DSLExecutor alloc] initWithProgram: prog engine: engine]
    autorelease];
  int rc = [exec run];

  /* the executor logs failures to stderr; echo nothing on success */
  [pool release];
  return rc;
}
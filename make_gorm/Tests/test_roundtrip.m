/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <sys/wait.h>
#import "Testing.h"

static int
run_cmd(NSString *cmd)
{
  return WEXITSTATUS(system([cmd UTF8String]));
}

int
main()
{
  CREATE_AUTORELEASE_POOL(pool);
  NSString *tool = @"../obj/make_gorm";
  NSString *finder =
    @"/System/Applications/Workspace.app/Resources/English.lproj/Finder.gorm";
  NSString *terminal =
    @"/System/Applications/Terminal.app/Resources/English.lproj/Terminal.gorm";


  START_SET("roundtrip - Finder.gorm decompile->compile->decompile")
  {
    NSString *t1 = @"/tmp/_test_rt_f1.gormt";
    NSString *b1 = @"/tmp/_test_rt_f.gorm";
    NSString *t2 = @"/tmp/_test_rt_f2.gormt";
    int status;

    status = run_cmd([NSString stringWithFormat:
      @"%@ decompile \"%@\" \"%@\" >/dev/null 2>&1", tool, finder, t1]);
    PASS(status == 0, "first decompile succeeds");
    status = run_cmd([NSString stringWithFormat:
      @"%@ compile \"%@\" \"%@\" >/dev/null 2>&1", tool, t1, b1]);
    PASS(status == 0, "compile succeeds");
    status = run_cmd([NSString stringWithFormat:
      @"%@ decompile \"%@\" \"%@\" >/dev/null 2>&1", tool, b1, t2]);
    PASS(status == 0, "second decompile succeeds");

    NSString *text1 = [NSString stringWithContentsOfFile:t1
      encoding:NSUTF8StringEncoding error:NULL];
    NSString *text2 = [NSString stringWithContentsOfFile:t2
      encoding:NSUTF8StringEncoding error:NULL];
    PASS(text1 != nil, "first decompiled text is valid UTF-8");
    PASS(text2 != nil, "second decompiled text is valid UTF-8");
    PASS([text1 isEqualToString:text2],
      "decompiled text is identical after round-trip");
  }
  END_SET("roundtrip - Finder.gorm decompile->compile->decompile");

  START_SET("roundtrip - Terminal.gorm decompile->compile->decompile")
  {
    NSString *t1 = @"/tmp/_test_rt_t1.gormt";
    NSString *b1 = @"/tmp/_test_rt_t.gorm";
    NSString *t2 = @"/tmp/_test_rt_t2.gormt";
    int status;

    status = run_cmd([NSString stringWithFormat:
      @"%@ decompile \"%@\" \"%@\" >/dev/null 2>&1", tool, terminal, t1]);
    PASS(status == 0, "first decompile succeeds");
    status = run_cmd([NSString stringWithFormat:
      @"%@ compile \"%@\" \"%@\" >/dev/null 2>&1", tool, t1, b1]);
    PASS(status == 0, "compile succeeds");
    status = run_cmd([NSString stringWithFormat:
      @"%@ decompile \"%@\" \"%@\" >/dev/null 2>&1", tool, b1, t2]);
    PASS(status == 0, "second decompile succeeds");

    NSString *text1 = [NSString stringWithContentsOfFile:t1
      encoding:NSUTF8StringEncoding error:NULL];
    NSString *text2 = [NSString stringWithContentsOfFile:t2
      encoding:NSUTF8StringEncoding error:NULL];
    PASS(text1 != nil, "first decompiled text is valid UTF-8");
    PASS(text2 != nil, "second decompiled text is valid UTF-8");
    PASS([text1 isEqualToString:text2],
      "decompiled text is identical after round-trip");
  }
  END_SET("roundtrip - Terminal.gorm decompile->compile->decompile");

  START_SET("error handling - invalid inputs rejected")
  {
    int status;

    status = run_cmd([NSString stringWithFormat:
      @"%@ verify /nonexistent/path.gorm >/dev/null 2>&1", tool]);
    PASS(status != 0, "verify rejects nonexistent path");

    status = run_cmd([NSString stringWithFormat:
      @"%@ verify \"/tmp\" >/dev/null 2>&1", tool]);
    PASS(status != 0, "verify rejects directory without objects.gorm");

    status = run_cmd([NSString stringWithFormat:
      @"%@ decompile \"/nonexistent/file.gorm\" /tmp/_test_err.gormt >/dev/null 2>&1", tool]);
    PASS(status != 0, "decompile rejects nonexistent input");

    status = run_cmd([NSString stringWithFormat:
      @"%@ compile \"/nonexistent/file.gormt\" /tmp/_test_err.gorm >/dev/null 2>&1", tool]);
    PASS(status != 0, "compile rejects nonexistent input");

    status = run_cmd([NSString stringWithFormat:
      @"%@ unknown_command >/dev/null 2>&1", tool]);
    PASS(status != 0, "unknown subcommand rejected");

    status = run_cmd([NSString stringWithFormat:
      @"%@ verify \"/tmp/_test_err.gorm\" >/dev/null 2>&1", tool]);
    PASS(status != 0, "verify rejects non-gorm file");
  }
  END_SET("error handling - invalid inputs rejected");

  START_SET("roundtrip - class names preserved")
  {
    NSString *text = [NSString stringWithContentsOfFile:
      @"/tmp/_test_rt_f2.gormt" encoding:NSUTF8StringEncoding error:NULL];
    PASS(text != nil, "Finder round-trip text is readable");
    PASS([text rangeOfString:@"GSNibContainer"].length > 0,
      "class name GSNibContainer preserved in output");

  }
  END_SET("roundtrip - class names preserved");

  START_SET("roundtrip - 10-cycle stability")
  {
    NSString *binPath = finder;
    int status;
    NSString *prevText = nil;

    for (int i = 0; i < 10; i++)
      {
        NSString *textPath =
          [NSString stringWithFormat:@"/tmp/_test_rt_stable_%d.gormt", i];
        NSString *nextBin =
          [NSString stringWithFormat:@"/tmp/_test_rt_stable_%d.gorm", i];

        status = run_cmd([NSString stringWithFormat:
          @"%@ decompile \"%@\" \"%@\" >/dev/null 2>&1",
          tool, binPath, textPath]);
        PASS(status == 0, "cycle %d: decompile succeeds", i);

        NSString *curText = [NSString stringWithContentsOfFile:textPath
          encoding:NSUTF8StringEncoding error:NULL];
        PASS(curText != nil, "cycle %d: decompiled text is valid UTF-8", i);

        if (prevText != nil)
          {
            PASS([curText isEqualToString:prevText],
              "cycle %d: text is stable (matches previous)", i);
          }

        prevText = curText;

        status = run_cmd([NSString stringWithFormat:
          @"%@ compile \"%@\" \"%@\" >/dev/null 2>&1",
          tool, textPath, nextBin]);
        PASS(status == 0, "cycle %d: compile succeeds", i);

        binPath = nextBin;
      }
  }
  END_SET("roundtrip - 10-cycle stability");

  [pool drain];
  return 0;
}

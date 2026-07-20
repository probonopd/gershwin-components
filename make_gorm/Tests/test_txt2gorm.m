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
  NSString *tmpText = @"/tmp/_test_t2g_text.gormt";
  NSString *tmpGorm = @"/tmp/_test_t2g_binary.gorm";
  NSFileManager *fm = [NSFileManager defaultManager];

  START_SET("txt2gorm - compile text to binary (Finder.gorm)")
  {
    int status;

    PASS([fm fileExistsAtPath:finder],
      "Finder.gorm exists");
    status = run_cmd([NSString stringWithFormat:
      @"%@ decompile \"%@\" \"%@\" >/dev/null 2>&1", tool, finder, tmpText]);
    PASS(status == 0, "decompile Finder.gorm to text");

    status = run_cmd([NSString stringWithFormat:
      @"%@ compile \"%@\" \"%@\" >/dev/null 2>&1", tool, tmpText, tmpGorm]);
    PASS(status == 0, "compile text to binary");

    BOOL isDir = NO;
    PASS([fm fileExistsAtPath:tmpGorm isDirectory:&isDir] && isDir,
      "compiled output is a bundle directory");
    PASS([fm fileExistsAtPath:
      [tmpGorm stringByAppendingPathComponent:@"objects.gorm"]],
      "compiled bundle contains objects.gorm");
    PASS([fm fileExistsAtPath:
      [tmpGorm stringByAppendingPathComponent:@"data.classes"]],
      "compiled bundle contains data.classes");
    PASS([fm fileExistsAtPath:
      [tmpGorm stringByAppendingPathComponent:@"data.info"]],
      "compiled bundle contains data.info");

    NSData *binary = [NSData dataWithContentsOfFile:
      [tmpGorm stringByAppendingPathComponent:@"objects.gorm"]];
    PASS(binary != nil, "objects.gorm is readable");

    NSString *magic = [[[NSString alloc] initWithData:
      [binary subdataWithRange:NSMakeRange(0, 15)]
      encoding:NSASCIIStringEncoding] autorelease];
    PASS([magic isEqualToString:@"GNUstep archive"],
      "binary starts with 'GNUstep archive' magic");

    status = run_cmd([NSString stringWithFormat:
      @"%@ verify \"%@\" >/dev/null 2>&1", tool, tmpGorm]);
    PASS(status == 0, "compiled output passes verify");

    PASS([binary length] > 0,
      "compiled binary is non-empty (%lu bytes)",
      (unsigned long)[binary length]);
  }
  END_SET("txt2gorm - compile text to binary (Finder.gorm)");

  START_SET("txt2gorm - compile text to binary (Terminal.gorm)")
  {
    int status;

    PASS([fm fileExistsAtPath:terminal],
      "Terminal.gorm exists");
    status = run_cmd([NSString stringWithFormat:
      @"%@ decompile \"%@\" \"%@\" >/dev/null 2>&1",
      tool, terminal, tmpText]);
    PASS(status == 0, "decompile Terminal.gorm to text");

    status = run_cmd([NSString stringWithFormat:
      @"%@ compile \"%@\" \"%@\" >/dev/null 2>&1",
      tool, tmpText, tmpGorm]);
    PASS(status == 0, "compile text to binary");

    BOOL isDir = NO;
    PASS([fm fileExistsAtPath:tmpGorm isDirectory:&isDir] && isDir,
      "compiled output is a bundle directory");
    PASS([fm fileExistsAtPath:
      [tmpGorm stringByAppendingPathComponent:@"objects.gorm"]],
      "compiled bundle contains objects.gorm");

    NSData *binary = [NSData dataWithContentsOfFile:
      [tmpGorm stringByAppendingPathComponent:@"objects.gorm"]];
    PASS(binary != nil, "objects.gorm is readable");

    NSString *magic = [[[NSString alloc] initWithData:
      [binary subdataWithRange:NSMakeRange(0, 15)]
      encoding:NSASCIIStringEncoding] autorelease];
    PASS([magic isEqualToString:@"GNUstep archive"],
      "binary starts with 'GNUstep archive' magic");

    status = run_cmd([NSString stringWithFormat:
      @"%@ verify \"%@\" >/dev/null 2>&1", tool, tmpGorm]);
    PASS(status == 0, "compiled output passes verify");
  }
  END_SET("txt2gorm - compile text to binary (Terminal.gorm)");

  [pool drain];
  return 0;
}

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
  NSString *tmp = @"/tmp/_test_decompile.gormt";

  START_SET("gorm2txt - decompile binary to text")
  {
    NSFileManager *fm = [NSFileManager defaultManager];
    int status;

    PASS([fm fileExistsAtPath:finder],
      "Finder.gorm exists at %s", [finder UTF8String]);
    PASS([[NSData dataWithContentsOfFile:
      [finder stringByAppendingPathComponent:@"objects.gorm"]] length] > 0,
      "Finder.gorm/objects.gorm is non-empty");

    status = run_cmd([NSString stringWithFormat:
      @"%@ verify \"%@\" >/dev/null 2>&1", tool, finder]);
    PASS(status == 0, "make_gorm verify succeeds on Finder.gorm");

    status = run_cmd([NSString stringWithFormat:
      @"%@ decompile \"%@\" \"%@\" >/dev/null 2>&1", tool, finder, tmp]);
    PASS(status == 0, "make_gorm decompile succeeds on Finder.gorm");

    PASS([fm fileExistsAtPath:tmp],
      "decompiled file exists at %s", [tmp UTF8String]);

    NSString *content = [NSString stringWithContentsOfFile:tmp
      encoding:NSUTF8StringEncoding error:NULL];
    PASS(content != nil, "decompiled output is valid UTF-8");

    PASS([content hasPrefix:@"gorm-text 1"],
      "output starts with 'gorm-text 1'");

    PASS([content rangeOfString:@"object "].length > 0,
      "output contains 'object ' marker");
    PASS([content rangeOfString:@"class = "].length > 0,
      "output contains 'class = ' marker");
    PASS([content rangeOfString:@"<data>"].length > 0,
      "output contains '<data>' marker");

    // Count top-level objects (sub-objects are in the root's raw data)
    int objCount = 0;
    NSArray *lines = [content componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
      if ([line hasPrefix:@"object "]) objCount++;
    }
    PASS(objCount == 1, "output has %d top-level object definition(s)", objCount);

    // Verify <data> block contains hex-encoded class names from sub-objects
    NSString *hexClass = @"475357696E646F7754656D706C617465"; // GSWindowTemplate
    PASS([content rangeOfString:hexClass].length > 0,
         "hex-encoded class name GSWindowTemplate found in data");
  }
  END_SET("gorm2txt - decompile binary to text");

  [pool drain];
  return 0;
}

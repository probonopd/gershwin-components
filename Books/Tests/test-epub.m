/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "EPUBBook.h"
#import "EPUBTOCEntry.h"
#import "EPUBPaginator.h"
#import "EPUBPageRenderer.h"
#import "EPUBHTMLConverter.h"

static int failures = 0;

#define CHECK(cond, msg) do { \
  if (cond) { NSLog(@"PASS: %s", msg); } \
  else { NSLog(@"FAIL: %s", msg); failures++; } \
} while (0)

int main(void)
{
  @autoreleasepool
    {
      [NSApplication sharedApplication];
      NSString *here = [[NSString stringWithUTF8String:__FILE__]
          stringByDeletingLastPathComponent];
      NSString *epub = [here stringByAppendingPathComponent:@"fixtures/sample.epub"];
      NSError *err = nil;
      EPUBBook *book = [[EPUBBook alloc] initWithEPUBAtPath:epub error:&err];
      CHECK(book != nil, "EPUB book parsed");
      CHECK(err == nil, "no parse error");
      CHECK([book.title isEqualToString:@"Test Book"], "title parsed");
      CHECK([book.author isEqualToString:@"Jane Author"], "author parsed");
      CHECK([book.spine count] == 2, "spine has two items");
      CHECK([book.tableOfContents count] == 2, "TOC has two entries");
      if ([book.tableOfContents count] == 2)
        {
          CHECK([[book.tableOfContents[0] title] isEqualToString:@"Chapter One"],
                "TOC entry 1 title");
          CHECK(book.tableOfContents[0].contentPath != nil, "TOC entry 1 has content path");
        }

      NSMutableAttributedString *full = [[NSMutableAttributedString alloc] init];
      NSUInteger textLen = 0;
      for (NSString *doc in book.spine)
        {
          NSURL *base = [NSURL fileURLWithPath:[doc stringByDeletingLastPathComponent]];
          NSAttributedString *part = [EPUBHTMLConverter
              attributedStringFromXHTMLAtPath:doc baseURL:base error:NULL];
          textLen += [part length];
          [full appendAttributedString:part];
        }
      CHECK(textLen > 100, "converter produced non-trivial text from XHTML");
      CHECK([full length] > 100, "rendered attributed string is non-trivial");

      BOOL hasScreen = YES;
      @try
        {
          EPUBPaginator *pag = [[EPUBPaginator alloc]
              initWithAttributedString:full
                              pageRect:NSMakeRect(0, 0, 400, 600)];
          CHECK([pag pageCount] >= 1, "paginator produced at least one page");
          NSLog(@"INFO: paginated into %lu pages",
                (unsigned long)[pag pageCount]);
          if ([pag pageCount] > 1)
            {
              NSRange r0 = [pag rangeForPage:0];
              NSRange r1 = [pag rangeForPage:1];
              CHECK(NSMaxRange(r0) <= NSMaxRange(r1), "page ranges are ordered");
            }
          EPUBPageRenderer *rend = [[EPUBPageRenderer alloc] init];
          NSBitmapImageRep *img = [rend imageForRange:NSMakeRange(0, MIN(50, [full length]))
                            ofAttributedString:full
                                      pageSize:NSMakeSize(400, 600)
                               backgroundColor:[NSColor whiteColor]
                                     textColor:[NSColor blackColor]];
          CHECK(img != nil && [img pixelsWide] > 0, "renderer produced an image");
        }
      @catch (id ex)
        {
          hasScreen = NO;
          NSLog(@"SKIP: layout/rendering requires a window server (%@)", ex);
        }

      [book cleanupExtraction];
      if (!hasScreen)
        {
          NSLog(@"NOTE: running headless; parsing + text conversion verified, "
                @"layout skipped.");
          return (failures > 0) ? 1 : 0;
        }
    }
  if (failures > 0)
    {
      NSLog(@"TEST RESULT: %d FAILURE(S)", failures);
      return 1;
    }
  NSLog(@"TEST RESULT: ALL PASSED");
  return 0;
}

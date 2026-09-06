/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_Text_Detector - GSHelpFormatDetector: SPEC 10 detection priority
 * (hint > bundle metadata > extension > content sniffing > text),
 * magic bytes, and extension-vs-content conflicts. */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "GSHelpFormatDetector.h"

static NSString *fixtureDir(void)
{
  return [NSString stringWithFormat:
            @"/tmp/opencode/gshelp_detect_%d", getpid()];
}

static NSURL *writeFixture(NSString *name, NSString *content)
{
  NSString *dir = fixtureDir();
  [[NSFileManager defaultManager] createDirectoryAtPath: dir
      withIntermediateDirectories: YES attributes: nil error: NULL];
  NSString *path = [dir stringByAppendingPathComponent: name];
  [content writeToFile: path atomically: YES
              encoding: NSUTF8StringEncoding error: NULL];
  return [NSURL fileURLWithPath: path];
}

static NSURL *writeBinaryFixture(NSString *name, NSData *data)
{
  NSString *dir = fixtureDir();
  [[NSFileManager defaultManager] createDirectoryAtPath: dir
      withIntermediateDirectories: YES attributes: nil error: NULL];
  NSString *path = [dir stringByAppendingPathComponent: name];
  [data writeToFile: path atomically: YES];
  return [NSURL fileURLWithPath: path];
}

static void cleanupFixtures(void)
{
  [[NSFileManager defaultManager] removeItemAtPath: fixtureDir() error: NULL];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("format constants")
  {
    PASS_EQUAL(GSHelpFormatMarkdown, @"GSHelpFormatMarkdown",
               "markdown constant");
    PASS_EQUAL(GSHelpFormatMan, @"GSHelpFormatMan", "man constant");
    PASS_EQUAL(GSHelpFormatGSDoc, @"GSHelpFormatGSDoc", "gsdoc constant");
    PASS_EQUAL(GSHelpFormatText, @"GSHelpFormatText", "text constant");
  }
  END_SET("format constants")

  START_SET("extension detection")
  {
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL:
                  [NSURL fileURLWithPath: @"/docs/README.md"]],
               GSHelpFormatMarkdown, ".md -> markdown");
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL:
                  [NSURL fileURLWithPath: @"/docs/README.markdown"]],
               GSHelpFormatMarkdown, ".markdown -> markdown");
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL:
                  [NSURL fileURLWithPath: @"/man/foo.1"]],
               GSHelpFormatMan, ".1 -> man");
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL:
                  [NSURL fileURLWithPath: @"/man/foo.3ssl"]],
               GSHelpFormatMan, ".3ssl -> man");
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL:
                  [NSURL fileURLWithPath: @"/man/foo.1.gz"]],
               GSHelpFormatMan, ".1.gz -> man");
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL:
                  [NSURL fileURLWithPath: @"/man/foo.8.bz2"]],
               GSHelpFormatMan, ".8.bz2 -> man");
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL:
                  [NSURL fileURLWithPath: @"/man/foo.6.xz"]],
               GSHelpFormatMan, ".6.xz -> man");
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL:
                  [NSURL fileURLWithPath: @"/api/Foo.gsdoc"]],
               GSHelpFormatGSDoc, ".gsdoc -> gsdoc");
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL:
                  [NSURL fileURLWithPath: @"/notes/todo.txt"]],
               GSHelpFormatText, ".txt -> text");
  }
  END_SET("extension detection")

  START_SET("content sniffing")
  {
    NSURL *gz = writeBinaryFixture(@"page.gz",
      [NSData dataWithBytes: "\x1f\x8b\x08\x00" length: 4]);
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL: gz],
               GSHelpFormatMan, "gzip magic detected");

    NSURL *bz2 = writeBinaryFixture(@"archive.bz2",
      [NSData dataWithBytes: "BZh9" length: 4]);
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL: bz2],
               GSHelpFormatMan, "bzip2 magic detected");

    char xzMagic[6] = { '\xfd', '7', 'z', 'X', 'Z', '\x00' };
    NSURL *xz = writeBinaryFixture(@"stream.xz",
      [NSData dataWithBytes: xzMagic length: 6]);
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL: xz],
               GSHelpFormatMan, "xz magic detected");

    NSURL *roff = writeFixture(@"unknownfile",
                               @".TH LS 1 \"2024-01-01\"\n.SH NAME\nls\n");
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL: roff],
               GSHelpFormatMan, ".TH line detected");

    NSURL *roffComment = writeFixture(@"mystery2", @"'\\\" t\n.TH TROFF 1\n");
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL: roffComment],
               GSHelpFormatMan, "roff comment line detected");

    NSURL *mdSniff = writeFixture(@"INSTALLNOTES",
                                  @"Some intro text.\n\n# Getting Started\n\nBody.\n");
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL: mdSniff],
               GSHelpFormatMarkdown, "ATX heading near top detected");

    NSURL *gsdocSniff = writeFixture(@"apiref",
      @"<?xml version=\"1.0\"?>\n<gsdoc><class name=\"Foo\"/></gsdoc>\n");
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL: gsdocSniff],
               GSHelpFormatGSDoc, "XML with gsdoc root detected");

    NSURL *plain = writeFixture(@"nothing_special",
                                @"just some ordinary words\nover two lines\n");
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL: plain],
               GSHelpFormatText, "no signals fall back to text");
  }
  END_SET("content sniffing")

  START_SET("extension wins over content")
  {
    /* roff content behind a .md name: extension is checked first. */
    NSURL *mdNameRoffContent =
        writeFixture(@"looks_roff.md", @".TH NOTMARKDOWN 1\n.SH NAME\nx\n");
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL: mdNameRoffContent],
               GSHelpFormatMarkdown, ".md extension beats roff content");

    /* markdown content behind a man-section name. */
    NSURL *manNameMdContent =
        writeFixture(@"actually_md.7", @"# Not A Man Page\n\nText.\n");
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL: manNameMdContent],
               GSHelpFormatMan, "man extension beats markdown content");

    /* gzip magic behind a .txt name. */
    NSURL *txtNameGzipContent = writeBinaryFixture(@"packed.txt",
      [NSData dataWithBytes: "\x1f\x8b\x08\x00" length: 4]);
    PASS_EQUAL(
      [GSHelpFormatDetector detectFormatForURL: txtNameGzipContent],
      GSHelpFormatText, ".txt extension beats gzip magic");
  }
  END_SET("extension wins over content")

  START_SET("explicit format hint has top priority")
  {
    NSURL *url = [NSURL fileURLWithPath: @"/man/definitely_man.3"];
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL: url
                                             formatHint: GSHelpFormatMarkdown],
               GSHelpFormatMarkdown, "hint overrides the extension");

    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL: url
                                             formatHint: @"text"],
               GSHelpFormatText, "hint accepted by short name too");

    /* Unknown hints are ignored so detection continues normally. */
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL: url
                                             formatHint: @"rtfd"],
               GSHelpFormatMan, "unknown hint falls through to extension");
  }
  END_SET("explicit format hint has top priority")

  START_SET("bundle metadata hook")
  {
    NSURL *readme = [NSURL fileURLWithPath: @"/app/Resources/Help/README"];

    NSDictionary *plist =
        @{ @"FileFormats": @{ @"README": GSHelpFormatMarkdown } };
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL: readme
                                                formatHint: nil
                                            bundleMetadata: plist],
               GSHelpFormatMarkdown,
               "FileFormats entry maps README to markdown");

    NSDictionary *irrelevantPlist =
        @{ @"FileFormats": @{ @"OTHER": GSHelpFormatMarkdown } };
    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL: readme
                                                formatHint: nil
                                            bundleMetadata: irrelevantPlist],
               GSHelpFormatText,
               "unlisted files keep falling through to text");

    PASS_EQUAL([GSHelpFormatDetector detectFormatForURL:
                  [NSURL fileURLWithPath: @"/man/ls.1"]
                                                  formatHint: nil
                                              bundleMetadata: plist],
               GSHelpFormatMan,
               "metadata for other names leaves extensions in charge");
  }
  END_SET("bundle metadata hook")

  cleanupFixtures();
  [arp release];
  return 0;
}

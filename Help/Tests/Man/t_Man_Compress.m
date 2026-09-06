/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_Man_Compress - GSManParser transparent decompression: gz, bz2 and
 * xz pages must parse identically to the uncompressed page; corrupt
 * compressed data must yield an error, never a crash. Headless. */

#import <Foundation/Foundation.h>
#import <unistd.h>
#import "Testing.h"

#import "GSHelpNode.h"
#import "GSHelpDocument.h"
#import "GSManParser.h"

#if defined(__has_include)
#  if __has_include(<zlib.h>)
#    import <zlib.h>
#    define T_HAVE_ZLIB 1
#  endif
#  if __has_include(<bzlib.h>)
#    import <bzlib.h>
#    define T_HAVE_BZ2 1
#  endif
#  if __has_include(<lzma.h>)
#    import <lzma.h>
#    define T_HAVE_LZMA 1
#  endif
#endif

static NSString *Source(void)
{
  return @".TH GZIPTEST 1\n"
          @".SH NAME\n"
          @"ziptest \\- compressed page fixture\n"
          @".SH DESCRIPTION\n"
          @"See printf(3) for details.\n";
}

static NSString *BasePath(NSString *suffix)
{
  return [NSString stringWithFormat: @"%@/gsmancomp_%d%@",
      NSTemporaryDirectory(), (int)getpid(), suffix];
}

static void RemoveAll(void)
{
  NSFileManager *fm = [NSFileManager defaultManager];
  [fm removeItemAtPath: BasePath(@".1") error: NULL];
  [fm removeItemAtPath: BasePath(@".1.gz") error: NULL];
  [fm removeItemAtPath: BasePath(@".1.bz2") error: NULL];
  [fm removeItemAtPath: BasePath(@".1.xz") error: NULL];
  [fm removeItemAtPath: BasePath(@"bad.gz") error: NULL];
}

#ifdef T_HAVE_ZLIB
static NSData *GzipData(NSData *input)
{
  z_stream zs;
  memset(&zs, 0, sizeof zs);
  /* windowBits 15+16 selects the gzip container, not raw deflate */
  if (deflateInit2(&zs, Z_BEST_COMPRESSION, Z_DEFLATED, 15 + 16, 8,
                   Z_DEFAULT_STRATEGY) != Z_OK) {
    return nil;
  }
  NSMutableData *out =
      [NSMutableData dataWithCapacity: input.length / 2 + 64];
  Bytef buf[65536];
  zs.next_in = (Bytef *)(uintptr_t) input.bytes;
  zs.avail_in = input.length;
  int r;
  do {
    zs.next_out = buf;
    zs.avail_out = sizeof buf;
    r = deflate(&zs, Z_FINISH);
    [out appendBytes: buf length: sizeof buf - zs.avail_out];
  } while (r != Z_STREAM_END);
  deflateEnd(&zs);
  return out;
}
#endif

#ifdef T_HAVE_BZ2
static NSData *Bzip2Data(NSData *input)
{
  unsigned int destLen =
      (unsigned int)(input.length + input.length / 100 + 600);
  char *dest = malloc(destLen);
  if (!dest) {
    return nil;
  }
  int r = BZ2_bzBuffToBuffCompress(dest, &destLen,
                                   (char *)(uintptr_t) input.bytes,
                                   (unsigned int) input.length, 9, 0, 0);
  if (r != BZ_OK) {
    free(dest);
    return nil;
  }
  return [NSData dataWithBytesNoCopy: dest length: destLen freeWhenDone: YES];
}
#endif

#ifdef T_HAVE_LZMA
static NSData *XzData(NSData *input)
{
  size_t bound = lzma_stream_buffer_bound(input.length);
  uint8_t *buf = malloc(bound);
  if (!buf) {
    return nil;
  }
  size_t pos = 0;
  lzma_ret r = lzma_easy_buffer_encode(6, LZMA_CHECK_CRC32, NULL,
      (const uint8_t *)(uintptr_t) input.bytes, input.length, buf, &pos, bound);
  if (r != LZMA_OK) {
    free(buf);
    return nil;
  }
  return [NSData dataWithBytesNoCopy: buf length: pos freeWhenDone: YES];
}
#endif

static void WriteBytes(NSData *data, NSString *path)
{
  [data writeToFile: path atomically: YES];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  RemoveAll();

  NSData *raw = [Source() dataUsingEncoding: NSUTF8StringEncoding];
  GSManParser *parser = [GSManParser new];

  /* Baseline: the uncompressed page */
  WriteBytes(raw, BasePath(@".1"));
  NSURL *plainURL = [NSURL fileURLWithPath: BasePath(@".1")];
  GSHelpDocument *base = [parser parseURL: plainURL error: nil];
  PASS(base != nil, "uncompressed page parses");
  PASS_EQUAL(base.metadata[@"command"], @"GZIPTEST", "baseline command");
  PASS_EQUAL(base.metadata[@"shortDescription"],
             @"compressed page fixture", "baseline shortDescription");
  PASS_EQUAL(base.title, @"GZIPTEST(1)", "baseline title");

  START_SET("gzip")
  {
#ifdef T_HAVE_ZLIB
    PASS([parser canParseURL:
        [NSURL fileURLWithPath: BasePath(@".1.gz")]],
        ".1.gz accepted by canParseURL");
    WriteBytes(GzipData(raw), BasePath(@".1.gz"));
    __block GSHelpDocument *d = nil;
    PASS_RUNS(d = [parser parseURL:
        [NSURL fileURLWithPath: BasePath(@".1.gz")] error: nil],
        ".gz page parses without raising");
    PASS(d != nil, ".gz produced a document");
    PASS([d.metadata[@"command"] isEqual: base.metadata[@"command"]]
         && [d.metadata[@"shortDescription"]
             isEqual: base.metadata[@"shortDescription"]],
         ".gz metadata identical to uncompressed");
#else
    FAIL("zlib unavailable - cannot test .gz");
#endif
  }
  END_SET("gzip")

  START_SET("bzip2")
  {
#ifdef T_HAVE_BZ2
    PASS([parser canParseURL:
        [NSURL fileURLWithPath: BasePath(@".1.bz2")]],
        ".1.bz2 accepted by canParseURL");
    WriteBytes(Bzip2Data(raw), BasePath(@".1.bz2"));
    GSHelpDocument *d = [parser parseURL:
        [NSURL fileURLWithPath: BasePath(@".1.bz2")] error: nil];
    PASS(d != nil, ".bz2 produced a document");
    PASS([d.title isEqual: base.title],
         ".bz2 title identical to uncompressed");
#else
    FAIL("libbz2 unavailable - cannot test .bz2");
#endif
  }
  END_SET("bzip2")

  START_SET("xz")
  {
#ifdef T_HAVE_LZMA
    PASS([parser canParseURL:
        [NSURL fileURLWithPath: BasePath(@".1.xz")]],
        ".1.xz accepted by canParseURL");
    WriteBytes(XzData(raw), BasePath(@".1.xz"));
    GSHelpDocument *d = [parser parseURL:
        [NSURL fileURLWithPath: BasePath(@".1.xz")] error: nil];
    PASS(d != nil, ".xz produced a document");
    PASS([d.metadata[@"command"] isEqual: base.metadata[@"command"]],
         ".xz command identical to uncompressed");
#else
    FAIL("liblzma unavailable - cannot test .xz");
#endif
  }
  END_SET("xz")

  START_SET("corrupt archive")
  {
    NSString *bad = BasePath(@"bad.gz");
    NSData *junk = [@"this is definitely not gzip data"
        dataUsingEncoding: NSUTF8StringEncoding];
    WriteBytes(junk, bad);
    NSError *err = nil;
    __block GSHelpDocument *d = nil;
    PASS_RUNS(d = [parser parseURL:
        [NSURL fileURLWithPath: bad] error: &err],
        "corrupt .gz does not raise");
    PASS(d == nil, "corrupt .gz returns nil document");
    PASS(err != nil, "corrupt .gz sets an error");
  }
  END_SET("corrupt archive")

  RemoveAll();

  [arp release];
  return 0;
}

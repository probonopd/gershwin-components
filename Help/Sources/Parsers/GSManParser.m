/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSManParser.h"

#import "GSHelpDocument.h"
#import "GSHelpNode.h"
#import "GSHelpURL.h"

/* Decompression support is optional at build time: the makefile probes
 * each codec with a real link test and passes GS_HAVE_* on the command
 * line, so this source compiles in exactly the codecs that will be
 * linked. Header-only detection is not enough - some systems expose
 * bzlib.h/lzma.h without usable libraries (this broke the OpenBSD
 * link). A page compressed with an unsupported codec surfaces as a
 * parse error, never as silent garbage output. */
#ifdef GS_HAVE_ZLIB
#  import <zlib.h>
#endif
#ifdef GS_HAVE_BZ2
#  import <bzlib.h>
#endif
#ifdef GS_HAVE_LZMA
#  import <lzma.h>
#endif

NS_ASSUME_NONNULL_BEGIN

static NSString *const GSManErrorDomain = @"GSManParserErrorDomain";

#pragma mark - Compression

static BOOL GSCheckedReadFile(NSString *path, NSData **outData)
{
  *outData = [NSData dataWithContentsOfFile: path];
  return (*outData != nil);
}

#ifdef GS_HAVE_ZLIB
/* gzopen/gzread handle the whole gzip container including multi-member
 * files; a read error is reported so corrupt pages fail hard instead of
 * producing truncated roff source. zlib would silently read non-gzip
 * files transparently, so the magic bytes are verified up front. */
static NSData *GSGunzip(NSString *path)
{
  NSData *head =
      [[NSData alloc] initWithContentsOfFile: path];
  if (!head || head.length < 2
      || ((const uint8_t *)head.bytes)[0] != 0x1f
      || ((const uint8_t *)head.bytes)[1] != 0x8b) {
    return nil;
  }
  gzFile f = gzopen(path.fileSystemRepresentation, "rb");
  if (!f) {
    return nil;
  }
  NSMutableData *out = [NSMutableData new];
  char buf[65536];
  int r;
  while ((r = gzread(f, buf, sizeof buf)) > 0) {
    [out appendBytes: buf length: (NSUInteger) r];
  }
  int zerr;
  gzerror(f, &zerr);
  gzclose(f);
  if (r < 0 || zerr != Z_OK) {
    return nil;
  }
  return out;
}
#endif

#ifdef GS_HAVE_BZ2
static NSData *GSBunzip2(NSData *input)
{
  if (input.length == 0 || !input.bytes) {
    return nil;
  }
  bz_stream s;
  memset(&s, 0, sizeof s);
  if (BZ2_bzDecompressInit(&s, 0, 0) != BZ_OK) {
    return nil;
  }
  s.next_in = (char *)(uintptr_t) input.bytes;
  s.avail_in = input.length;
  NSMutableData *out = [NSMutableData new];
  char buf[65536];
  int r = BZ_OK;
  while (r == BZ_OK) {
    s.next_out = buf;
    s.avail_out = sizeof buf;
    r = BZ2_bzDecompress(&s);
    [out appendBytes: buf length: sizeof buf - s.avail_out];
    if (r == BZ_STREAM_END) {
      break;
    }
  }
  BZ2_bzDecompressEnd(&s);
  if (r != BZ_STREAM_END) {
    return nil;
  }
  return out;
}
#endif

#ifdef GS_HAVE_LZMA
static NSData *GSUnxz(NSData *input)
{
  lzma_stream strm = LZMA_STREAM_INIT;
  /* UINT64_MAX memory limit: man pages are small and local files are
   * already trusted to be readable; the decoder caps itself anyway. */
  if (lzma_stream_decoder(&strm, UINT64_MAX, 0) != LZMA_OK) {
    return nil;
  }
  strm.next_in = (const uint8_t *)(uintptr_t) input.bytes;
  strm.avail_in = input.length;
  NSMutableData *out = [NSMutableData new];
  uint8_t buf[65536];
  lzma_ret r = LZMA_OK;
  while (r == LZMA_OK) {
    strm.next_out = buf;
    strm.avail_out = sizeof buf;
    r = lzma_code(&strm, LZMA_RUN);
    [out appendBytes: buf length: sizeof buf - strm.avail_out];
    if (r == LZMA_STREAM_END) {
      break;
    }
  }
  lzma_end(&strm);
  if (r != LZMA_STREAM_END) {
    return nil;
  }
  return out;
}
#endif

static NSString *GSLowercaseExtension(NSString *path)
{
  return path.pathExtension.lowercaseString;
}

/* Returns decompressed data or nil when the extension names a codec we
 * cannot handle (missing library or corrupt input). */
static NSData *GSDecompressedForPath(NSString *path,
                                               NSData *raw,
                                               NSError **error)
{
  NSString *ext = GSLowercaseExtension(path);
  NSDictionary<NSString *, NSNumber *> *codecs =
      @{ @"gz": @1, @"bz2": @2, @"xz": @3 };
  NSNumber *codec = codecs[ext];
  if (codec == nil) {
    return raw;
  }
  switch (codec.integerValue) {
#ifdef GS_HAVE_ZLIB
    case 1:
      if ([ext isEqual: @"gz"]) {
        NSData *d = GSGunzip(path);
        if (d) {
          return d;
        }
        if (error) {
          *error = [NSError errorWithDomain: GSManErrorDomain
                                       code: 3
                                   userInfo: @{ NSLocalizedDescriptionKey:
                                       @"gzip decompression failed" }];
        }
        return nil;
      }
      break;
#endif
#ifdef GS_HAVE_BZ2
    case 2: {
      NSData *d = GSBunzip2(raw);
      if (d) {
        return d;
      }
      if (error) {
        *error = [NSError errorWithDomain: GSManErrorDomain
                                     code: 3
                                 userInfo: @{ NSLocalizedDescriptionKey:
                                     @"bzip2 decompression failed" }];
      }
      return nil;
    }
#endif
#ifdef GS_HAVE_LZMA
    case 3: {
      NSData *d = GSUnxz(raw);
      if (d) {
        return d;
      }
      if (error) {
        *error = [NSError errorWithDomain: GSManErrorDomain
                                     code: 3
                                 userInfo: @{ NSLocalizedDescriptionKey:
                                     @"xz decompression failed" }];
      }
      return nil;
    }
#endif
    default:
      break;
  }
  if (error) {
    *error = [NSError errorWithDomain: GSManErrorDomain
                                 code: 4
                             userInfo: @{ NSLocalizedDescriptionKey:
      [NSString stringWithFormat:
          @"compression format '%@' not supported by this build", ext] }];
  }
  return nil;
}

#pragma mark - Escapes

static NSDictionary<NSString *, NSString *> *GSEntityMap(void)
{
  static NSDictionary<NSString *, NSString *> *map;
  /* Parsing runs on a single worker thread per document; a plain
   * guarded init avoids libdispatch per project rules. */
  if (!map) {
    map = @{
      @"em": @"-", @"en": @"-", @"hy": @"-", @"mi": @"-",
      @"bu": @"*", @"sq": @"'", @"aq": @"'", @"aa": @"'",
      @"ga": @"`", @"dq": @"\"", @"lq": @"\u201c", @"rq": @"\u201d",
      @"dg": @"#", @"dd": @"#", @"sh": @"#", @"tm": @"(TM)",
      @"am": @"&", @"lt": @"<", @"gt": @">", @"pl": @"+", @"sc": @"$",
      @"de": @"\u00b0", @"rg": @"(R)", @"co": @"(C)",
      @"ba": @"|", @"br": @"|", @"or": @"^", @"ul": @"_", @"rn": @"-",
      @"sl": @"_", @"rs": @"\\", @"fm": @"'",
    };
  }
  return map;
}

/* Best-effort roff escape resolution (SPEC 21/22): common two-char
 * entities mapped, font switches dropped, zero-width escapes removed,
 * anything else loses its backslash. Never raises. */
static NSString *GSUnescape(NSString *s)
{
  if (![s containsString: @"\\"]) {
    return s;
  }
  NSMutableString *out = [NSMutableString stringWithCapacity: s.length];
  NSUInteger i = 0;
  const NSUInteger n = s.length;
  while (i < n) {
    unichar c = [s characterAtIndex: i];
    if (c != '\\') {
      [out appendFormat: @"%C", c];
      i++;
      continue;
    }
    if (i + 1 >= n) {
      /* trailing backslash: drop */
      i++;
      continue;
    }
    unichar d = [s characterAtIndex: i + 1];
    switch (d) {
      case '-':
        [out appendString: @"-"];
        i += 2;
        break;
      case '\\':
      case 'e':
        [out appendString: @"\\"];
        i += 2;
        break;
      case '&':
      case '%':
      case 'c':
      case '!':
      case '?':
        [out appendString: @""];
        i += 2;
        break;
      case ' ':
      case '~':
      case '^':
        [out appendString: @" "];
        i += 2;
        break;
      case '{':
      case '}':
        i += 2;
        break;
      case 'f':
      case 'F': {
        /* inline font switch: skip the selector, keep rendering */
        i += 2;
        if (i < n && [s characterAtIndex: i] == '(') {
          i += 3;
        } else if (i + 1 < n && [s characterAtIndex: i] == '[') {
          NSUInteger close = [s rangeOfString: @"]"
                                      options: 0
                                        range: NSMakeRange(i, n - i)].location;
          i = (close == NSNotFound) ? n : close + 1;
        } else if (i < n) {
          i += 1;
        }
        break;
      }
      case '(': {
        /* two-char special entity */
        if (i + 3 < n) {
          NSString *key = [s substringWithRange: NSMakeRange(i + 2, 2)];
          NSString *v = GSEntityMap()[key];
          if (v) {
            [out appendString: v];
          } else {
            /* unknown entity: strip backslash, keep the characters */
            [out appendString: key];
          }
          i += 4;
        } else {
          i += 2;
        }
        break;
      }
      case '[': {
        NSUInteger close = [s rangeOfString: @"]"
                                    options: 0
                                      range: NSMakeRange(i + 2, n - i - 2)].location;
        if (close != NSNotFound) {
          NSString *key =
              [s substringWithRange: NSMakeRange(i + 2, close - i - 2)];
          if ([key isEqual: @"nbsp"] || [key isEqual: @" "] ) {
            [out appendString: @" "];
          }
          i = close + 1;
        } else {
          i += 2;
        }
        break;
      }
      default:
        /* unknown escape: drop the backslash only */
        i += 1;
        break;
    }
  }
  return out;
}

static NSString *GSTrim(NSString *s)
{
  return [s stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceCharacterSet]];
}

/* Simple whitespace tokenizer for macro arguments. */
static NSArray<NSString *> *GSSplitWords(NSString *s)
{
  NSMutableArray *out = [NSMutableArray new];
  for (NSString *w in
      [s componentsSeparatedByCharactersInSet:
          [NSCharacterSet whitespaceCharacterSet]]) {
    if (w.length > 0) {
      [out addObject: w];
    }
  }
  return out;
}

/* Quote-aware tokenizer used for .TH where extra arguments carry
 * strings like "May 2023". */
static NSArray<NSString *> *GSSplitQuoted(NSString *s)
{
  NSMutableArray *out = [NSMutableArray new];
  NSMutableString *cur = [NSMutableString new];
  BOOL inQuote = NO;
  for (NSUInteger k = 0; k < s.length; k++) {
    unichar c = [s characterAtIndex: k];
    if (c == '"') {
      inQuote = !inQuote;
    } else if (!inQuote && (c == ' ' || c == '\t')) {
      if (cur.length > 0) {
        [out addObject: cur];
        cur = [NSMutableString new];
      }
    } else {
      [cur appendFormat: @"%C", c];
    }
  }
  if (cur.length > 0) {
    [out addObject: cur];
  }
  return out;
}

#pragma mark - Cross references

static NSRegularExpression *GSManRefRegex(void)
{
  static NSRegularExpression *re;
  static NSLock *lock;
  if (!re) {
    if (!lock) {
      lock = [NSLock new];
    }
    [lock lock];
    if (!re) {
      re = [[NSRegularExpression alloc]
          initWithPattern: @"([A-Za-z][A-Za-z0-9_.:+-]*)\\(([0-9][A-Za-z0-9+]*)\\)"
                  options: 0
                    error: NULL];
    }
    [lock unlock];
  }
  return re;
}

NS_ASSUME_NONNULL_END

#pragma mark - Parser state

typedef NS_ENUM(NSUInteger, GSMRunMode) {
  GSMRunModeParagraph,
  GSMRunModeListItem,
};

@implementation GSManParser
{
  GSHelpSection *_root;
  GSHelpDocument *_doc;
  NSMutableArray<GSHelpNode *> *_pendingRuns;
  GSMRunMode _runMode;
  GSHelpList *_openList;
  GSHelpListItem *_currentItem;
  BOOL _lastBlockWasList;
  BOOL _inNameSection;
  NSString *_shortDescription;
  NSString *_command;
  NSString *_section;
  BOOL _verbatim;
  NSMutableString *_codeBuffer;
  /* Whole-section code blocks: some man sections (SYNOPSIS, TYPES,
   * CONSTANTS, ...) are pure source and read best as a monospaced code
   * block rather than filled prose. While _inCodeSection is set, text
   * lines and font macros accumulate verbatim into _codeSectionBuffer,
   * flushed as one GSHelpCodeBlock when the section ends. */
  BOOL _inCodeSection;
  NSMutableString *_codeSectionBuffer;
  BOOL _tpPending;
  GSHelpTextStyle _pendingStyle;
  BOOL _awaitHeadingText;
  /* While parsing a roff macro definition (.de/.do ... terminator) the
   * body lines are formatting machinery, never page content, and must
   * be skipped wholesale. _macroDepth counts nesting; _macroEnd is the
   * optional explicit end-macro name given as ".de name end". */
  NSInteger _macroDepth;
  NSString *_macroEnd;
}

#pragma mark Detection

- (BOOL)canParseURL:(NSURL *)url
{
  if (!url.isFileURL || url.path.length == 0) {
    return NO;
  }
  NSString *name = url.lastPathComponent;
  NSString *ext = name.pathExtension.lowercaseString;

  /* Strip one compression layer before checking the section suffix. */
  if ([ext isEqual: @"gz"] || [ext isEqual: @"bz2"]
      || [ext isEqual: @"xz"]) {
    NSString *stem =
        [name stringByDeletingPathExtension].lastPathComponent;
    ext = stem.pathExtension.lowercaseString;
  }
  if (ext.length > 0 && isdigit((int)[ext characterAtIndex: 0])) {
    return YES;
  }

  /* Content sniff: pages without a numeric extension still count when
   * their first line looks like roff control input (.TH or '). */
  NSData *head = [NSData dataWithContentsOfFile: url.path];
  if (!head) {
    return NO;
  }
  if (head.length > 256) {
    head = [head subdataWithRange: NSMakeRange(0, 256)];
  }
  NSString *prefix =
      [[NSString alloc] initWithData: head
                            encoding: NSUTF8StringEncoding];
  if (!prefix) {
    prefix = [[NSString alloc] initWithData: head
                                   encoding: NSISOLatin1StringEncoding];
  }
  NSString *firstLine =
      [prefix componentsSeparatedByCharactersInSet:
          [NSCharacterSet newlineCharacterSet]].firstObject;
  firstLine = GSTrim(firstLine ?: @"");
  return ([firstLine hasPrefix: @".TH"] || [firstLine hasPrefix: @"'"]);
}

#pragma mark Parsing entry point

- (nullable GSHelpDocument *)parseURL:(NSURL *)url
                                error:(NSError **)error
{
  if (error) {
    *error = nil;
  }
  if (!url.isFileURL || url.path.length == 0) {
    if (error) {
      *error = [NSError errorWithDomain: GSManErrorDomain
                                   code: 1
                               userInfo: @{ NSLocalizedDescriptionKey:
                                   @"not a file URL" }];
    }
    return nil;
  }

  NSData *raw = nil;
  if (!GSCheckedReadFile(url.path, &raw)) {
    if (error) {
      *error = [NSError errorWithDomain: GSManErrorDomain
                                   code: 2
                               userInfo: @{ NSLocalizedDescriptionKey:
      [NSString stringWithFormat: @"cannot read %@", url.path] }];
    }
    return nil;
  }

  NSError *decompError = nil;
  NSData *data = GSDecompressedForPath(url.path, raw, &decompError);
  if (!data) {
    if (error) {
      *error = decompError;
    }
    return nil;
  }

  NSString *source =
      [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
  if (!source) {
    source = [[NSString alloc] initWithData: data
                                   encoding: NSISOLatin1StringEncoding];
  }
  if (!source) {
    source = @"";
  }

  @try {
    return [self documentFromSource: source url: url];
  }
  @catch (NSException *e) {
    /* Malformed roff must never propagate: degrade to plain paragraphs
     * so the user can still read the page content. */
    return [self fallbackDocumentFromSource: source url: url];
  }
}

#pragma mark Document construction

- (GSHelpDocument *)documentFromSource:(NSString *)source
                                   url:(NSURL *)url
{
  _root = [GSHelpSection new];
  _doc = [GSHelpDocument new];
  _doc.sourceURL = url;
  _doc.sourceType = @"man";
  _doc.rootNode = _root;
  _pendingRuns = [NSMutableArray new];
  _runMode = GSMRunModeParagraph;
  _shortDescription = nil;
  _command = nil;
  _section = nil;
  _verbatim = NO;
  _inCodeSection = NO;
  _codeSectionBuffer = nil;
  _tpPending = NO;
  _pendingStyle = GSHelpTextStylePlain;
  _awaitHeadingText = NO;
  _macroDepth = 0;
  _macroEnd = nil;

  NSArray *lines =
      [source componentsSeparatedByCharactersInSet:
          [NSCharacterSet newlineCharacterSet]];
  for (NSString *line in lines) {
    [self processLine: line];
  }
  [self flushRuns];
  if (_verbatim) {
    [self flushCodeBlock];
  }
  [self flushCodeSection];

  NSMutableDictionary *meta = [NSMutableDictionary new];
  meta[@"command"] = _command ?: @"";
  meta[@"section"] = _section ?: @"";
  if (_shortDescription.length > 0) {
    meta[@"shortDescription"] = _shortDescription;
  }
  _doc.metadata = meta;

  if (!_doc.title.length) {
    if (_command && _section) {
      _doc.title =
          [NSString stringWithFormat: @"%@(%@)", _command, _section];
    } else if (_command) {
      _doc.title = _command;
    } else {
      _doc.title = url.lastPathComponent;
    }
  }

  GSHelpDocument *result = _doc;
  _root = nil;
  _doc = nil;
  return result;
}

- (void)processLine:(NSString *)line
{
  /* Whole-line comments (both spellings) vanish entirely and must not
   * break paragraph continuity. */
  if ([line hasPrefix: @"\\\""] || [line hasPrefix: @".'"]) {
    return;
  }

  /* Inside a roff macro definition the body is machinery, not content.
   * Skip it until the terminator (a lone '.' or '..', or the explicit
   * end macro named in ".de name end"). */
  if (_macroDepth > 0) {
    NSString *trimmed = GSTrim(line);
    BOOL terminator = ([trimmed isEqualToString: @"."]
                       || [trimmed isEqualToString: @".."]);
    if (_macroEnd != nil) {
      terminator = terminator
          || [trimmed isEqualToString:
              [@"." stringByAppendingString: _macroEnd]];
    }
    if (terminator) {
      _macroDepth--;
      if (_macroDepth == 0) {
        _macroEnd = nil;
      }
      return;
    }
    return;
  }

  /* Fallback for macro bodies that escaped .de detection: a line that
   * is plainly roff machinery (a macro argument reference "\$1" or a
   * register/string interpolation "\n[...]") must never reach the
   * output as text (this is what rst2man leaks at the top of pages). */
  if ([line hasPrefix: @"\\$"]
      || [line containsString: @"\\n["]
      || [line containsString: @"\\*["]) {
    return;
  }

  unichar c0 = line.length ? [line characterAtIndex: 0] : 0;

  if (line.length == 0) {
    if (_verbatim) {
      [_codeBuffer appendString: @"\n"];
    } else {
      [self flushRuns];
    }
    return;
  }

  if (c0 == '.' || c0 == '\'') {
    NSString *rest = [line substringFromIndex: 1];
    NSUInteger k = 0;
    while (k < rest.length && isalpha((int)[rest characterAtIndex: k])) {
      k++;
    }
    if (k > 0) {
      [self handleMacro: [rest substringToIndex: k]
                   args: GSTrim([rest substringFromIndex: k])];
      return;
    }
    /* '.' alone or followed by junk: treat as filler, ignore */
    return;
  }

    if (_verbatim) {
      /* Code/verbatim excerpts carry the same roff noise as running
       * text (\&, \f switches, \- ...); strip it so the block shows the
       * actual content rather than roff machinery. */
      [_codeBuffer appendString: GSUnescape(line)];
      [_codeBuffer appendString: @"\n"];
      return;
    }

  [self addTextLine: line];
}

- (void)handleMacro:(NSString *)name args:(NSString *)args
{
  NSString *m = name.uppercaseString;

  /* Begin a roff macro definition; its body (until the terminator) is
   * machinery and is skipped by -processLine. The optional second
   * argument names the end macro (".de name end"). */
  if ([m isEqualToString: @"DE"] || [m isEqualToString: @"DO"]
      || [m isEqualToString: @"DE1"] || [m isEqualToString: @"DO1"]) {
    NSArray *toks = GSSplitQuoted(args);
    NSString *end = nil;
    if (toks.count >= 2) {
      end = [toks[1] uppercaseString];
    }
    _macroDepth++;
    _macroEnd = end;
    return;
  }

  if ([m isEqualToString: @"TH"]) {
    [self flushAllContent];
    NSArray *toks = GSSplitQuoted(args);
    if (toks.count > 0) {
      _command = toks[0];
    }
    if (toks.count > 1) {
      _section = toks[1];
    }
    if (_command && _section) {
      _doc.title =
          [NSString stringWithFormat: @"%@(%@)", _command, _section];
    }
    return;
  }

  if ([m isEqualToString: @"SH"] || [m isEqualToString: @"SS"]) {
    BOOL isSubsection = [m isEqualToString: @"SS"];
    [self flushAllContent];
    NSString *title = GSUnescape(
        [GSSplitWords(args) componentsJoinedByString: @" "]);
    title = GSTrim(title);
    if (title.length == 0) {
      /* .SH with no arguments takes its title from the next text line */
      _awaitHeadingText = YES;
      return;
    }
    [self openHeading: title level: isSubsection ? 2 : 1];
    return;
  }

  if ([m isEqualToString: @"PP"] || [m isEqualToString: @"P"]
      || [m isEqualToString: @"LP"]) {
    [self flushRuns];
    return;
  }

  if ([m isEqualToString: @"IP"] || [m isEqualToString: @"HP"]) {
    [self beginListItemWithTag: [m isEqualToString: @"IP"]
                          args: args];
    return;
  }

  if ([m isEqualToString: @"TP"]) {
    [self flushRuns];
    _tpPending = YES;
    return;
  }

  /* Verbatim display blocks arrive under several macro names: man(7)
   * .nf/.fi, pod2man .Vb/.Ve and mdoc-style .EX/.EE. */
  if ([m isEqualToString: @"NF"] || [m isEqualToString: @"VB"]
      || [m isEqualToString: @"EX"]) {
    [self flushRuns];
    _verbatim = YES;
    _codeBuffer = [NSMutableString new];
    return;
  }

  if ([m isEqualToString: @"FI"] || [m isEqualToString: @"VE"]
      || [m isEqualToString: @"EE"]) {
    [self flushCodeBlock];
    return;
  }

  /* .br forces a line break and .sp vertical space. Roff is
   * case-sensitive here: the lowercase spellings are breaks, while
   * .BR/.SP uppercased would collide with the bold-roman font macro,
   * which silently ate every .br before this check existed. */
  if ([name isEqualToString: @"br"] || [name isEqualToString: @"sp"]) {
    [self flushRuns];
    return;
  }

  if ([self isFontMacro: m]) {
    [self applyFontMacro: m args: args];
    return;
  }

  /* mdoc author references: .An names an author (sometimes inline with
   * "Aq email"), .Aq renders an address in angle brackets. Both carry
   * real content that must reach the output, not be dropped. Control
   * forms like ".An -split"/".An -nosplit" carry no text. */
  if ([m isEqualToString: @"AN"]) {
    [self handleAuthorName: args];
    return;
  }
  if ([m isEqualToString: @"AQ"]) {
    NSString *t = GSTrim(GSUnescape(args));
    if (t.length > 0) {
      [self addRun: [NSString stringWithFormat: @"<%@>", t]
             style: GSHelpTextStylePlain
              join: YES];
    }
    return;
  }

  /* Unknown macro: ignored gracefully rather than misinterpreted. */
}

- (void)handleAuthorName:(NSString *)args
{
  NSString *t = GSTrim(GSUnescape(args));
  if (t.length == 0 || [t hasPrefix: @"-"]) {
    return;
  }
  /* Combined ".An name Aq email" form: keep the name and bracket the
   * address, matching what .Aq would produce standalone. */
  NSRange aq = [t rangeOfString: @" Aq "];
  if (aq.location != NSNotFound) {
    NSString *name = GSTrim([t substringToIndex: aq.location]);
    NSString *email = GSTrim([t substringFromIndex: NSMaxRange(aq)]);
    [self addRun: [NSString stringWithFormat: @"%@ <%@>", name, email]
           style: GSHelpTextStylePlain
            join: YES];
    return;
  }
  [self addRun: t style: GSHelpTextStylePlain join: YES];
}

- (BOOL)isFontMacro:(NSString *)m
{
  static NSSet *macros;
  if (!macros) {
    macros = [NSSet setWithObjects:
        @"B", @"I", @"BI", @"BR", @"IB", @"IR", @"RB", @"RI",
        @"SB", @"SM", nil];
  }
  return [macros containsObject: m];
}

/* Maps one letter of a two-letter font code (or the single-letter
 * macro itself) to a run style. S renders bold (small-bold), R/P
 * render plain. */
- (GSHelpTextStyle)styleForFontLetter:(unichar)c
{
  switch (c) {
    case 'B':
    case 'S':
      return GSHelpTextStyleBold;
    case 'I':
      return GSHelpTextStyleItalic;
    default:
      return GSHelpTextStylePlain;
  }
}

- (void)applyFontMacro:(NSString *)name args:(NSString *)args
{
  /* Inside a code section a font macro just contributes its literal
   * text as a source line; a bare font request (no args) applies to the
   * next line and is ignored here. */
  if (_inCodeSection) {
    NSArray *toks = GSSplitQuoted(args);
    if (toks.count == 0) {
      return;
    }
    [_codeSectionBuffer
        appendString: GSUnescape([toks componentsJoinedByString: @" "])];
    [_codeSectionBuffer appendString: @"\n"];
    return;
  }

  /* Roff font macros take whitespace-separated OR double-quoted
   * arguments; quoted spaces are significant (".BI "-x " "file"" must
   * render "-x file", not "-xfile"), so split quote-aware. */
  NSArray *toks = GSSplitQuoted(args);
  if ([name isEqualToString: @"SM"]) {
    /* .SM sets its arguments small, i.e. plain roman here */
    for (NSString *tok in toks) {
      [self addRun: GSUnescape(tok) style: GSHelpTextStylePlain];
    }
    if (_tpPending && toks.count > 0) {
      _tpPending = NO;
    }
    return;
  }
  if (toks.count == 0) {
    /* Font request applies to the next input text line. */
    _pendingStyle = [self styleForFontLetter:
        [name characterAtIndex: 0]];
    return;
  }
  BOOL alternating = name.length == 2;
  for (NSUInteger k = 0; k < toks.count; k++) {
    unichar letter =
        [name characterAtIndex: alternating ? (k % 2) : 0];
    /* Roff output semantics: the first argument continues the prose
     * flow with a space; a single-font macro separates its further
     * arguments with spaces too (".B foo bar" -> "foo bar"), while
     * two-font macros concatenate them ("libinput" + "(1)" ->
     * "libinput(1)"). */
    [self addRun: GSUnescape(toks[k])
           style: [self styleForFontLetter: letter]
           join: k == 0 || !alternating];
  }
  if (_tpPending) {
    /* The whole font-macro line counts as the .TP tag. */
    _tpPending = NO;
  }
}

- (void)openHeading:(NSString *)text level:(NSUInteger)level
{
  [self flushCodeSection];
  GSHelpHeading *h = [GSHelpHeading new];
  h.text = text;
  h.level = MIN(MAX(level, 1), 4);
  [_root appendNode: h];
  _inNameSection = [text caseInsensitiveCompare: @"NAME"] == 0;
  _inCodeSection = [self isCodeSectionTitle: text];
  if (_inCodeSection) {
    _codeSectionBuffer = [NSMutableString new];
  }
}

- (void)beginListItemWithTag:(BOOL)tagged args:(NSString *)args
{
  [self flushRuns];

  if (!_openList || !_lastBlockWasList) {
    _openList = [GSHelpList new];
    _openList.ordered = NO;
    [_root appendNode: _openList];
  }
  GSHelpListItem *item = [GSHelpListItem new];
  [_openList appendNode: item];
  _lastBlockWasList = YES;
  _currentItem = item;
  _runMode = GSMRunModeListItem;

  if (tagged) {
    /* .IP tag [indent]: a purely numeric second argument is the tag
     * width, not tag text, and must not leak into the output. */
    NSArray *toks = GSSplitQuoted(args);
    for (NSString *tok in toks) {
      NSString *t = GSTrim(GSUnescape(tok));
      if (t.length == 0) {
        continue;
      }
      BOOL numericOnly = YES;
      for (NSUInteger k = 0; k < t.length; k++) {
        if (!isdigit((int)[t characterAtIndex: k])) {
          numericOnly = NO;
          break;
        }
      }
      if (numericOnly) {
        continue;
      }
      GSHelpText *run = [GSHelpText new];
      run.string = t;
      run.style = GSHelpTextStyleBold;
      [item appendNode: run];
      break;
    }
  }
}

- (void)addTextLine:(NSString *)line
{
  if (_awaitHeadingText) {
    _awaitHeadingText = NO;
    [self openHeading: GSTrim(GSUnescape(line)) level: 1];
    return;
  }

  /* Inside a code section the body is source: keep it verbatim
   * (preserving line breaks and indentation) instead of filling it. */
  if (_inCodeSection) {
    [_codeSectionBuffer appendString: GSUnescape(line)];
    [_codeSectionBuffer appendString: @"\n"];
    return;
  }

  GSHelpTextStyle style = GSHelpTextStylePlain;
  if (_tpPending) {
    style = GSHelpTextStyleBold;
    _tpPending = NO;
  } else if (_pendingStyle != GSHelpTextStylePlain) {
    style = _pendingStyle;
    _pendingStyle = GSHelpTextStylePlain;
  }

  NSString *clean = GSTrim(GSUnescape(line));
  if (clean.length == 0) {
    return;
  }
  /* Roff hard-wraps paragraphs in the source; a newline in the input
   * is a word space in the output, so consecutive text lines must
   * join with a space or words glue together ("willbe"). */
  [self addRun: clean style: style join: YES];
}

- (void)addRun:(NSString *)string style:(GSHelpTextStyle)style
{
  [self addRun: string style: style join: NO];
}

- (void)addRun:(NSString *)string
              style:(GSHelpTextStyle)style
              join:(BOOL)join
{
  /* Roff fill mode puts a space wherever a source line breaks, no
   * matter which characters meet at the boundary ("adds" + "-Wall"
   * renders "adds -Wall"); only existing whitespace suppresses the
   * joiner. */
  if (join && string.length > 0 && _pendingRuns.count > 0) {
    GSHelpNode *last = _pendingRuns.lastObject;
    if ([last isKindOfClass: [GSHelpText class]]) {
      GSHelpText *prev = (GSHelpText *)last;
      if (prev.string.length > 0) {
        unichar a = [prev.string
            characterAtIndex: prev.string.length - 1];
        unichar b = [string characterAtIndex: 0];
        if (a != ' ' && b != ' ') {
          prev.string = [prev.string stringByAppendingString: @" "];
        }
      }
    }
  }
  GSHelpText *run = [GSHelpText new];
  run.string = string;
  run.style = style;
  [_pendingRuns addObject: run];
}

#pragma mark Flushing

- (void)flushRuns
{
  NSArray *runs = _pendingRuns;
  _pendingRuns = [NSMutableArray new];
  BOOL wasItem = _runMode == GSMRunModeListItem;
  _runMode = GSMRunModeParagraph;
  if (!wasItem) {
    /* Any flushed prose block ends list grouping for subsequent .IP */
    _lastBlockWasList = NO;
    _openList = nil;
  }
  if (wasItem) {
    if (_currentItem) {
      /* The item may already hold the bold .IP/.TP tag run; the body
       * must not glue onto it ("--helpShow this help"). */
      GSHelpNode *lastTag = [_currentItem.children lastObject];
      GSHelpText *first = runs.firstObject;
      if ([lastTag isKindOfClass: [GSHelpText class]]
          && [first isKindOfClass: [GSHelpText class]]
          && [(GSHelpText *)lastTag string].length > 0
          && [first string].length > 0) {
        unichar a = [[(GSHelpText *)lastTag string]
            characterAtIndex:
                [(GSHelpText *)lastTag string].length - 1];
        unichar b = [[first string] characterAtIndex: 0];
        if (a != ' ' && b != ' ') {
          ((GSHelpText *)lastTag).string =
              [[(GSHelpText *)lastTag string]
                  stringByAppendingString: @" "];
        }
      }
      for (GSHelpNode *n in [self expandedRuns: runs]) {
        [_currentItem appendNode: n];
      }
      _currentItem = nil;
    }
    return;
  }
  if (runs.count == 0) {
    return;
  }
  GSHelpParagraph *p = [GSHelpParagraph new];
  for (GSHelpNode *n in [self expandedRuns: runs]) {
    [p appendNode: n];
  }
  [_root appendNode: p];
  [self captureShortDescriptionIfName: runs];
}

- (void)flushCodeBlock
{
  if (!_verbatim) {
    return;
  }
  _verbatim = NO;
  GSHelpCodeBlock *cb = [GSHelpCodeBlock new];
  cb.code = _codeBuffer;
  cb.language = nil;
  [_root appendNode: cb];
  _codeBuffer = nil;
  _lastBlockWasList = NO;
}

/* Man sections that are pure source read best as a monospaced code block
 * rather than filled, joined prose. Recognised by their (case-insensitive)
 * title; extend this set as more code-bearing sections are encountered. */
- (BOOL)isCodeSectionTitle:(NSString *)title
{
  static NSSet *codeSections;
  if (codeSections == nil) {
    codeSections = [NSSet setWithObjects:
        @"SYNOPSIS", @"SYNTAX",
        @"CALLBACKS", @"TYPES", @"CONSTANTS",
        @"DEFINES", @"DECLARATIONS", nil];
  }
  return [codeSections containsObject: [title uppercaseString]];
}

/* Flushes a pending whole-section code block (see _inCodeSection). */
- (void)flushCodeSection
{
  if (!_inCodeSection) {
    return;
  }
  _inCodeSection = NO;
  NSString *code = [_codeSectionBuffer
      stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  _codeSectionBuffer = nil;
  if (code.length == 0) {
    return;
  }
  GSHelpCodeBlock *cb = [GSHelpCodeBlock new];
  cb.code = code;
  cb.language = nil;
  [_root appendNode: cb];
  _lastBlockWasList = NO;
}

- (void)flushAllContent
{
  [self flushRuns];
  [self flushCodeBlock];
  [self flushCodeSection];
}

/* NAME section: first hyphen splits command summary from description
 * (SPEC 22). Only the first paragraph after NAME contributes. */
- (void)captureShortDescriptionIfName:(NSArray<GSHelpNode *> *)runs
{
  if (!_inNameSection || _shortDescription) {
    return;
  }
  _inNameSection = NO;

  NSMutableString *joined = [NSMutableString new];
  for (GSHelpNode *n in runs) {
    if ([n isKindOfClass: [GSHelpText class]] &&
        ((GSHelpText *)n).string.length) {
      if (joined.length > 0) {
        [joined appendString: @" "];
      }
      [joined appendString: ((GSHelpText *)n).string];
    }
  }
  NSString *s = GSTrim(joined);
  if (s.length == 0) {
    return;
  }
  NSRange r = [s rangeOfString: @" - "];
  if (r.location == NSNotFound) {
    r = [s rangeOfString: @"-"];
    if (r.location == NSNotFound) {
      return;
    }
  }
  NSString *before = GSTrim([s substringToIndex: r.location]);
  _shortDescription = GSTrim([s substringFromIndex:
      NSMaxRange(r)]);
  if (before.length > 0 && !_command) {
    _command = before;
  }
}

/* Turns word(section) patterns inside text runs into help://man links
 * (SPEC 24). Runs keep their original style across the split. */
- (NSArray<GSHelpNode *> *)expandedRuns:(NSArray<GSHelpNode *> *)runs
{
  NSMutableArray *out = [NSMutableArray arrayWithCapacity: runs.count];
  NSRegularExpression *re = GSManRefRegex();
  for (GSHelpNode *node in runs) {
    if (![node isKindOfClass: [GSHelpText class]]
        || !((GSHelpText *)node).string) {
      [out addObject: node];
      continue;
    }
    GSHelpText *run = (GSHelpText *)node;
    NSString *s = run.string;
    NSArray *matches =
        [re matchesInString: s options: 0 range: NSMakeRange(0, s.length)];
    if (matches.count == 0) {
      [out addObject: run];
      continue;
    }
    NSUInteger loc = 0;
    for (NSTextCheckingResult *m in matches) {
      if (m.range.location > loc) {
        GSHelpText *pre = [GSHelpText new];
        pre.string = [s substringWithRange: NSMakeRange(loc,
            m.range.location - loc)];
        pre.style = run.style;
        [out addObject: pre];
      }
      NSString *cmd = [s substringWithRange: [m rangeAtIndex: 1]];
      NSString *sec = [s substringWithRange: [m rangeAtIndex: 2]];
      NSURL *target = [GSHelpURL manURLWithCommand: cmd section: sec];
      GSHelpLink *link = [GSHelpLink new];
      link.target = target.absoluteString;
      [link appendLabelRun: [s substringWithRange: m.range]
                     style: run.style];
      [out addObject: link];
      loc = NSMaxRange(m.range);
    }
    if (loc < s.length) {
      GSHelpText *tail = [GSHelpText new];
      tail.string = [s substringFromIndex: loc];
      tail.style = run.style;
      [out addObject: tail];
    }
  }
  return out;
}

#pragma mark Fallback

/* Garbage-tolerance path (SPEC 76): blank-line-separated chunks become
 * plain paragraphs, no styling applied. */
- (GSHelpDocument *)fallbackDocumentFromSource:(NSString *)source
                                           url:(NSURL *)url
{
  GSHelpSection *root = [GSHelpSection new];
  GSHelpDocument *doc = [GSHelpDocument new];
  doc.sourceType = @"man";
  doc.sourceURL = url;
  doc.rootNode = root;
  doc.metadata = @{ @"command": @"", @"section": @"" };
  doc.title = url.lastPathComponent;

  NSArray *lines =
      [source componentsSeparatedByCharactersInSet:
          [NSCharacterSet newlineCharacterSet]];
  NSMutableArray *chunk = [NSMutableArray new];
  void (^flushChunk)(void) = ^{
    if (chunk.count == 0) {
      return;
    }
    GSHelpParagraph *p = [GSHelpParagraph new];
    GSHelpText *t = [GSHelpText new];
    t.string = [chunk componentsJoinedByString: @" "];
    t.style = GSHelpTextStylePlain;
    [p appendNode: t];
    [root appendNode: p];
    [chunk removeAllObjects];
  };
  for (NSString *line in lines) {
    NSString *l = GSTrim(line);
    if (l.length == 0) {
      flushChunk();
    } else {
      [chunk addObject: l];
    }
  }
  flushChunk();
  return doc;
}

@end

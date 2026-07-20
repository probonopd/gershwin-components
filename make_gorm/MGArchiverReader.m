/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * NSArchiver binary parser + GSC-tagged value parser.
 * Flat parse for lossless round-trip; GSC parser for structured output.
 */
#import "MGArchiverReader.h"
#import "MGTypes.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define PREFIX "GNUstep archive"

static inline uint16_t r16(const uint8_t *b) {
  return (uint16_t)b[0] << 8 | (uint16_t)b[1];
}
static inline uint32_t r32(const uint8_t *b) {
  return (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16
       | (uint32_t)b[2] << 8  | (uint32_t)b[3];
}

static unsigned cSkipOne(const uint8_t *b, unsigned len, unsigned p);
static unsigned cSkipFull(const uint8_t *b, unsigned len, unsigned p);

/* cSkipFull: skip a complete value, recursing for _GSC_ID without xref
 * (skips class hierarchy + nested data). */
static unsigned cSkipFull(const uint8_t *b, unsigned len, unsigned p) {
  if (p >= len) return p;
  uint8_t t = b[p];
  if ((t & 0x1f) == 0x10 && !(t & 0x80)) {
    p++; /* skip ID tag */
    unsigned xl = (t & 0x60) == 0x20 ? 1 : (t & 0x60) == 0x40 ? 2 : (t & 0x60) == 0x60 ? 4 : 0;
    p += xl;
    /* Skip class hierarchy */
    while (p < len) {
      uint8_t ct = b[p];
      if ((ct & 0x1f) != 0x11) break;
      p++;
      unsigned cl = (ct & 0x60) == 0x20 ? 1 : (ct & 0x60) == 0x40 ? 2 : (ct & 0x60) == 0x60 ? 4 : 0;
      p += cl;
      if (p + 2 > len) return len;
      unsigned nl = r16(b + p); p += 2 + nl + 4;
    }
    if (p < len && b[p] == 0) p++;
    /* Skip data: skip values and recursively handle nested _GSC_ID defs */
    int limit = 10000000;
    while (p < len && limit-- > 0) {
      uint8_t ct = b[p];
      if ((ct & 0x1f) == 0x10 && !(ct & 0x80)) {
        unsigned old = p;
        p = cSkipFull(b, len, p);
        if (p <= old) { p++; break; }
        continue;
      }
      unsigned old = p;
      p = cSkipOne(b, len, p);
      if (p <= old) { p++; break; }
    }
    return p;
  }
  return cSkipOne(b, len, p);
}

/* cSkipOne: skip a single GSC-tagged value (no _GSC_ID recursion). */
static unsigned cSkipOne(const uint8_t *b, unsigned len, unsigned p) {
  if (p >= len) return p;
  uint8_t t = b[p++];
  uint8_t m = t & 0x1f;
  uint8_t sz = t & 0x60;
  if (t & 0x80) {
    if (sz == 0x20) return p + 1;
    if (sz == 0x40) return p + 2;
    if (sz == 0x60) return p + 4;
    return p;
  }
  switch (m) {
    case 0x00: return p + 1;
    case 0x01: case 0x02: case 0x0d: return p + 1;
    case 0x03: case 0x04: return p + 2;
    case 0x05: case 0x06: case 0x07: case 0x08:
      if (sz == 0x00) return p + 2;
      if (sz == 0x20) return p + 4;
      if (sz == 0x40) return p + 8;
      return p + 4;
    case 0x09: case 0x0a: return p + 8;
    case 0x0b: return p + 4;
    case 0x0c: return p + 8;
    case 0x10: case 0x11: case 0x17: {
      unsigned xl = (sz == 0x20) ? 1 : (sz == 0x40) ? 2 : (sz == 0x60) ? 4 : 0;
      return p + xl;
    }
    case 0x12: case 0x14: {
      unsigned xl = (sz == 0x20) ? 1 : (sz == 0x40) ? 2 : (sz == 0x60) ? 4 : 0;
      if (p + xl + 2 > len) return len;
      p += xl;
      return p + 2 + r16(b + p);
    }
    case 0x13: {
      unsigned xl = (sz == 0x20) ? 1 : (sz == 0x40) ? 2 : (sz == 0x60) ? 4 : 0;
      return p + xl;
    }
    case 0x15: {
      if (p + 4 > len) return len;
      unsigned cnt = r32(b + p); p += 4;
      /* Read element type tag to determine byte size per element */
      if (p >= len) return len;
      uint8_t et = b[p]; p++;
      unsigned esz = 0;
      switch (et & 0x1f) {
        case 0x01: case 0x02: case 0x0d: esz = 1; break;
        case 0x03: case 0x04: esz = 2; break;
        case 0x05: case 0x06: case 0x07: case 0x08:
          esz = ((et & 0x60) == 0x00) ? 2 : ((et & 0x60) == 0x20) ? 4 : ((et & 0x60) == 0x40) ? 8 : 4;
          break;
        case 0x09: case 0x0a: esz = 8; break;
        case 0x0b: esz = 4; break;
        case 0x0c: esz = 8; break;
        default: esz = 1; break;
      }
      unsigned total = cnt * esz;
      if (p + total > len) total = len - p;
      p += total;
      return p;
    }
    case 0x16: {
      while (p < len) {
        uint8_t ct = b[p];
        if (ct == 0) { p++; break; }
        if ((ct & 0x1f) == 0x15) break;
        unsigned old = p;
        p = cSkipOne(b, len, p);
        if (p <= old) break;
      }
      return p;
    }
    default: return p;
  }
}

/* Read one MGValue from GSC-tagged stream. For _GSC_ID without xref,
 * reads crossref, skips class hierarchy + data via cSkipFull, returns ref MGValue. */
static MGValue *readRawValue(const uint8_t *b, unsigned len, unsigned *posp) {
  if (*posp >= len) return nil;
  unsigned p = *posp;
  uint8_t tag = b[p++];
  uint8_t base = tag & 0x1f;
  uint8_t sz = tag & 0x60;
  MGValue *val = [[MGValue alloc] init];
  val.tag = tag;

  if (tag & 0x80) {
    if (sz != 0x00) {
      if (sz == 0x20) { val.xref = b[p]; p += 1; }
      else if (sz == 0x40) { val.xref = (b[p]<<8)|b[p+1]; p += 2; }
      else if (sz == 0x60) { val.xref = r32(b + p); p += 4; }
    }
    *posp = p; return AUTORELEASE(val);
  }

  switch (base) {
    case 0x00: break;
    case 0x01: if (p < len) { val.intValue = (int64_t)(int8_t)b[p]; p++; } break;
    case 0x02: if (p < len) { val.uintValue = b[p]; p++; } break;
    case 0x0d: if (p < len) { val.boolValue = b[p] != 0; p++; } break;
    case 0x03: case 0x04: {
      if (p + 2 <= len) {
        unsigned v = (b[p]<<8)|b[p+1];
        if (base == 0x03) val.intValue = (int64_t)(int16_t)v;
        else val.uintValue = v;
        p += 2;
      }
      break;
    }
    case 0x05: case 0x06: case 0x07: case 0x08: {
      unsigned nb = (sz == 0x00) ? 2 : (sz == 0x20) ? 4 : (sz == 0x40) ? 8 : 4;
      if (p + nb <= len) {
        uint64_t v = 0;
        for (unsigned i = 0; i < nb; i++) v = (v << 8) | b[p + i];
        p += nb;
        if (base == 0x05 || base == 0x07) {
          if (nb == 2) v = (uint64_t)(int64_t)(int16_t)(uint16_t)v;
          else if (nb == 4) v = (uint64_t)(int64_t)(int32_t)(uint32_t)v;
          val.intValue = (int64_t)v;
        } else val.uintValue = v;
      }
      break;
    }
    case 0x09: if (p + 8 <= len) {
      uint64_t raw = (uint64_t)b[p]<<56|(uint64_t)b[p+1]<<48|(uint64_t)b[p+2]<<40
                   |(uint64_t)b[p+3]<<32|(uint64_t)b[p+4]<<24|(uint64_t)b[p+5]<<16
                   |(uint64_t)b[p+6]<<8|(uint64_t)b[p+7];
      val.intValue = (int64_t)raw; p += 8;
    } break;
    case 0x0a: if (p + 8 <= len) {
      uint64_t raw = (uint64_t)b[p]<<56|(uint64_t)b[p+1]<<48|(uint64_t)b[p+2]<<40
                   |(uint64_t)b[p+3]<<32|(uint64_t)b[p+4]<<24|(uint64_t)b[p+5]<<16
                   |(uint64_t)b[p+6]<<8|(uint64_t)b[p+7];
      val.uintValue = raw; p += 8;
    } break;
    case 0x0b: if (p + 4 <= len) {
      uint32_t bits = r32(b + p); float f; memcpy(&f, &bits, 4);
      val.floatValue = f; p += 4;
    } break;
    case 0x0c: if (p + 8 <= len) {
      uint64_t bits = (uint64_t)b[p]<<56|(uint64_t)b[p+1]<<48|(uint64_t)b[p+2]<<40
                     |(uint64_t)b[p+3]<<32|(uint64_t)b[p+4]<<24|(uint64_t)b[p+5]<<16
                     |(uint64_t)b[p+6]<<8|(uint64_t)b[p+7];
      double d; memcpy(&d, &bits, 8); val.doubleValue = d; p += 8;
    } break;
    case 0x10: case 0x11: case 0x17: {
      unsigned xl = (sz == 0x20) ? 1 : (sz == 0x40) ? 2 : (sz == 0x60) ? 4 : 0;
      if (xl > 0 && p + xl <= len) {
        if (xl == 1) val.xref = b[p];
        else if (xl == 2) val.xref = (b[p]<<8)|b[p+1];
        else if (xl == 4) val.xref = r32(b + p);
        p += xl;
      }
      /* _GSC_ID without xref: skip via cSkipFull (handles class hierarchy + nested data) */
      if (base == 0x10 && !(tag & 0x80)) {
        p = cSkipFull(b, len, p);
      }
      break;
    }
    case 0x12: case 0x14: {
      unsigned xl = (sz == 0x20) ? 1 : (sz == 0x40) ? 2 : (sz == 0x60) ? 4 : 0;
      p += xl;
      if (p + 2 <= len) {
        unsigned sl = r16(b + p); p += 2;
        if (sl > 0 && p + sl <= len) {
          val.stringValue = [[[NSString alloc] initWithBytes:b+p length:sl encoding:NSUTF8StringEncoding] autorelease];
          p += sl;
        }
      }
      break;
    }
    case 0x13: {
      unsigned xl = (sz == 0x20) ? 1 : (sz == 0x40) ? 2 : (sz == 0x60) ? 4 : 0;
      p += xl; break;
    }
    case 0x15: {
      if (p + 4 <= len) {
        unsigned cnt = r32(b + p); p += 4;
        val.children = [NSMutableArray array];
        /* Read element type tag and skip elements as raw bytes */
        if (p >= len) break;
        uint8_t et = b[p]; p++;
        unsigned esz = 0;
        switch (et & 0x1f) {
          case 0x01: case 0x02: case 0x0d: esz = 1; break;
          case 0x03: case 0x04: esz = 2; break;
          case 0x05: case 0x06: case 0x07: case 0x08:
            esz = ((et & 0x60) == 0x00) ? 2 : ((et & 0x60) == 0x20) ? 4 : 8;
            break;
          case 0x09: case 0x0a: esz = 8; break;
          case 0x0b: esz = 4; break;
          case 0x0c: esz = 8; break;
          default: esz = 1; break;
        }
        unsigned total = cnt * esz;
        if (p + total > len) total = len - p;
        /* Store as raw data blob */
        val.objectValue = [NSData dataWithBytes:b+p length:total];
        p += total;
      }
      break;
    }
    case 0x16: {
      val.children = [NSMutableArray array];
      while (p < len) {
        uint8_t ct = b[p];
        if (ct == 0) { p++; break; }
        if ((ct & 0x1f) == 0x15) break;
        unsigned old = p;
        MGValue *child = readRawValue(b, len, &p);
        if (child) [val.children addObject:child];
        if (p <= old) { p++; break; }
      }
      break;
    }
    default: break;
  }
  *posp = p;
  return AUTORELEASE(val);
}

@implementation MGArchiverReader

- (MGArchive *)parseArchiveFromData:(NSData *)data error:(NSError **)error
{
  unsigned pl = strlen(PREFIX);
  unsigned hl = pl + 36;
  if ([data length] < hl) {
    if (error) *error = [NSError errorWithDomain:@"MGReader"
      code:1 userInfo:@{NSLocalizedDescriptionKey: @"File too small"}];
    return nil;
  }
  const uint8_t *b = [data bytes];
  if (memcmp(b, PREFIX, pl)) {
    if (error) *error = [NSError errorWithDomain:@"MGReader"
      code:1 userInfo:@{NSLocalizedDescriptionKey: @"Not a GNUstep archive"}];
    return nil;
  }
  char h[37];
  memcpy(h, b + pl, 36); h[36] = '\0';
  unsigned sv, cc, oc, pc;
  if (sscanf(h, "%x:%x:%x:%x:", &sv, &cc, &oc, &pc) != 4) {
    if (error) *error = [NSError errorWithDomain:@"MGReader"
      code:1 userInfo:@{NSLocalizedDescriptionKey: @"Bad archive header"}];
    return nil;
  }

  MGArchive *archive = [[MGArchive alloc] init];
  archive.systemVersion = sv;
  archive.classCount = cc;
  archive.objectCount = oc;
  archive.pointerCount = pc;
  archive.classDefs = [NSMutableArray array];
  archive.objects = [NSMutableArray array];

  /* Flat parse: find root object with raw data */
  [self _flatParse:data into:archive];

  return AUTORELEASE(archive);
}

- (void)_flatParse:(NSData *)data into:(MGArchive *)archive
{
  const uint8_t *b = [data bytes];
  unsigned len = (unsigned)[data length];
  unsigned p = strlen(PREFIX) + 36;

  while (p < len) {
    if ((b[p] & 0x1f) != 0x10 || (b[p] & 0x80)) { p++; continue; }
    uint8_t tag = b[p]; p++;
    uint32_t oid = 0;
    switch (tag & 0x60) {
      case 0x20: oid = b[p]; p += 1; break;
      case 0x40: oid = r16(b + p); p += 2; break;
      case 0x60: oid = r32(b + p); p += 4; break;
      default: break;
    }
    unsigned ce = p;
    NSString *cn = [self _readClsName:b len:len pos:p end:&ce];
    if (!cn) cn = @"(null)";
    p = ce;
    /* Data from here to EOF (flat parse stores raw for round-trip) */
    /* Find data boundary: next _GSC_ID without xref.
     * Use cSkipOne (NOT cSkipFull) to avoid skipping nested defs. */
    unsigned ds = p;
    unsigned de = len;
    unsigned scan = p;
    while (scan < len) {
      uint8_t ct = b[scan];
      if ((ct & 0x1f) == 0x10 && !(ct & 0x80)) { de = scan; break; }
      unsigned old = scan;
      scan = cSkipOne(b, len, scan);
      if (scan <= old) { scan++; break; }
    }
    MGArchiveObject *obj = [[MGArchiveObject alloc] init];
    obj.objectId = (int32_t)oid;
    obj.className = cn;
    obj.encodedValues = [NSMutableArray array];
    if (de > ds) {
      MGValue *rv = [MGValue valueWithTag:0];
      rv.objectValue = [data subdataWithRange:NSMakeRange(ds, de - ds)];
      [obj.encodedValues addObject:rv];
    }
    [archive.objects addObject:obj]; RELEASE(obj);
    p = de;
  }
}

- (NSString *)_readClsName:(const uint8_t *)b len:(unsigned)len pos:(unsigned)p end:(unsigned *)end
{
  if (p >= len || (b[p] & 0x1f) != 0x11) { *end = p; return nil; }
  NSString *firstName = nil;
  while (p < len && (b[p] & 0x1f) == 0x11) {
    uint8_t tag = b[p]; p++;
    switch (tag & 0x60) {
      case 0x20: p += 1; break;
      case 0x40: r16(b + p); p += 2; break;
      case 0x60: r32(b + p); p += 4; break;
    }
    if (p + 2 > len) { *end = len; return nil; }
    uint16_t nl = (b[p]<<8)|b[p+1]; p += 2;
    if (p + nl + 4 > len) { *end = len; return nil; }
    char buf[nl + 1];
    memcpy(buf, b + p, nl); buf[nl] = '\0';
    p += nl + 4;
    if (!firstName) firstName = [NSString stringWithUTF8String:buf];
  }
  if (p < len && b[p] == 0) p++;
  *end = p;
  return firstName;
}

+ (NSArray *)parseValuesFromRawData:(NSData *)data error:(NSError **)error
{
  const uint8_t *b = [data bytes];
  unsigned len = (unsigned)[data length];
  unsigned pos = 0;
  NSMutableArray *result = [NSMutableArray array];

  while (pos < len) {
    unsigned saved = pos;
    MGValue *val = readRawValue(b, len, &pos);
    if (!val || pos <= saved) {
      if (error) *error = [NSError errorWithDomain:@"MGReader"
        code:1 userInfo:@{NSLocalizedDescriptionKey: @"Parse error"}];
      return nil;
    }
    [result addObject:val];
  }
  return AUTORELEASE([result copy]);
}

@end

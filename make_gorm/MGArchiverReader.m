/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * NSArchiver binary parser.
 * Default mode: flat parse (no AppKit). NSUnarchiver path only
 * with -DRECORDING_CODER (requires GUI).
 */
#import "MGArchiverReader.h"
#ifdef RECORDING_CODER
#import <AppKit/AppKit.h>
#endif
#import "MGTypes.h"
#import <Foundation/Foundation.h>

#define PREFIX "GNUstep archive"

@implementation MGArchiverReader

- (MGArchive *)parseArchiveFromData:(NSData *)data error:(NSError **)error
{
  /* First, parse the header */
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

  /* Flat parse: no GUI dependency */
  [self _flatParse:data into:archive];

#if defined(RECORDING_CODER)
  /* Optional NSUnarchiver path for named property extraction (requires GUI).
   * Disabled by default to avoid window server dependency. */
  @try {
    [NSApplication sharedApplication];
    NSUnarchiver *unarchiver;
    unarchiver = [[NSUnarchiver alloc] initForReadingWithData:data];
    id root = [unarchiver decodeObject];
    RELEASE(unarchiver);
    if (root) {
      NSMutableArray *allObjs = [NSMutableArray array];
      [self _collect:root into:allObjs];
      for (MGArchiveObject *obj in archive.objects) {
        int32_t idx = obj.objectId;
        if (idx > 0 && (NSUInteger)(idx - 1) < [allObjs count])
          obj.decodedObject = [allObjs objectAtIndex:(idx - 1)];
      }
    }
  } @catch (NSException *e) {
    fprintf(stderr, "warning: NSUnarchiver: %s\n", [[e reason] UTF8String]);
  }
#endif

  /* Ensure at least 1 object was found */
  if ([archive.objects count] == 0) {
    archive.objects = [self _flatParseRaw:data];
  }

  return AUTORELEASE(archive);
}

/* Collect all objects reachable from root into array.
 * The order should match object ID ordering (1-indexed). */
- (void)_collect:(id)root into:(NSMutableArray *)arr
{
  if (!root || [arr containsObject:root]) return;
  [arr addObject:root];
  
  if ([root isKindOfClass:[NSArray class]]) {
    for (id obj in (NSArray *)root)
      [self _collect:obj into:arr];
  } else if ([root isKindOfClass:[NSDictionary class]]) {
    for (id key in [(NSDictionary *)root allKeys]) {
      [self _collect:[(NSDictionary *)root objectForKey:key] into:arr];
      [self _collect:key into:arr];
    }
  } else if ([root isKindOfClass:[NSSet class]]) {
    for (id obj in (NSSet *)root)
      [self _collect:obj into:arr];
  }
  
  unsigned cnt = 0;
  Ivar *ivars = class_copyIvarList([root class], &cnt);
  for (unsigned i = 0; i < cnt; i++) {
    const char *type = ivar_getTypeEncoding(ivars[i]);
    if (type && *type == _C_ID) {
      id val = object_getIvar(root, ivars[i]);
      if (val && val != root)
        [self _collect:val into:arr];
    }
  }
  free(ivars);
}

/* Flat binary parse: extract object IDs, class names, and raw data.
 * Scan the GSC stream linearly. Each _GSC_ID without xref starts
 * a new object. The object's data is the raw bytes from after its
 * class hierarchy to the next _GSC_ID (at ANY depth). */
- (void)_flatParse:(NSData *)data into:(MGArchive *)archive
{
  const uint8_t *b = [data bytes];
  unsigned len = (unsigned)[data length];
  unsigned p = strlen(PREFIX) + 36; /* past header */

  while (p < len) {
    /* Find _GSC_ID without xref */
    if ((b[p] & 0x1f) != 0x10 || (b[p] & 0x80)) {
      p = [self _skipToNextObj:b len:len pos:p];
      if (p >= len) break;
    }

    /* Read _GSC_ID + crossref */
    uint8_t tag = b[p]; p++;
    uint32_t oid = 0;
    switch (tag & 0x60) {
      case 0x20: oid = b[p]; p += 1; break;
      case 0x40: oid = r16(b + p); p += 2; break;
      case 0x60: oid = r32(b + p); p += 4; break;
      default: break;
    }

    /* Read class hierarchy */
  unsigned ce = p;
  NSString *cn = [self _readClsName:b len:len pos:p classDefs:archive.classDefs end:&ce];
  if (!cn) cn = @"(null)";
  p = ce;

    /* Find next _GSC_ID to get data boundary */
    unsigned ds = p;
    unsigned de = [self _skipToNextObj:b len:len pos:ds];
    if (de <= ds) de = len;

    MGArchiveObject *obj = [[MGArchiveObject alloc] init];
    obj.objectId = (int32_t)oid;
    obj.className = cn;
    obj.encodedValues = [NSMutableArray array];
    obj.namedProperties = [NSMutableDictionary dictionary];

    if (de > ds) {
      MGValue *rv = [MGValue valueWithTag:0];
      rv.objectValue = [data subdataWithRange:NSMakeRange(ds, de - ds)];
      [obj.encodedValues addObject:rv];
    }

    [archive.objects addObject:obj];
    RELEASE(obj);
    p = de;
  }
}

/* Minimal fallback: just find _GSC_ID tags and record them */
- (NSMutableArray *)_flatParseRaw:(NSData *)data
{
  (void)data;
  return [NSMutableArray array];
}

/* Skip to next _GSC_ID without xref, skipping all values and
 * nested object definitions. This is the core parsing logic. */
- (unsigned)_skipToNextObj:(const uint8_t *)b len:(unsigned)len pos:(unsigned)p
{
  int maxSkips = 10000000;
  while (p < len && maxSkips-- > 0) {
    if ((b[p] & 0x1f) == 0x10 && !(b[p] & 0x80)) {
      return p;
    }
    unsigned old = p;
    p = [self _skipOne:b len:len pos:p];
    if (p <= old) return len;
  }
  return p;
}

/* Skip one GSC-tagged value, recursing through containers.
 * For _GSC_ID without xref, skips the full object definition. */
- (unsigned)_skipOne:(const uint8_t *)b len:(unsigned)len pos:(unsigned)p
{
  if (p >= len) return p;
  uint8_t t = b[p++];
  uint8_t m = t & 0x1f;
  uint8_t sz = t & 0x60;

  if (t & 0x80) return [self _skipXr:b len:len pos:p tag:t];

  switch (m) {
    case 0x01: case 0x02: case 0x0d: return p + 1;
    case 0x03: case 0x04: return p + 2;
    case 0x05: case 0x06: case 0x07: case 0x08:
      if (sz == 0x20) return p + 1;
      if (sz == 0x40) return p + 2;
      if (sz == 0x60) return p + 4;
      return p + 4;
    case 0x09: case 0x0a: return p + 8;
    case 0x0b: return p + 4;
    case 0x0c: return p + 8;
    case 0x10: case 0x11: case 0x17:
      return [self _skipXr:b len:len pos:p tag:t];
    case 0x12: case 0x14: {
      unsigned np = [self _skipXr:b len:len pos:p tag:t];
      if (np + 2 > len || np + 2 < np) return len;
      uint16_t sl = r16(b + np);
      if (np + 2 + sl > len || np + 2 + sl < np) return len;
      return np + 2 + sl;
    }
    case 0x13:
      return [self _skipXr:b len:len pos:p tag:t];
    case 0x15: {
      if (p + 4 > len) return len;
      uint32_t cnt = r32(b + p);
      p += 4;
      int maxElements = 100000;
      for (uint32_t i = 0; i < cnt && p < len && maxElements-- > 0; i++) {
        unsigned old = p;
        p = [self _skipOne:b len:len pos:p];
        if (p <= old) { p = len; break; }
      }
      return p;
    }
    case 0x16: {
      int maxMembers = 1000;
      while (p < len && maxMembers-- > 0) {
        if (p >= len) break;
        uint8_t ct = b[p];
        if (ct == 0) { p++; break; }
        if ((ct & 0x1f) == 0x15) break;
        unsigned old = p;
        p = [self _skipOne:b len:len pos:p];
        if (p <= old) { p = len; break; }
      }
      return p;
    }
    default: return p;
  }
}

- (unsigned)_skipXr:(const uint8_t *)b len:(unsigned)len pos:(unsigned)p tag:(uint8_t)t
{
  (void)b;
  switch (t & 0x60) {
    case 0x20: return p + 1;
    case 0x40: return p + 2;
    case 0x60: return p + 4;
    default: return p;
  }
}

/* Read class hierarchy at pos, registering every class into classDefs.
 * Returns the first (most specific) class name. */
- (NSString *)_readClsName:(const uint8_t *)b len:(unsigned)len pos:(unsigned)p classDefs:(NSMutableArray *)classDefs end:(unsigned *)end
{
  if (p >= len || (b[p] & 0x1f) != 0x11) { *end = p; return nil; }

  NSString *firstName = nil;

  while (p < len && (b[p] & 0x1f) == 0x11) {
    uint8_t tag = b[p]; p++;
    if (p >= len) { *end = len; return nil; }
    p = [self _skipXr:b len:len pos:p tag:tag];
    if (p >= len || p + 2 > len || p + 2 < p) { *end = len; return nil; }
    uint16_t nl = r16(b + p);
    p += 2;
    if (p >= len || p + nl + 4 > len || p + nl + 4 < p) { *end = len; return nil; }
    char buf[nl + 1];
    memcpy(buf, b + p, nl); buf[nl] = '\0';
    p += nl + 4;
    NSString *name = [NSString stringWithUTF8String:buf];
    if (!firstName) firstName = name;

    BOOL found = NO;
    for (MGClassDef *cd in classDefs) {
      if ([cd.name isEqualToString:name]) { found = YES; break; }
    }
    if (!found) {
      MGClassDef *cd = [[MGClassDef alloc] init];
      cd.name = name; cd.version = 0;
      [classDefs addObject:cd]; RELEASE(cd);
    }
  }

  if (p < len && b[p] == 0) p++;
  *end = p;
  return firstName;
}

static inline uint16_t r16(const uint8_t *b) {
  return (uint16_t)b[0] << 8 | (uint16_t)b[1];
}
static inline uint32_t r32(const uint8_t *b) {
  return (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16
       | (uint32_t)b[2] << 8  | (uint32_t)b[3];
}

#pragma mark - Raw data value parser

/* C-level skip for a single GSC value (recurses into arrays/structs).
 * For _GSC_ID without xref, skips class hierarchy + data. */
static unsigned cSkipOne(const uint8_t *b, unsigned len, unsigned p);
static unsigned cSkipFull(const uint8_t *b, unsigned len, unsigned p) {
  if (p >= len) return p;
  uint8_t t = b[p];
  if ((t & 0x1f) == 0x10 && !(t & 0x80)) {
    p++; /* skip ID tag */
    unsigned xl = (t & 0x60) == 0x20 ? 1 : (t & 0x60) == 0x40 ? 2 : (t & 0x60) == 0x60 ? 4 : 0;
    p += xl; /* skip crossref */
    /* Skip class hierarchy */
    while (p < len) {
      uint8_t ct = b[p];
      if ((ct & 0x1f) != 0x11) break;
      p++;
      unsigned cl = ((ct & 0x60) == 0x20) ? 1 : ((ct & 0x60) == 0x40) ? 2 : ((ct & 0x60) == 0x60) ? 4 : 0;
      p += cl;
      if (p + 2 > len) return len;
      unsigned nl = r16(b + p); p += 2 + nl + 4;
    }
    if (p < len && b[p] == 0) p++;
    /* Skip data until next _GSC_ID without xref */
    while (p < len) {
      uint8_t ct = b[p];
      if ((ct & 0x1f) == 0x10 && !(ct & 0x80)) break;
      unsigned old = p;
      p = cSkipOne(b, len, p);
      if (p <= old) { p++; break; }
    }
    return p;
  }
  return cSkipOne(b, len, p);
}

static unsigned cSkipOne(const uint8_t *b, unsigned len, unsigned p) {
  if (p >= len) return p;
  uint8_t t = b[p++];
  uint8_t m = t & 0x1f;
  uint8_t sz = t & 0x60;
  /* _GSC_ID without xref: skip full object def via cSkipFull */
  if (m == 0x10 && !(t & 0x80)) {
    p--;
    return cSkipFull(b, len, p);
  }
  if (t & 0x80) {
    if (sz == 0x20) return p + 1;
    if (sz == 0x40) return p + 2;
    if (sz == 0x60) return p + 4;
    return p;
  }
  switch (m) {
    case 0x00: return p + 1;  /* skip GSC_NONE padding byte */
    case 0x01: case 0x02: case 0x0d: return p + 1;
    case 0x03: case 0x04: return p + 2;
    case 0x05: case 0x06: case 0x07: case 0x08:
      /* Integer width: I16=0x00→2 bytes, I32=0x20→4, I64=0x40→8 */
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
      for (unsigned i = 0; i < cnt && p < len; i++) {
        unsigned old = p;
        p = cSkipOne(b, len, p);
        if (p <= old) break;
      }
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

/* Read one MGValue from raw GSC-tagged data starting at *posp.
 * Updates *posp to after the consumed bytes. Returns nil on error. */
static MGValue *readRawValue(const uint8_t *b, unsigned len, unsigned *posp)
{
  if (*posp >= len) return nil;
  unsigned p = *posp;
  uint8_t tag = b[p++];
  MGValue *val = [[MGValue alloc] init];
  val.tag = tag;
  uint8_t base = tag & 0x1f;
  uint8_t sz = tag & 0x60;

  if (tag & 0x80) {
    if (sz != 0x00) {
      if (sz == 0x20) { val.xref = b[p]; p += 1; }
      else if (sz == 0x40) { val.xref = (b[p]<<8)|b[p+1]; p += 2; }
      else if (sz == 0x60) { val.xref = (b[p]<<24)|(b[p+1]<<16)|(b[p+2]<<8)|b[p+3]; p += 4; }
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
          if (nb == 1) v = (uint64_t)(int64_t)(int8_t)(uint8_t)v;
          else if (nb == 2) v = (uint64_t)(int64_t)(int16_t)(uint16_t)v;
          else if (nb == 4) v = (uint64_t)(int64_t)(int32_t)(uint32_t)v;
          val.intValue = (int64_t)v;
        } else val.uintValue = v;
      }
      break;
    }
    case 0x09: if (p + 8 <= len) {
      uint64_t raw = (uint64_t)b[p]<<56 | (uint64_t)b[p+1]<<48
                   | (uint64_t)b[p+2]<<40 | (uint64_t)b[p+3]<<32
                   | (uint64_t)b[p+4]<<24 | (uint64_t)b[p+5]<<16
                   | (uint64_t)b[p+6]<<8  | (uint64_t)b[p+7];
      val.intValue = (int64_t)raw; p += 8;
    } break;
    case 0x0a: if (p + 8 <= len) {
      uint64_t raw = (uint64_t)b[p]<<56 | (uint64_t)b[p+1]<<48
                   | (uint64_t)b[p+2]<<40 | (uint64_t)b[p+3]<<32
                   | (uint64_t)b[p+4]<<24 | (uint64_t)b[p+5]<<16
                   | (uint64_t)b[p+6]<<8  | (uint64_t)b[p+7];
      val.uintValue = raw; p += 8;
    } break;
    case 0x0b: if (p + 4 <= len) {
      uint32_t bits = r32(b + p); float f; memcpy(&f, &bits, 4);
      val.floatValue = f; p += 4;
    } break;
    case 0x0c: if (p + 8 <= len) {
      uint64_t bits = (uint64_t)b[p]<<56 | (uint64_t)b[p+1]<<48
                    | (uint64_t)b[p+2]<<40 | (uint64_t)b[p+3]<<32
                    | (uint64_t)b[p+4]<<24 | (uint64_t)b[p+5]<<16
                    | (uint64_t)b[p+6]<<8  | (uint64_t)b[p+7];
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
      /* For new object defs (_GSC_ID without xref): skip class hierarchy + data */
      if (base == 0x10 && !(tag & 0x80)) {
        unsigned end = p;
        /* Skip class hierarchy (CLASS tags + _GSC_NONE) */
        while (end < len) {
          uint8_t ct = b[end];
          if ((ct & 0x1f) != 0x11) break;
          end++;
          unsigned cl = ((ct & 0x60) == 0x20) ? 1 : ((ct & 0x60) == 0x40) ? 2 : ((ct & 0x60) == 0x60) ? 4 : 0;
          end += cl;
          if (end + 2 > len) { end = len; break; }
          unsigned nl = r16(b + end); end += 2 + nl + 4;
        }
        if (end < len && b[end] == 0) end++;
        p = end;
        /* Skip data values using cSkipOne (handles _GSC_ID without
         * xref by skipping class hierarchy + data recursively). */
        while (p < len) {
          uint8_t ct = b[p];
          if ((ct & 0x1f) == 0x10 && !(ct & 0x80)) break;
          unsigned old = p;
          p = cSkipOne(b, len, p);
          if (p <= old) { p++; break; }
        }
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
      p += xl;
      break;
    }
    case 0x15: {
      if (p + 4 <= len) {
        unsigned cnt = r32(b + p); p += 4;
        val.children = [NSMutableArray array];
        for (unsigned i = 0; i < cnt && p < len; i++) {
          MGValue *child = readRawValue(b, len, &p);
          if (child) [val.children addObject:child];
          else break;
        }
      }
      break;
    }
    case 0x16: {
      val.children = [NSMutableArray array];
      while (p < len) {
        uint8_t ct = b[p];
        if (ct == 0 || (ct & 0x1f) == 0x15) break;
        if ((ct & 0x1f) == 0x10 && !(ct & 0x80)) break;
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
        code:1 userInfo:@{NSLocalizedDescriptionKey: @"Parse error at offset"}];
      return nil;
    }
    [result addObject:val];
  }

  return AUTORELEASE([result copy]);
}

@end

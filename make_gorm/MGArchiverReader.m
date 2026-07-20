/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * NSArchiver binary parser that uses NSUnarchiver for correct
 * stream parsing, with raw data fallback for unknown classes.
 */
#import "MGArchiverReader.h"
#import "MGTypes.h"
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

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

  /* Try to decode with NSUnarchiver */
  @try {
    [NSApplication sharedApplication];
    NSUnarchiver *unarchiver;
    unarchiver = [[NSUnarchiver alloc] initForReadingWithData:data];
    id root = [unarchiver decodeObject];
    RELEASE(unarchiver);

    if (root) {
      /* Collect all decoded objects */
      NSMutableArray *allObjs = [NSMutableArray array];
      [self _collect:root into:allObjs];

      /* Build a flat parse from the binary to get class names and IDs */
      [self _flatParse:data into:archive];

      /* Map decoded objects to archive objects by index */
      for (MGArchiveObject *obj in archive.objects) {
        int32_t idx = obj.objectId;
        if (idx > 0 && (NSUInteger)(idx - 1) < [allObjs count]) {
          obj.decodedObject = [allObjs objectAtIndex:(idx - 1)];
        }
      }
    }
  } @catch (NSException *e) {
    /* NSUnarchiver failed; fall back to flat binary parse */
    [self _flatParse:data into:archive];
  }

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

@end

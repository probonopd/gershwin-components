/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * NSArchiver binary parser using NSUnarchiver with real display.
 * Decompile uses X11 display; compile is headless (MGCompiler).
 */
#import "MGArchiverReader.h"
#import "MGTypes.h"
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#define PREFIX "GNUstep archive"

static inline uint16_t r16(const uint8_t *b) {
  return (uint16_t)b[0] << 8 | (uint16_t)b[1];
}
static inline uint32_t r32(const uint8_t *b) {
  return (uint32_t)b[0] << 24 | (uint32_t)b[1] << 16
       | (uint32_t)b[2] << 8  | (uint32_t)b[3];
}

@implementation MGArchiverReader

/* Initialize NSApp with the real X11 display server */
+ (void)ensureApp
{
  static BOOL ready = NO;
  if (ready) return;
  ready = YES;
  [[NSUserDefaults standardUserDefaults] setObject:@"xlib" forKey:@"GSBackend"];
  [[NSUserDefaults standardUserDefaults] synchronize];
  [NSApplication sharedApplication];
}

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

  [[self class] ensureApp];

  /* Try NSUnarchiver. On failure (unknown classes), fall back to flat parse. */
  BOOL usedUnarchiver = NO;
  @try {
    NSUnarchiver *unarchiver;
    unarchiver = [[NSUnarchiver alloc] initForReadingWithData:data];
    id root = [unarchiver decodeObject];
    RELEASE(unarchiver);

    if (root) {
      usedUnarchiver = YES;
      NSMutableDictionary *ptrToId = [NSMutableDictionary dictionary];
      NSMutableArray *objList = [NSMutableArray array];
      [self _walk:root map:ptrToId list:objList];

      for (id decoded in objList) {
        MGArchiveObject *ao = [[MGArchiveObject alloc] init];
        ao.objectId = (int32_t)([objList indexOfObject:decoded] + 1);
        ao.decodedObject = decoded;
        ao.className = decoded ? NSStringFromClass([decoded class]) : @"(null)";
        ao.namedProperties = [NSMutableDictionary dictionary];
        if (decoded)
          [self _extractProperties:decoded into:ao.namedProperties ptrToId:ptrToId];
        [archive.objects addObject:ao];
        RELEASE(ao);
      }

      NSMutableSet *seen = [NSMutableSet set];
      for (MGArchiveObject *ao in archive.objects) {
        if (ao.className && ![seen containsObject:ao.className]) {
          [seen addObject:ao.className];
          MGClassDef *cd = [[MGClassDef alloc] init];
          cd.name = ao.className; cd.version = 0;
          [archive.classDefs addObject:cd]; RELEASE(cd);
        }
      }
    }
  } @catch (NSException *e) {
    /* NSUnarchiver failed — fall through to flat parse */
  }

  if (!usedUnarchiver) {
    [self _flatParse:data into:archive];
  }

  return AUTORELEASE(archive);
}

/* Walk decoded objects via ivar introspection, assign IDs in encounter order */
- (void)_walk:(id)obj map:(NSMutableDictionary *)map list:(NSMutableArray *)list
{
  if (!obj) return;
  NSValue *key = [NSValue valueWithPointer:(const void *)obj];
  if ([map objectForKey:key]) return;
  [map setObject:@([list count] + 1) forKey:key];
  [list addObject:obj];

  unsigned cnt = 0;
  Ivar *ivars = class_copyIvarList([obj class], &cnt);
  for (unsigned i = 0; i < cnt; i++) {
    const char *type = ivar_getTypeEncoding(ivars[i]);
    if (type && *type == _C_ID) {
      id val = object_getIvar(obj, ivars[i]);
      [self _walk:val map:map list:list];
    }
  }
  free(ivars);
  if ([obj isKindOfClass:[NSArray class]]) {
    for (id e in (NSArray *)obj) [self _walk:e map:map list:list];
  } else if ([obj isKindOfClass:[NSDictionary class]]) {
    for (id k in [(NSDictionary *)obj allKeys]) {
      [self _walk:[(NSDictionary *)obj objectForKey:k] map:map list:list];
      [self _walk:k map:map list:list];
    }
  } else if ([obj isKindOfClass:[NSSet class]]) {
    for (id e in (NSSet *)obj) [self _walk:e map:map list:list];
  }
}

/* Extract ivar values as named properties with @N references */
- (void)_extractProperties:(id)obj into:(NSMutableDictionary *)props
                    ptrToId:(NSDictionary *)ptrToId
{
  unsigned cnt = 0;
  Ivar *ivars = class_copyIvarList([obj class], &cnt);
  for (unsigned i = 0; i < cnt; i++) {
    NSString *name = [NSString stringWithUTF8String:ivar_getName(ivars[i])];
    const char *type = ivar_getTypeEncoding(ivars[i]);
    if (!type) continue;
    id value = nil;
    ptrdiff_t off = ivar_getOffset(ivars[i]);
    void *ptr = (char *)obj + off;
    switch (*type) {
      case _C_ID: {
        id iv = object_getIvar(obj, ivars[i]);
        if (!iv) { value = [NSNull null]; break; }
        NSValue *k = [NSValue valueWithPointer:(const void *)iv];
        NSNumber *rid = [ptrToId objectForKey:k];
        value = rid ? [NSString stringWithFormat:@"@%d", [rid intValue]] : [iv description];
        break;
      }
      case _C_CLASS: { Class c = *(Class *)ptr; value = c ? NSStringFromClass(c) : (id)[NSNull null]; break; }
      case _C_SEL:   { SEL s = *(SEL *)ptr; value = s ? NSStringFromSelector(s) : (id)[NSNull null]; break; }
      case _C_CHR:  value = [NSNumber numberWithChar:*(char *)ptr]; break;
      case _C_UCHR: value = [NSNumber numberWithUnsignedChar:*(unsigned char *)ptr]; break;
      case _C_SHT:  value = [NSNumber numberWithShort:*(short *)ptr]; break;
      case _C_USHT: value = [NSNumber numberWithUnsignedShort:*(unsigned short *)ptr]; break;
      case _C_INT:  value = [NSNumber numberWithInt:*(int *)ptr]; break;
      case _C_UINT: value = [NSNumber numberWithUnsignedInt:*(unsigned int *)ptr]; break;
      case _C_LNG:  value = [NSNumber numberWithLong:*(long *)ptr]; break;
      case _C_ULNG: value = [NSNumber numberWithUnsignedLong:*(unsigned long *)ptr]; break;
      case _C_LNG_LNG:  value = [NSNumber numberWithLongLong:*(long long *)ptr]; break;
      case _C_ULNG_LNG: value = [NSNumber numberWithUnsignedLongLong:*(unsigned long long *)ptr]; break;
      case _C_FLT:  value = [NSNumber numberWithFloat:*(float *)ptr]; break;
      case _C_DBL:  value = [NSNumber numberWithDouble:*(double *)ptr]; break;
      case _C_BOOL: { BOOL bv = *(BOOL *)ptr; value = [[[MGBoolBox alloc] initWithBool:bv] autorelease]; break; }
      case _C_CHARPTR: {
        char *s = *(char **)ptr;
        value = s ? [NSString stringWithUTF8String:s] : (id)[NSNull null];
        break;
      }
      default: {
        NSUInteger size = 0, align = 0;
        NSGetSizeAndAlignment(type, &size, &align);
        if (size > 0 && size < 4096)
          value = [NSData dataWithBytes:ptr length:size];
        break;
      }
    }
    if (value) [props setObject:value forKey:name];
  }
  free(ivars);
}

/* Flat parse fallback: finds objects via GSC_ID scanning */
- (void)_flatParse:(NSData *)data into:(MGArchive *)archive
{
  const uint8_t *b = [data bytes];
  unsigned len = (unsigned)[data length];
  unsigned p = strlen(PREFIX) + 36;
  unsigned first = 1;
  while (p < len) {
    uint8_t bt = b[p];
    if (bt != 0x30 && bt != 0x50 && bt != 0x70) { p++; continue; }
    if (!first) break;
    first = 0;
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
    unsigned ds = p, de = len;
    MGArchiveObject *obj = [[MGArchiveObject alloc] init];
    obj.objectId = (int32_t)oid;
    obj.className = cn;
    obj.encodedValues = [NSMutableArray array];
    if (de > ds) {
      NSData *raw = [data subdataWithRange:NSMakeRange(ds, de - ds)];
      if ([raw length] > 0 && [raw length] < 5000) {
        NSError *pe = nil;
        NSArray *vals = [[self class] parseValuesFromRawData:raw error:&pe];
        if (vals) [obj.encodedValues addObjectsFromArray:vals];
      }
    }
    [archive.objects addObject:obj]; RELEASE(obj);
    break;
  }
}

- (NSString *)_readClsName:(const uint8_t *)b len:(unsigned)len pos:(unsigned)p end:(unsigned *)end
{
  if (p >= len || (b[p] & 0x1f) != 0x11) { *end = p; return nil; }
  NSString *fn = nil;
  while (p < len && (b[p] & 0x1f) == 0x11) {
    uint8_t tag = b[p]; p++;
    switch (tag & 0x60) {
      case 0x20: p += 1; break;
      case 0x40: p += 2; break;
      case 0x60: p += 4; break;
    }
    if (p + 2 > len) { *end = len; return nil; }
    uint16_t nl = (b[p]<<8)|b[p+1]; p += 2;
    if (p + nl + 4 > len) { *end = len; return nil; }
    char buf[nl + 1];
    memcpy(buf, b + p, nl); buf[nl] = '\0';
    p += nl + 4;
    if (!fn) fn = [NSString stringWithUTF8String:buf];
  }
  if (p < len && b[p] == 0) p++;
  *end = p;
  return fn;
}

/* Scan archive for GSC_CLASS entries and map unknown classes to NSObject.
 * Walks the byte stream skipping _GSC_ID tags and class hierarchies. */
- (void)_mapUnknownClasses:(NSData *)data unarchiver:(NSUnarchiver *)un
{
  const uint8_t *b = [data bytes];
  unsigned len = (unsigned)[data length];
  NSMutableSet *checked = [NSMutableSet set];
  unsigned p = strlen(PREFIX) + 36;
  while (p < len) {
    uint8_t t = b[p];
    if ((t & 0x1f) == 0x11) { /* GSC_CLASS tag */
      p++;
      unsigned xl = ((t & 0x60) == 0x20) ? 1 : ((t & 0x60) == 0x40) ? 2 : ((t & 0x60) == 0x60) ? 4 : 0;
      p += xl;
      if (p + 2 > len) break;
      unsigned nl = (b[p]<<8)|b[p+1]; p += 2;
      if (p + nl > len) break;
      char buf[nl + 1];
      memcpy(buf, b + p, nl); buf[nl] = '\0';
      p += nl + 4;
      NSString *cn = [NSString stringWithUTF8String:buf];
      if (cn && ![checked containsObject:cn]) {
        [checked addObject:cn];
        if (NSClassFromString(cn) == nil)
          [un decodeClassName:cn asClassName:@"NSObject"];
      }
      continue;
    }
    if ((t & 0x1f) == 0x10 && !(t & 0x80)) { /* GSC_ID without xref: skip class hierarchy */
      p++;
      unsigned xl = ((t & 0x60) == 0x20) ? 1 : ((t & 0x60) == 0x40) ? 2 : ((t & 0x60) == 0x60) ? 4 : 0;
      p += xl;
      while (p < len) {
        uint8_t ct = b[p];
        if ((ct & 0x1f) != 0x11) break;
        p++;
        unsigned cl = ((ct & 0x60) == 0x20) ? 1 : ((ct & 0x60) == 0x40) ? 2 : ((ct & 0x60) == 0x60) ? 4 : 0;
        p += cl;
        if (p + 2 > len) break;
        unsigned nl = (b[p]<<8)|b[p+1]; p += 2;
        if (p + nl > len) break;
        char buf[nl + 1];
        memcpy(buf, b + p, nl); buf[nl] = '\0';
        p += nl + 4;
        NSString *cn = [NSString stringWithUTF8String:buf];
        if (cn && ![checked containsObject:cn]) {
          [checked addObject:cn];
          if (NSClassFromString(cn) == nil)
            [un decodeClassName:cn asClassName:@"NSObject"];
        }
      }
      if (p < len && b[p] == 0) p++; /* GSC_NONE */
      continue;
    }
    p++;
  }
}

@end

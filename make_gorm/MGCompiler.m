/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Binary compiler.
 * Writes all objects top-level (sub-objects first, root last).
 * Each object: _GSC_ID + class hierarchy + re-encoded MGValue tree.
 */

#import "MGCompiler.h"
#import "MGTypes.h"
#import "MGArchiverReader.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static uint16_t w16(uint16_t v) { return (v >> 8) | (v << 8); }
static uint32_t w32(uint32_t v) {
  return (v >> 24) | ((v >> 8) & 0xff00) | ((v << 8) & 0xff0000) | (v << 24);
}

@implementation MGCompiler {
  NSMutableSet *_writtenClasses;
  int _classIndex;
}

- (NSData *)compileArchive:(MGArchive *)archive error:(NSError **)error
{
  NSMutableArray *sorted = [[archive.objects sortedArrayUsingComparator:
    ^NSComparisonResult(id a, id b) {
      MGArchiveObject *oa = (MGArchiveObject *)a;
      MGArchiveObject *ob = (MGArchiveObject *)b;
      if (oa.objectId < ob.objectId) return NSOrderedAscending;
      if (oa.objectId > ob.objectId) return NSOrderedDescending;
      return NSOrderedSame;
    }] mutableCopy];

  if ([sorted count] == 0) {
    if (error) *error = [NSError errorWithDomain:@"MGCompiler"
      code:1 userInfo:@{NSLocalizedDescriptionKey: @"No objects"}];
    return nil;
  }

  /* Parse raw data into MGValue trees for all objects */
  for (MGArchiveObject *obj in sorted) {
    if ([obj.encodedValues count] > 0) {
      MGValue *v = [obj.encodedValues objectAtIndex:0];
      if ([v.objectValue isKindOfClass:[NSData class]]) {
        NSError *pe = nil;
        NSArray *parsed = [MGArchiverReader parseValuesFromRawData:(NSData *)v.objectValue
                                                             error:&pe];
        if (parsed) {
          [obj.encodedValues removeAllObjects];
          [obj.encodedValues addObjectsFromArray:parsed];
        }
      }
    }
  }

  /* Separate root (id=1) from sub-objects */
  MGArchiveObject *root = nil;
  NSMutableArray *subs = [NSMutableArray array];
  for (MGArchiveObject *obj in sorted) {
    if (obj.objectId == 1) root = obj;
    else [subs addObject:obj];
  }

  if (!root) root = [sorted objectAtIndex:0];

  _writtenClasses = [NSMutableSet set];
  _classIndex = 0;

  NSMutableData *data = [NSMutableData data];
  unsigned nCls = [self _countUniqueClasses:sorted];
  if (nCls < 1) nCls = 1;

  BOOL hasHexData = NO;
  for (MGArchiveObject *o in sorted) {
    if ([o.namedProperties objectForKey:@"data"]) { hasHexData = YES; break; }
  }

  NSString *hdr = [NSString stringWithFormat:
    @"GNUstep archive%08x:%08x:%08x:%08x:",
    archive.systemVersion, nCls, (unsigned)[sorted count], 0];
  [data appendData:[hdr dataUsingEncoding:NSASCIIStringEncoding]];

  if (hasHexData) {
    for (MGArchiveObject *obj in sorted) {
      [self _writeId:(uint32_t)obj.objectId data:data];
      [self _writeClassHierarchy:obj.className data:data];
      uint8_t none = 0; [data appendBytes:&none length:1];
      id raw = [obj.namedProperties objectForKey:@"data"];
      if ([raw isKindOfClass:[NSData class]])
        [data appendData:(NSData *)raw];
    }
  } else {
    /* MGValue tree approach: convert namedProps to values, write recursively */
    for (MGArchiveObject *obj in sorted) {
      if ([obj.encodedValues count] == 0 && [obj.namedProperties count] > 0) {
        [self _namedPropsToValues:obj];
      }
    }
    /* Find root (id=1) for recursive writing */
    MGArchiveObject *rootObj = nil;
    for (MGArchiveObject *o in sorted)
      if (o.objectId == 1) { rootObj = o; break; }
    if (!rootObj) rootObj = [sorted objectAtIndex:0];
    [self _writeObjectRecursive:rootObj allObjects:archive.objects data:data written:[[NSMutableSet alloc] init]];
  }

  return data;
}

/* Recursively write an object and all objects it references via _GSC_ID. */
- (void)_writeObjectRecursive:(MGArchiveObject *)obj
                  allObjects:(NSArray *)allObjs
                        data:(NSMutableData *)data
                     written:(NSMutableSet *)written
{
  NSNumber *key = @(obj.objectId);
  if ([written containsObject:key]) return;
  [written addObject:key];

  /* _GSC_ID + crossref */
  uint32_t oid = (uint32_t)obj.objectId;
  if (oid <= 0xff) {
    uint8_t tag = 0x30; [data appendBytes:&tag length:1];
    uint8_t v = (uint8_t)oid; [data appendBytes:&v length:1];
  } else {
    uint8_t tag = 0x50; [data appendBytes:&tag length:1];
    uint16_t v = w16((uint16_t)oid); [data appendBytes:&v length:2];
  }

  /* Class hierarchy */
  [self _writeClassHierarchy:obj.className data:data];
  uint8_t none = 0; [data appendBytes:&none length:1];

  /* Write values. For _GSC_ID without xref references, recursively write
   * the referenced object's definition inline (append to same data). */
  for (MGValue *v in obj.encodedValues) {
    uint8_t base = v.tag & GSC_MASK;
    if (base == 0x10 && !(v.tag & 0x80) && v.xref > 0) {
      /* Write the _GSC_ID reference, then recursively write the target object */
      uint8_t refTag = v.tag;
      [data appendBytes:&refTag length:1];
      [self _writeXref:v.xref data:data];

      MGArchiveObject *target = nil;
      for (MGArchiveObject *o in allObjs) {
        if (o.objectId == (int32_t)v.xref) { target = o; break; }
      }
      if (target && ![written containsObject:@(v.xref)]) {
        [self _writeObjectRecursive:target allObjects:allObjs data:data written:written];
      }
    } else {
      [self _writeValue:v data:data];
    }
  }
}

/* Compile using NSArchiver (reconstructs objects, archives them) */
- (NSData *)_compileWithNSArchiver:(MGArchive *)archive
{
  /* Reconstruct objects in ID order */
  NSMutableDictionary *reconstructed = [NSMutableDictionary dictionary];
  id rootObj = nil;
  
  for (MGArchiveObject *ao in archive.objects) {
    Class cls = NSClassFromString(ao.className);
    if (!cls) cls = [NSObject class];
    id obj = [[cls alloc] init];
    if (ao.objectId == 1) rootObj = obj;
    reconstructed[@(ao.objectId)] = obj;
    RELEASE(obj);
  }
  
  if (!rootObj) return nil;
  
  /* Set properties on each object */
  for (MGArchiveObject *ao in archive.objects) {
    id obj = reconstructed[@(ao.objectId)];
    if (!obj) continue;
    for (NSString *key in ao.namedProperties) {
      if ([key isEqualToString:@"class"] || [key isEqualToString:@"data"]) continue;
      id val = [ao.namedProperties objectForKey:key];
      id converted = [self _convertNamedValue:val withMap:reconstructed];
      if (converted) {
        @try { [obj setValue:converted forKey:key]; }
        @catch (NSException *e) { /* skip unsettable properties */ }
      }
    }
  }
  
  /* Archive the root object */
  @try {
    return [NSArchiver archivedDataWithRootObject:rootObj];
  } @catch (NSException *e) {
    return nil;
  }
}

/* Convert a named property value (string, number, etc.) back to an ObjC object */
- (id)_convertNamedValue:(id)val withMap:(NSDictionary *)map
{
  if (!val || [val isKindOfClass:[NSNull class]]) return nil;
  if ([val isKindOfClass:[MGBoolBox class]])
    return [NSNumber numberWithBool:[(MGBoolBox *)val boolValue]];
  if ([val isKindOfClass:[NSNumber class]]) return val;
  if ([val isKindOfClass:[NSString class]]) {
    NSString *s = (NSString *)val;
    if ([s hasPrefix:@"@"] && [s length] > 1) {
      int oid = [[s substringFromIndex:1] intValue];
      id ref = [map objectForKey:@(oid)];
      return ref ? ref : [NSNull null];
    }
    return s;
  }
  if ([val isKindOfClass:[NSArray class]]) {
    NSMutableArray *arr = [NSMutableArray array];
    for (id e in (NSArray *)val) {
      id cv = [self _convertNamedValue:e withMap:map];
      if (cv) [arr addObject:cv];
    }
    return arr;
  }
  if ([val isKindOfClass:[NSDictionary class]]) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    for (id k in [(NSDictionary *)val allKeys]) {
      id cv = [self _convertNamedValue:[(NSDictionary *)val objectForKey:k] withMap:map];
      if (cv) [dict setObject:cv forKey:k];
    }
    return dict;
  }
  return val;
}

- (unsigned)_countUniqueClasses:(NSArray *)objects
{
  NSMutableSet *s = [NSMutableSet set];
  for (MGArchiveObject *obj in objects) {
    if (obj.className) [s addObject:obj.className];
  }
  return (unsigned)[s count];
}

/* Convert namedProperties (from text reader) to MGValue objects */
- (void)_namedPropsToValues:(MGArchiveObject *)obj
{
  /* Sort keys by name (_0, _1, etc.) */
  NSArray *keys = [[obj.namedProperties allKeys] sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *key in keys) {
    if ([key isEqualToString:@"class"] || [key isEqualToString:@"data"]) continue;
    id val = [obj.namedProperties objectForKey:key];
    MGValue *v = [self _propToMGValue:val];
    if (v) [obj.encodedValues addObject:v];
  }
}

- (MGValue *)_propToMGValue:(id)val
{
  if (!val || [val isKindOfClass:[NSNull class]]) {
    return [MGValue valueWithTag:GSC_NONE];
  }
  if ([val isKindOfClass:[MGBoolBox class]]) {
    MGValue *v = [MGValue valueWithTag:GSC_BOOL];
    v.boolValue = [(MGBoolBox *)val boolValue];
    return v;
  }
  if ([val isKindOfClass:[NSNumber class]]) {
    NSNumber *n = (NSNumber *)val;
    const char *t = [n objCType];
    if (t && (*t == 'f' || *t == 'd')) {
      MGValue *v = [MGValue valueWithTag:GSC_DBL];
      v.doubleValue = [n doubleValue];
      return v;
    }
    MGValue *v = [MGValue valueWithTag:GSC_INT | GSC_I32];
    v.intValue = [n intValue];
    return v;
  }
  if ([val isKindOfClass:[NSString class]]) {
    NSString *s = (NSString *)val;
    if ([s hasPrefix:@"@"] && [s length] > 1) {
      int refId = [[s substringFromIndex:1] intValue];
      MGValue *v = [MGValue valueWithTag:GSC_ID | GSC_X_1];
      v.xref = (uint32_t)refId;
      return v;
    }
    MGValue *v = [MGValue valueWithTag:GSC_CHARPTR];
    v.stringValue = s;
    return v;
  }
  if ([val isKindOfClass:[NSArray class]]) {
    MGValue *v = [MGValue valueWithTag:GSC_ARY_B];
    v.children = [NSMutableArray array];
    for (id elem in (NSArray *)val) {
      MGValue *cv = [self _propToMGValue:elem];
      if (cv) [v.children addObject:cv];
    }
    return v;
  }
  if ([val isKindOfClass:[NSDictionary class]]) {
    MGValue *v = [MGValue valueWithTag:GSC_STRUCT_B];
    v.children = [NSMutableArray array];
    for (id key in [(NSDictionary *)val allKeys]) {
      /* Dictionary entries: key = value */
      MGValue *kv = [self _propToMGValue:[(NSDictionary *)val objectForKey:key]];
      if (kv) [v.children addObject:kv];
    }
    return v;
  }
  if ([val isKindOfClass:[NSData class]]) {
    MGValue *v = [MGValue valueWithTag:0];
    v.objectValue = val;
    return v;
  }
  return nil;
}



- (void)_writeClassHierarchy:(NSString *)className data:(NSMutableData *)data
{
  Class cls = NSClassFromString(className);
  if (!cls) cls = [NSObject class];
  while (cls) {
    NSString *cname = NSStringFromClass(cls);
    if ([_writtenClasses containsObject:cname]) break;
    [_writtenClasses addObject:cname];
    _classIndex++;

    if (_classIndex <= 0xff) {
      uint8_t tag = 0x31; [data appendBytes:&tag length:1];
      uint8_t idx = (uint8_t)_classIndex; [data appendBytes:&idx length:1];
    } else {
      uint8_t tag = 0x51; [data appendBytes:&tag length:1];
      uint16_t idx = w16((uint16_t)_classIndex); [data appendBytes:&idx length:2];
    }
    NSData *nd = [cname dataUsingEncoding:NSUTF8StringEncoding];
    uint16_t nl = w16((uint16_t)[nd length]);
    [data appendBytes:&nl length:2]; [data appendData:nd];
    uint32_t ver = 0; [data appendBytes:&ver length:4];

    cls = class_getSuperclass(cls);
    if (cls == Nil) break;
  }
}

/* Write one MGValue as GSC-tagged bytes */
- (void)_writeValue:(MGValue *)v data:(NSMutableData *)data
{
  if (v.rawData) { [data appendData:v.rawData]; return; }

  uint8_t base = v.tag & GSC_MASK;
  uint8_t sz = v.tag & GSC_SIZE;

  if (v.tag & GSC_XREF) {
    uint8_t outTag = base | GSC_XREF | _xrefSz(v.xref);
    [data appendBytes:&outTag length:1];
    [self _writeXref:v.xref data:data];
    return;
  }

  switch (base) {
    case GSC_NONE: { uint8_t t = 0; [data appendBytes:&t length:1]; return; }
    case GSC_CHR: { uint8_t t = v.tag; [data appendBytes:&t length:1]; int8_t x = (int8_t)v.intValue; [data appendBytes:&x length:1]; return; }
    case GSC_UCHR:
    case GSC_BOOL: { uint8_t t = v.tag; [data appendBytes:&t length:1]; uint8_t x = (uint8_t)(base == GSC_BOOL ? (v.boolValue ? 1 : 0) : v.uintValue); [data appendBytes:&x length:1]; return; }
    case GSC_SHT: { uint8_t t = v.tag; [data appendBytes:&t length:1]; int16_t x = w16((int16_t)v.intValue); [data appendBytes:&x length:2]; return; }
    case GSC_USHT: { uint8_t t = v.tag; [data appendBytes:&t length:1]; uint16_t x = w16((uint16_t)v.uintValue); [data appendBytes:&x length:2]; return; }
    case GSC_INT:
    case GSC_UINT:
    case GSC_LNG:
    case GSC_ULNG: {
      uint8_t t = v.tag; [data appendBytes:&t length:1];
      NSUInteger nb = (sz == 0x00) ? 2 : (sz == 0x20) ? 4 : (sz == 0x40) ? 8 : 4;
      BOOL s = (base == GSC_INT || base == GSC_LNG);
      [self _writeInt:(s ? (int64_t)v.intValue : (int64_t)v.uintValue) bytes:nb data:data];
      return;
    }
    case GSC_LNG_LNG: { uint8_t t = v.tag; [data appendBytes:&t length:1]; int64_t x = (int64_t)v.intValue; uint64_t bx = (uint64_t)x; bx = w32((uint32_t)(bx>>32)) | ((uint64_t)w32((uint32_t)bx) << 32); [data appendBytes:&bx length:8]; return; }
    case GSC_ULNG_LNG: { uint8_t t = v.tag; [data appendBytes:&t length:1]; uint64_t x = v.uintValue; [data appendBytes:&x length:8]; return; }
    case GSC_FLT: { uint8_t t = v.tag; [data appendBytes:&t length:1]; float f = v.floatValue; uint32_t bits; memcpy(&bits, &f, 4); bits = w32(bits); [data appendBytes:&bits length:4]; return; }
    case GSC_DBL: { uint8_t t = v.tag; [data appendBytes:&t length:1]; double d = v.doubleValue; uint64_t bits; memcpy(&bits, &d, 8); [data appendBytes:&bits length:8]; return; }
    case GSC_ID:
    case GSC_CLASS:
    case GSC_CID: {
      uint8_t t = base | _xrefSz(v.xref);
      [data appendBytes:&t length:1];
      [self _writeXref:v.xref data:data];
      return;
    }
    case GSC_SEL:
    case GSC_CHARPTR: {
      uint8_t t = v.tag; [data appendBytes:&t length:1];
      [self _writeXref:v.xref data:data];
      NSString *str = v.stringValue ?: @"";
      NSData *sd = [str dataUsingEncoding:NSUTF8StringEncoding];
      uint16_t sl = w16((uint16_t)[sd length]);
      [data appendBytes:&sl length:2];
      [data appendData:sd];
      return;
    }
    case GSC_PTR: {
      uint8_t t = v.tag; [data appendBytes:&t length:1];
      [self _writeXref:v.xref data:data];
      return;
    }
    case GSC_ARY_B: {
      uint8_t t = v.tag; [data appendBytes:&t length:1];
      uint32_t cnt = w32((uint32_t)[v.children count]);
      [data appendBytes:&cnt length:4];
      for (MGValue *child in v.children) {
        [self _writeValue:child data:data];
      }
      return;
    }
    case GSC_STRUCT_B: {
      uint8_t t = v.tag; [data appendBytes:&t length:1];
      for (MGValue *child in v.children) {
        [self _writeValue:child data:data];
      }
      return;
    }
    default:
      /* Emit raw data blob if present */
      if ([v.objectValue isKindOfClass:[NSData class]]) {
        [data appendData:(NSData *)v.objectValue];
      }
      return;
  }
}

- (void)_writeInt:(int64_t)val bytes:(NSUInteger)n data:(NSMutableData *)data
{
  uint8_t buf[8] = {0};
  for (NSUInteger i = 0; i < n; i++)
    buf[i] = (val >> ((n - 1 - i) * 8)) & 0xff;
  [data appendBytes:buf length:n];
}

- (void)_writeXref:(uint32_t)xref data:(NSMutableData *)data
{
  if (xref <= 0xff) { uint8_t v = (uint8_t)xref; [data appendBytes:&v length:1]; }
  else if (xref <= 0xffff) { uint16_t v = w16((uint16_t)xref); [data appendBytes:&v length:2]; }
  else { uint32_t v = w32(xref); [data appendBytes:&v length:4]; }
}

- (void)_writeId:(uint32_t)oid data:(NSMutableData *)data {
  if (oid <= 0xff) {
    uint8_t tag = 0x30; [data appendBytes:&tag length:1];
    uint8_t v = (uint8_t)oid; [data appendBytes:&v length:1];
  } else {
    uint8_t tag = 0x50; [data appendBytes:&tag length:1];
    uint16_t v = w16((uint16_t)oid); [data appendBytes:&v length:2];
  }
}

static uint8_t _xrefSz(uint32_t xref) {
  if (xref <= 0xff) return GSC_X_1;
  if (xref <= 0xffff) return GSC_X_2;
  return GSC_X_4;
}

@end

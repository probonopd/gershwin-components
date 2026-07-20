/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 * Binary compiler. Writes ALL objects with inline class hierarchies
 * and raw data, matching the NSArchiver sequential format.
 */

#import "MGCompiler.h"
#import "MGTypes.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static uint16_t w16(uint16_t v) { return (v >> 8) | (v << 8); }
static uint32_t w32(uint32_t v) {
  return (v >> 24) | ((v >> 8) & 0xff00) | ((v << 8) & 0xff0000) | (v << 24);
}

@implementation MGCompiler
{
  NSMutableSet *_writtenClasses; /* class names already written */
  int _classIndex; /* next crossref index for new classes */
}

- (NSData *)compileArchive:(MGArchive *)archive error:(NSError **)error
{
  NSArray *sorted = [archive.objects sortedArrayUsingComparator:
    ^NSComparisonResult(id a, id b) {
      MGArchiveObject *oa = (MGArchiveObject *)a;
      MGArchiveObject *ob = (MGArchiveObject *)b;
      if (oa.objectId < ob.objectId) return NSOrderedAscending;
      if (oa.objectId > ob.objectId) return NSOrderedDescending;
      return NSOrderedSame;
    }];

  if ([sorted count] == 0) {
    if (error) *error = [NSError errorWithDomain:@"MGCompiler"
      code:1 userInfo:@{NSLocalizedDescriptionKey: @"No objects"}];
    return nil;
  }

  _writtenClasses = [NSMutableSet set];
  _classIndex = 0;

  NSMutableData *data = [NSMutableData data];

  unsigned nObj = (unsigned)[sorted count];
  unsigned nCls = (unsigned)[archive.classDefs count];
  if (nCls < 1) nCls = 1;

  NSString *hdr = [NSString stringWithFormat:
    @"GNUstep archive%08x:%08x:%08x:%08x:",
    archive.systemVersion, nCls, nObj, 0];
  [data appendData:[hdr dataUsingEncoding:NSASCIIStringEncoding]];

  /* Write each object in ID order with its inline class hierarchy */
  for (MGArchiveObject *obj in sorted) {
    [self _writeObject:obj data:data];
  }

  return data;
}

- (void)_writeObject:(MGArchiveObject *)obj data:(NSMutableData *)data
{
  /* _GSC_ID + crossref */
  uint32_t oid = (uint32_t)obj.objectId;
  if (oid <= 0xff) {
    uint8_t tag = 0x30;
    [data appendBytes:&tag length:1];
    uint8_t v = (uint8_t)oid;
    [data appendBytes:&v length:1];
  } else {
    uint8_t tag = 0x50;
    [data appendBytes:&tag length:1];
    uint16_t v = w16((uint16_t)oid);
    [data appendBytes:&v length:2];
  }

  /* Write class hierarchy: object's class + superclasses until already written */
  Class cls = NSClassFromString(obj.className);
  if (!cls) {
    /* Unknown class: write it as a placeholder */
    cls = [NSObject class];
  }
  while (cls) {
    NSString *cname = NSStringFromClass(cls);
    if ([_writtenClasses containsObject:cname]) break;

    [_writtenClasses addObject:cname];
    _classIndex++;

    /* Write CLASS tag + crossref + name + version */
    if (_classIndex <= 0xff) {
      uint8_t tag = 0x31;
      [data appendBytes:&tag length:1];
      uint8_t idx = (uint8_t)_classIndex;
      [data appendBytes:&idx length:1];
    } else {
      uint8_t tag = 0x51;
      [data appendBytes:&tag length:1];
      uint16_t idx = w16((uint16_t)_classIndex);
      [data appendBytes:&idx length:2];
    }

    NSData *nd = [cname dataUsingEncoding:NSUTF8StringEncoding];
    uint16_t nl = w16((uint16_t)[nd length]);
    [data appendBytes:&nl length:2];
    [data appendData:nd];
    uint32_t ver = 0;
    [data appendBytes:&ver length:4];

    cls = class_getSuperclass(cls);
    if (cls == Nil) break;
  }

  /* _GSC_NONE terminates class hierarchy */
  uint8_t none = 0;
  [data appendBytes:&none length:1];

  /* Write raw data blob (contains all object values) */
  id rawObj = [obj.namedProperties objectForKey:@"data"];
  if ([rawObj isKindOfClass:[NSData class]]) {
    [data appendData:(NSData *)rawObj];
  }
}

@end

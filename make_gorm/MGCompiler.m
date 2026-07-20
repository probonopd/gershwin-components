/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MGCompiler.h"
#import "MGTypes.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static uint16_t w16(uint16_t v) { return (v >> 8) | (v << 8); }
@implementation MGCompiler

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

  MGArchiveObject *root = nil;
  for (MGArchiveObject *obj in sorted)
    if (obj.objectId == 1) { root = obj; break; }
  if (!root) root = [sorted objectAtIndex:0];

  return [self _compileRoot:root archive:archive];
}

- (NSData *)_compileRoot:(MGArchiveObject *)root archive:(MGArchive *)archive
{
  NSMutableData *data = [NSMutableData data];

  unsigned nCls = (unsigned)[archive.classDefs count];
  if (nCls < 2) nCls = 2; // at least root + super
  unsigned nObj = (unsigned)[archive.objects count];
  if (nObj < 1) nObj = 1;

  NSString *hdr = [NSString stringWithFormat:
    @"GNUstep archive%08x:%08x:%08x:%08x:",
    archive.systemVersion, nCls, nObj, 0];
  [data appendData:[hdr dataUsingEncoding:NSASCIIStringEncoding]];

  // Write root object: _GSC_ID + 1
  [self _writeId:1 data:data];

  // Write class hierarchy for root using ObjC runtime
  Class cls = NSClassFromString(root.className);
  Class prev = nil;
  int idx = 1;
  while (cls) {
    if (cls == prev) break;
    prev = cls;
    NSString *cname = NSStringFromClass(cls);
    // Find or assign index
    BOOL found = NO;
    for (int i = 0; i < [archive.classDefs count]; i++) {
      MGClassDef *cd = [archive.classDefs objectAtIndex:i];
      if ([cd.name isEqualToString:cname]) { idx = i + 1; found = YES; break; }
    }
    if (!found) {
      // Assign new index
      idx = (int)[archive.classDefs count] + 1;
      MGClassDef *cd = [[MGClassDef alloc] init];
      cd.name = cname; cd.version = 0;
      [archive.classDefs addObject:cd];
      RELEASE(cd);
    }
    [self _writeClassRef:idx name:cname data:data];
    cls = class_getSuperclass(cls);
  }

  // _GSC_NONE terminates class hierarchy
  uint8_t none = 0;
  [data appendBytes:&none length:1];

  // Raw data
  id rawObj = [root.namedProperties objectForKey:@"data"];
  if ([rawObj isKindOfClass:[NSData class]])
    [data appendData:(NSData *)rawObj];

  return data;
}

- (void)_writeId:(uint32_t)oid data:(NSMutableData *)data
{
  if (oid <= 0xff) {
    uint8_t tag = 0x30; [data appendBytes:&tag length:1];
    uint8_t v = (uint8_t)oid; [data appendBytes:&v length:1];
  } else {
    uint8_t tag = 0x50; [data appendBytes:&tag length:1];
    uint16_t v = w16((uint16_t)oid); [data appendBytes:&v length:2];
  }
}

- (void)_writeClassRef:(int)idx name:(NSString *)name data:(NSMutableData *)data
{
  // New class definition (CLASS tag without XREF bit)
  uint8_t tag = 0x31; // CLASS | X_1
  if (idx > 0xff) tag = 0x51; // CLASS | X_2
  [data appendBytes:&tag length:1];
  if (idx <= 0xff) {
    uint8_t v = (uint8_t)idx; [data appendBytes:&v length:1];
  } else {
    uint16_t v = w16((uint16_t)idx); [data appendBytes:&v length:2];
  }
  NSData *nd = [name dataUsingEncoding:NSUTF8StringEncoding];
  uint16_t nl = w16((uint16_t)[nd length]);
  [data appendBytes:&nl length:2];
  [data appendData:nd];
  uint32_t ver = 0; [data appendBytes:&ver length:4];
}

@end

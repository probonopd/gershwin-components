/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MGTypes.h"

@implementation MGValue
+ (instancetype)valueWithTag:(uint8_t)t
{
  MGValue *v = [[self alloc] init];
  v.tag = t;
  return AUTORELEASE(v);
}
@end

@implementation MGClassDef
@end

@implementation MGArchiveObject
@end

@implementation MGArchive
- (MGArchiveObject *)objectWithId:(int32_t)oid
{
  for (MGArchiveObject *obj in self.objects) {
    if (obj.objectId == oid) return obj;
  }
  return nil;
}
@end

@implementation MGBoolBox
- (instancetype)initWithBool:(BOOL)val
{
  self = [super init];
  if (self) _value = val;
  return self;
}
- (BOOL)boolValue { return _value; }
@end

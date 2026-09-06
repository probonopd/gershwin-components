/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EfiVar.h"

@implementation EfiVar
{
  NSString *_lastError;
}

- (NSString *)platformName { return @"unknown"; }
- (BOOL)isAvailable { return NO; }
- (NSString *)ensureAvailable { return @"Not implemented"; }
- (NSString *)readValue:(NSString *)name guid:(NSString *)guid { return nil; }
- (BOOL)writeValue:(NSString *)value name:(NSString *)name guid:(NSString *)guid { return NO; }

- (NSString *)lastError
{
  return _lastError;
}

- (void)setLastError:(NSString *)err
{
  [_lastError release];
  _lastError = [err retain];
}

- (void)dealloc
{
  [_lastError release];
  [super dealloc];
}

@end

EfiVar *
EfiVarCreate(void)
{
#if defined(__linux__)
  return [[EfiVarLinux alloc] init];
#elif defined(__FreeBSD__) || defined(__DragonFly__) || defined(__OpenBSD__) || defined(__NetBSD__)
  return [[EfiVarFreeBSD alloc] init];
#else
  return nil;
#endif
}

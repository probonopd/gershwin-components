/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWOSDetector - OS identification utility.
 *
 * Detection algorithm:
 * 1. Attempt to read /etc/os-release (or overridden path). Parse ID and ID_LIKE.
 * 2. If os-release not available, fall back to `uname -s` for BSD systems.
 * 3. Build search order from primary ID followed by space-separated ID_LIKE entries.
 */

#import "GWOSDetector.h"

// Default path for os-release.
// Can be overridden via setOSReleasePathOverride: for testing.
static NSString *_osReleasePathOverride = nil;

// uname override for testing.
static NSString *_unameOverride = nil;

#pragma mark - Internal Helpers

static NSString *_osReleasePath(void)
{
  return _osReleasePathOverride ?: @"/etc/os-release";
}

static NSString *_getUname(void)
{
  if (_unameOverride)
    return _unameOverride;

  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:@"/usr/bin/uname"];
  [task setArguments:@[@"-s"]];

  NSPipe *pipe = [NSPipe pipe];
  [task setStandardOutput:pipe];

  @try
    {
      [task launch];
      [task waitUntilExit];

      NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
      NSString *result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      if (result)
        {
          result = [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
          return result;
        }
    }
  @catch (NSException *e)
    {
      NSLog(@"GWOSDetector: Failed to run uname: %@", e);
    }

  return @"Unknown";
}

static NSDictionary *_parseOSRelease(NSString *path)
{
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:path])
    return nil;

  NSString *content = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
  if (!content)
    return nil;

  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  NSArray *lines = [content componentsSeparatedByString:@"\n"];

  for (NSString *line in lines)
    {
      NSString *trimmed = [line stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]];
      if ([trimmed length] == 0 || [trimmed hasPrefix:@"#"])
        continue;

      NSRange eqRange = [trimmed rangeOfString:@"="];
      if (eqRange.location == NSNotFound)
        continue;

      NSString *key = [trimmed substringToIndex:eqRange.location];
      NSString *value = [trimmed substringFromIndex:eqRange.location + 1];

      // Strip surrounding quotes
      if ([value hasPrefix:@"\""] && [value hasSuffix:@"\""] && [value length] >= 2)
        value = [value substringWithRange:NSMakeRange(1, [value length] - 2)];
      if ([value hasPrefix:@"'"] && [value hasSuffix:@"'"] && [value length] >= 2)
        value = [value substringWithRange:NSMakeRange(1, [value length] - 2)];

      result[key] = [value lowercaseString];
    }

  return result;
}

#pragma mark - NSCharacterSet Helpers

// A whitespace set we use for splitting ID_LIKE
static NSCharacterSet *_whitespaceSet(void)
{
  return [NSCharacterSet whitespaceCharacterSet];
}

#pragma mark - Public API

@implementation GWOSDetector

+ (void)setOSReleasePathOverride:(NSString *)path
{
  NSLog(@"GWOSDetector -> setOSReleasePathOverride: %@", path);
  _osReleasePathOverride = [path copy];
}

+ (void)setUnameOverride:(NSString *)unameString
{
  NSLog(@"GWOSDetector -> setUnameOverride: %@", unameString);
  _unameOverride = [unameString copy];
}

+ (NSString *)currentOSIdentifier
{
  NSString *osReleasePath = _osReleasePath();
  NSLog(@"GWOSDetector -> currentOSIdentifier: reading %@", osReleasePath);
  NSDictionary *osRelease = _parseOSRelease(osReleasePath);

  if (osRelease)
    {
      NSString *osID = osRelease[@"ID"];
      NSLog(@"GWOSDetector -> parsed os-release ID = %@, ID_LIKE = %@", osID, osRelease[@"ID_LIKE"]);
      if (osID && [osID length] > 0)
        {
          NSLog(@"GWOSDetector <- '%@'", osID);
          return osID;
        }
    }

  // Fallback: use uname -s
  NSLog(@"GWOSDetector -> os-release not available, falling back to uname");
  NSString *unameStr = _getUname();
  NSLog(@"GWOSDetector -> uname -s = '%@'", unameStr);
  if ([unameStr isEqualToString:@"FreeBSD"])
    return @"freebsd";
  if ([unameStr isEqualToString:@"OpenBSD"])
    return @"openbsd";
  if ([unameStr isEqualToString:@"Linux"])
    return @"linux";

  // Last resort
  NSString *result = [unameStr lowercaseString];
  NSLog(@"GWOSDetector <- '%@' (uname fallback)", result);
  return result;
}

+ (NSArray *)osSearchOrder
{
  NSString *osReleasePath = _osReleasePath();
  NSDictionary *osRelease = _parseOSRelease(osReleasePath);

  if (osRelease)
    {
      NSString *osID = osRelease[@"ID"];
      NSString *idLike = osRelease[@"ID_LIKE"];

      NSMutableArray *order = [NSMutableArray array];
      if (osID && [osID length] > 0)
        [order addObject:osID];

      if (idLike && [idLike length] > 0)
        {
          // ID_LIKE can be space-separated
          NSArray *likeEntries = [idLike componentsSeparatedByCharactersInSet:_whitespaceSet()];
          for (NSString *entry in likeEntries)
            {
              NSString *trimmed = [entry stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
              if ([trimmed length] > 0)
                [order addObject:trimmed];
            }
        }

      if ([order count] > 0)
        {
          NSLog(@"GWOSDetector <- osSearchOrder = %@", order);
          return order;
        }
    }

  // Fallback: single-element order from uname
  NSArray *fallback = @[[self currentOSIdentifier]];
  NSLog(@"GWOSDetector <- osSearchOrder (fallback) = %@", fallback);
  return fallback;
}

+ (NSString *)packageManagerFamily
{
  NSString *osID = [self currentOSIdentifier];

  // Keep these lists in sync with the backend factory in GWPackageManager.m.
  if ([osID isEqualToString:@"debian"] ||
      [osID isEqualToString:@"ubuntu"] ||
      [osID isEqualToString:@"devuan"] ||
      [osID isEqualToString:@"kali"] ||
      [osID isEqualToString:@"linuxmint"] ||
      [osID isEqualToString:@"raspbian"] ||
      [osID isEqualToString:@"pop"] ||
      [osID isEqualToString:@"elementary"] ||
      [osID isEqualToString:@"zorin"])
    return @"debian";

  if ([osID isEqualToString:@"arch"] ||
      [osID isEqualToString:@"manjaro"] ||
      [osID isEqualToString:@"endeavouros"] ||
      [osID isEqualToString:@"arcolinux"])
    return @"arch";

  if ([osID isEqualToString:@"freebsd"] ||
      [osID isEqualToString:@"ghostbsd"] ||
      [osID isEqualToString:@"dragonfly"] ||
      // NextBSD is a FreeBSD-derived OS (ID_LIKE=freebsd) and uses the
      // same pkg(8) tooling, so it belongs to the FreeBSD family.
      [osID isEqualToString:@"nextbsd"])
    return @"freebsd";

  if ([osID isEqualToString:@"openbsd"])
    return @"openbsd";

  NSLog(@"GWOSDetector <- packageManagerFamily: unknown OS '%@'", osID);
  return nil;
}

+ (NSString *)currentArchitecture
{
  // AppImages are architecture-specific binaries; we normalize the machine
  // architecture to the two tuples our plist schema understands so a
  // publisher can address x86_64 and aarch64 independently.
  NSString *machine = nil;
  @try
    {
      NSTask *t = [[NSTask alloc] init];
      [t setLaunchPath:@"uname"];
      [t setArguments:@[@"-m"]];
      NSPipe *outPipe = [NSPipe pipe];
      [t setStandardOutput:outPipe];
      [t launch];
      [t waitUntilExit];
      NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
      machine = [[NSString alloc] initWithData:data
                                      encoding:NSUTF8StringEncoding];
      machine = [machine stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
  @catch (NSException *e)
    {
      NSLog(@"GWOSDetector <- currentArchitecture: uname failed: %@", e);
    }

  NSString *m = [machine lowercaseString];
  if ([m isEqualToString:@"x86_64"] || [m isEqualToString:@"amd64"])
    return @"x86_64";
  if ([m isEqualToString:@"aarch64"] || [m isEqualToString:@"arm64"])
    return @"aarch64";

  return machine ? machine : @"unknown";
}

@end

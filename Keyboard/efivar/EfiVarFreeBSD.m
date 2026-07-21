/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EfiVar.h"
#import <unistd.h>
#import <string.h>
#import <errno.h>

#define EFIVAR_PATH "/sbin/efivar"
#define EFIDEV_PATH "/dev/efidev"

@implementation EfiVarFreeBSD

- (NSString *)platformName
{
#if defined(__FreeBSD__)
  return @"FreeBSD";
#elif defined(__DragonFly__)
  return @"DragonFly";
#elif defined(__OpenBSD__)
  return @"OpenBSD";
#elif defined(__NetBSD__)
  return @"NetBSD";
#else
  return @"BSD";
#endif
}

- (BOOL)isAvailable
{
  if (access(EFIVAR_PATH, X_OK) == 0)
    return YES;
  if (access(EFIDEV_PATH, R_OK | W_OK) == 0)
    return YES;
  return NO;
}

- (NSString *)ensureAvailable
{
#if defined(__FreeBSD__)
  if (access(EFIVAR_PATH, X_OK) == 0)
    return nil;

  if (access(EFIDEV_PATH, R_OK | W_OK) == 0)
    {
      // efidev exists but efivar tool missing
      return [NSString stringWithFormat:
                       @"%s not found (install from sysutils/efivar or pkg install efivar)",
                       EFIVAR_PATH];
    }

  // Try to load the efirt kernel module
  int rc = system("kldload efirt 2>/dev/null");
  if (rc != 0)
    rc = system("/sbin/kldload efirt 2>/dev/null");

  if (access(EFIDEV_PATH, R_OK | W_OK) == 0)
    return nil;

  if (access(EFIVAR_PATH, X_OK) == 0)
    return nil;

  return @"UEFI runtime services not available "
         @"(try: sudo kldload efirt, or install sysutils/efivar)";
#else
  return @"Not yet supported on this BSD variant";
#endif
}

- (NSString *)readValue:(NSString *)name guid:(NSString *)guid
{
#if defined(__FreeBSD__)
  NSString *varName = [NSString stringWithFormat:@"%@-%@", guid, name];
  NSString *cmd = [NSString stringWithFormat:@"%s -n '%@' 2>/dev/null",
                            EFIVAR_PATH, varName];
  FILE *fp = popen([cmd UTF8String], "r");
  if (!fp)
    {
      [self setLastError:[NSString stringWithFormat:
                                  @"Failed to run %s", EFIVAR_PATH]];
      return nil;
    }

  char buf[256];
  if (!fgets(buf, sizeof(buf), fp))
    {
      int rc = pclose(fp);
      if (rc != 0)
        [self setLastError:[NSString stringWithFormat:
                                    @"%s -n returned exit code %d",
                                    EFIVAR_PATH, rc]];
      else
        [self setLastError:@"Empty output from efivar"];
      return nil;
    }
  pclose(fp);

  size_t len = strlen(buf);
  if (len == 0)
    {
      [self setLastError:@"Empty output from efivar"];
      return nil;
    }

  // Strip trailing newline
  if (buf[len - 1] == '\n')
    buf[--len] = '\0';

  // Skip 4-byte attribute header if present
  const char *data = buf;
  if (len > 4)
    data = buf + 4;

  NSString *result = [NSString stringWithUTF8String:data];
  if (!result)
    {
      [self setLastError:@"efivar output is not valid UTF-8"];
      return nil;
    }

  [self setLastError:nil];
  return result;
#else
  [self setLastError:@"readValue not implemented on this BSD variant"];
  return nil;
#endif
}

- (BOOL)writeValue:(NSString *)value name:(NSString *)name guid:(NSString *)guid
{
#if defined(__FreeBSD__)
  if (!value || [value length] == 0)
    {
      [self setLastError:@"Empty value"];
      return NO;
    }

  NSString *varName = [NSString stringWithFormat:@"%@-%@", guid, name];
  NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                               @"efivar-XXXXXX"];
  char tmpC[1024];
  strncpy(tmpC, [tmpPath UTF8String], sizeof(tmpC) - 1);
  tmpC[sizeof(tmpC) - 1] = '\0';

  int fd = mkstemp(tmpC);
  if (fd < 0)
    {
      [self setLastError:[NSString stringWithFormat:
                                  @"Failed to create temp file: %s",
                                  strerror(errno)]];
      return NO;
    }

  unsigned char attr[4] = {0x07, 0x00, 0x00, 0x00};
  const char *valC = [value UTF8String];
  size_t valLen = strlen(valC);

  ssize_t w = write(fd, attr, 4);
  if (w != 4) { close(fd); unlink(tmpC); return NO; }
  w = write(fd, valC, valLen);
  if ((size_t)w != valLen) { close(fd); unlink(tmpC); return NO; }
  w = write(fd, "", 1);
  if (w != 1) { close(fd); unlink(tmpC); return NO; }
  close(fd);

  NSString *cmd = [NSString stringWithFormat:
                            "%s -w -n '%@' -f '%s' 2>/dev/null",
                            EFIVAR_PATH, varName, tmpC];
  int rc = system([cmd UTF8String]);
  unlink(tmpC);

  if (rc != 0)
    {
      [self setLastError:[NSString stringWithFormat:
                                  "%s -w returned exit code %d",
                                  EFIVAR_PATH, rc]];
      return NO;
    }

  // Verify by reading back
  NSString *verify = [self readValue:name guid:guid];
  if (!verify)
    {
      [self setLastError:@"Write succeeded but read-back failed"];
      return NO;
    }

  if (![verify isEqualToString:value])
    {
      [self setLastError:[NSString stringWithFormat:
                                  @"Read-back mismatch: wrote '%@', got '%@'",
                                  value, verify]];
      return NO;
    }

  [self setLastError:nil];
  return YES;
#else
  [self setLastError:@"writeValue not implemented on this BSD variant"];
  return NO;
#endif
}

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EfiVar.h"
#import <sys/stat.h>
#import <sys/uio.h>
#import <sys/mount.h>
#import <fcntl.h>
#import <unistd.h>
#import <string.h>
#import <errno.h>

#define EFIVARFS_PATH "/sys/firmware/efi/efivars"
#define EFI_PATH      "/sys/firmware/efi"

static NSString *
efivarfsPath(NSString *name, NSString *guid)
{
  return [NSString stringWithFormat:@"" EFIVARFS_PATH "/%@-%@", name, guid];
}

static BOOL
isDir(const char *path)
{
  struct stat st;
  return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

@implementation EfiVarLinux

- (NSString *)platformName
{
  return @"Linux";
}

- (BOOL)isAvailable
{
  return isDir(EFIVARFS_PATH);
}

- (NSString *)ensureAvailable
{
  if (isDir(EFIVARFS_PATH))
    {
      // Already available, verify it's writable
      int fd = open(EFIVARFS_PATH, O_RDONLY | O_DIRECTORY);
      if (fd < 0)
        return [NSString stringWithFormat:@"Cannot access %s: %s",
                         EFIVARFS_PATH, strerror(errno)];
      close(fd);
      return nil;
    }

  // Check if UEFI is available at all
  if (!isDir(EFI_PATH))
    return @"System not booted in UEFI mode (no /sys/firmware/efi)";

  // Try loading the kernel module
  int rc = system("modprobe efivarfs 2>/dev/null");
  if (rc != 0)
    {
      rc = system("/sbin/modprobe efivarfs 2>/dev/null");
    }
  if (rc != 0)
    {
      rc = system("/usr/bin/modprobe efivarfs 2>/dev/null");
    }

  if (isDir(EFIVARFS_PATH))
    return nil;

  // If directory doesn't exist, create and mount it
  if (!isDir(EFIVARFS_PATH))
    {
      rc = system("mkdir -p " EFIVARFS_PATH " 2>/dev/null");
      if (rc != 0)
        return @"Failed to create " EFIVARFS_PATH;
    }

  rc = system("mount -t efivarfs efivarfs " EFIVARFS_PATH " 2>/dev/null");
  if (rc != 0)
    return @"Failed to mount efivarfs (try: sudo modprobe efivarfs && "
           @"sudo mount -t efivarfs efivarfs " EFIVARFS_PATH ")";

  if (!isDir(EFIVARFS_PATH))
    return @"efivarfs mount point still not available after mount attempt";

  return nil;
}

- (NSString *)readValue:(NSString *)name guid:(NSString *)guid
{
  NSString *path = efivarfsPath(name, guid);

  int fd = open([path UTF8String], O_RDONLY);
  if (fd < 0)
    {
      [self setLastError:[NSString stringWithFormat:@"Cannot open %@: %s",
                                  path, strerror(errno)]];
      return nil;
    }

  char buf[512];
  ssize_t n = read(fd, buf, sizeof(buf) - 1);
  int saved_errno = errno;
  close(fd);

  if (n <= 4)
    {
      if (n < 0)
        [self setLastError:[NSString stringWithFormat:@"Cannot read %@: %s",
                                    path, strerror(saved_errno)]];
      else
        [self setLastError:[NSString stringWithFormat:@"%@: truncated data (%zd bytes)",
                                    path, n]];
      return nil;
    }

  buf[n] = '\0';
  // Verify it looks like valid attribute header
  unsigned char *attr = (unsigned char *)buf;
  if (attr[0] != 0x07 || attr[1] != 0x00 || attr[2] != 0x00 || attr[3] != 0x00)
    {
      [self setLastError:[NSString stringWithFormat:
                                  @"%@: unexpected attribute bytes: %02x %02x %02x %02x",
                                  path, attr[0], attr[1], attr[2], attr[3]]];
    }

  NSString *result = [NSString stringWithUTF8String:buf + 4];

  // Verify it's a valid UTF-8 string
  if (!result)
    {
      [self setLastError:[NSString stringWithFormat:@"%@: value is not valid UTF-8",
                                  path]];
      return nil;
    }

  [self setLastError:nil];
  return result;
}

- (BOOL)writeValue:(NSString *)value name:(NSString *)name guid:(NSString *)guid
{
  if (!value || [value length] == 0)
    {
      [self setLastError:@"Empty value"];
      return NO;
    }

  NSString *path = efivarfsPath(name, guid);
  const char *pathC = [path UTF8String];
  const char *valC = [value UTF8String];
  size_t valLen = strlen(valC);

  if (valLen > 65000)
    {
      [self setLastError:[NSString stringWithFormat:
                                  @"Value too long (%zu bytes, max 65000)", valLen]];
      return NO;
    }

  // Check if variable already exists; if so, remove immutable attr
  struct stat st;
  BOOL exists = (stat(pathC, &st) == 0);

  if (exists)
    {
      // Remove immutable attribute
      NSString *cmd = [NSString stringWithFormat:
                                @"chattr -i \"%s\" 2>/dev/null", pathC];
      system([cmd UTF8String]);
      cmd = [NSString stringWithFormat:
                        @"/usr/bin/chattr -i \"%s\" 2>/dev/null", pathC];
      system([cmd UTF8String]);
      cmd = [NSString stringWithFormat:
                        @"/sbin/chattr -i \"%s\" 2>/dev/null", pathC];
      system([cmd UTF8String]);
    }

  int fd = open(pathC, O_WRONLY | O_CREAT, 0644);
  if (fd < 0)
    {
      [self setLastError:[NSString stringWithFormat:
                                  @"Cannot open %@ for writing: %s",
                                  path, strerror(errno)]];
      return NO;
    }

  // Check write access
  if (access(pathC, W_OK) != 0 && !exists)
    {
      // New file - check directory write permission
      close(fd);
      [self setLastError:[NSString stringWithFormat:
                                  @"No write permission for %@ "
                                  @"(try running with sudo)", path]];
      return NO;
    }

  unsigned char attr[4] = {0x07, 0x00, 0x00, 0x00};
  struct iovec iov[3];
  iov[0].iov_base = attr;
  iov[0].iov_len = 4;
  iov[1].iov_base = (void *)valC;
  iov[1].iov_len = valLen;
  iov[2].iov_base = (void *)"";
  iov[2].iov_len = 1;

  ssize_t written = writev(fd, iov, 3);
  int saved_errno = errno;
  close(fd);

  if (written < 0)
    {
      [self setLastError:[NSString stringWithFormat:
                                  @"Write to %@ failed: %s",
                                  path, strerror(saved_errno)]];
      return NO;
    }

  if ((size_t)written != 4 + valLen + 1)
    {
      [self setLastError:[NSString stringWithFormat:
                                  @"Short write to %@: %zd bytes (expected %zu)",
                                  path, written, 4 + valLen + 1]];
      return NO;
    }

  // Verify by reading back
  NSString *verify = [self readValue:name guid:guid];
  if (!verify)
    {
      [self setLastError:[NSString stringWithFormat:
                                  @"Write verified but read-back failed for %@",
                                  path]];
      return NO;
    }

  if (![verify isEqualToString:value])
    {
      [self setLastError:[NSString stringWithFormat:
                                  @"Read-back verification mismatch for %@: "
                                  @"wrote '%@', read back '%@'",
                                  path, value, verify]];
      return NO;
    }

  [self setLastError:nil];
  return YES;
}

@end

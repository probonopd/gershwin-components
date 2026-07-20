/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWOpenBSDBackend - OpenBSD pkg_add/pkg_delete/pkg_info backend implementation.
 */

#import "GWOpenBSDBackend.h"
#import "GWPackageManager.h"

#pragma mark - Constants

static NSString *const kPkgInfoPath = @"/usr/sbin/pkg_info";
static NSString *const kPkgAddPath = @"/usr/sbin/pkg_add";
static NSString *const kPkgDeletePath = @"/usr/sbin/pkg_delete";
static NSString *const kSudoPath = @"/usr/bin/sudo";

#pragma mark - GWOpenBSDBackend

@implementation GWOpenBSDBackend

@synthesize backendName = _backendName;
@synthesize capturedErrorOutput = _capturedErrorOutput;

#pragma mark - Initialization

- (instancetype)initWithExecutor:(id<GWSystemCommandExecutor>)executor
{
  self = [super init];
  if (self) {
    if (executor) {
      _executor = executor;
    } else {
      _executor = (id<GWSystemCommandExecutor>)[GWSystemCommandExecutor sharedExecutor];
    }
    _backendName = @"OpenBSD (pkg_add)";
  }
  return self;
}

- (instancetype)init
{
  return [self initWithExecutor:nil];
}

#pragma mark - GWPackageManagerBackend - Install

- (BOOL)installPackages:(NSArray<NSString *> *)packageNames
         localFilePaths:(NSArray<NSString *> *)filePaths
               progress:(nullable id<GWInstallProgressHandler>)progressHandler
                  error:(NSError **)error
{
  NSLog(@"GWOpenBSDBackend -> installPackages: %@ (local: %@)", packageNames, filePaths);
  [progressHandler installDidProgress:0.0f message:@"Preparing..."];
  _capturedErrorOutput = @"";

  // Install local files first
  if ([filePaths count] > 0) {
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[@"-A", @"-E", kPkgAddPath]];
    [args addObjectsFromArray:filePaths];

    NSString *capturedStderr = nil;
    int status = [_executor execute:kSudoPath
                          arguments:args
                     stdoutCallback:^(NSString *line) {
                       if ([progressHandler respondsToSelector:@selector(installDidOutputLine:)])
                         [progressHandler installDidOutputLine:line];
                     }
                     stderrCallback:^(NSString *line) {
                       if ([progressHandler respondsToSelector:@selector(installDidOutputLine:)])
                         [progressHandler installDidOutputLine:line];
                     }
               capturedErrorOutput:&capturedStderr];
    _capturedErrorOutput = capturedStderr ?: @"";
    if (status != 0) {
      if (error) {
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"Failed to install local packages with pkg_add"
                                 }];
      }
      return NO;
    }
  }

  [progressHandler installDidProgress:0.05f message:@"Installing packages..."];

  // Install packages from repositories
  if ([packageNames count] > 0) {
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[@"-A", @"-E", kPkgAddPath, @"-V"]];
    [args addObjectsFromArray:packageNames];

    int status = 0;
    int retries = 0;
    const int maxRetries = 30;
    __block BOOL waitingWasReported = NO;

    do
      {
        waitingWasReported = NO;

        if (retries > 0)
          {
            NSLog(@"GWOpenBSDBackend -> lock detected, retrying (%d/%d)...", retries, maxRetries);
            [NSThread sleepForTimeInterval:2.0];
            [progressHandler installDidProgress:0.5f
                                       message:@"Waiting for other installations to finish…"];
          }

        NSLog(@"GWOpenBSDBackend -> pkg_add -V %@", packageNames);
        NSString *capturedStderr = nil;
        status = [_executor execute:kSudoPath
                          arguments:args
                     stdoutCallback:^(NSString *line)
        {
          if ([progressHandler respondsToSelector:@selector(installDidOutputLine:)])
            [progressHandler installDidOutputLine:line];
        }
                     stderrCallback:^(NSString *line)
        {
          if ([progressHandler respondsToSelector:@selector(installDidOutputLine:)])
            [progressHandler installDidOutputLine:line];

          if (!waitingWasReported &&
              [line rangeOfString:@"Package database already locked"
                         options:NSCaseInsensitiveSearch].location != NSNotFound)
            {
              waitingWasReported = YES;
              [progressHandler installDidProgress:0.5f
                                         message:@"Waiting for other installations to finish…"];
            }
        }
capturedErrorOutput:&capturedStderr];
        if (capturedStderr)
          _capturedErrorOutput = [_capturedErrorOutput stringByAppendingString:capturedStderr];

        retries++;
      }
    while (status != 0 && waitingWasReported && retries < maxRetries);

    NSLog(@"GWOpenBSDBackend <- pkg_add exit code: %d", status);
    if (status != 0) {
      if (error) {
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"Failed to install packages with pkg_add"
                                 }];
      }
      return NO;
    }
  }

  [progressHandler installDidProgress:1.0f message:@"Completed"];
  NSLog(@"GWOpenBSDBackend [OK] installPackages succeeded");
  return YES;
}

#pragma mark - GWPackageManagerBackend - Uninstall

- (BOOL)uninstallPackages:(NSArray<NSString *> *)packageNames
                 progress:(nullable id<GWInstallProgressHandler>)progressHandler
                    error:(NSError **)error
{
  NSLog(@"GWOpenBSDBackend -> uninstallPackages: %@", packageNames);
  [progressHandler installDidProgress:0.0f message:@"Preparing..."];
  [progressHandler installDidProgress:0.5f message:@"Removing packages..."];

  if ([packageNames count] > 0) {
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[@"-A", @"-E", kPkgDeletePath]];
    [args addObjectsFromArray:packageNames];

    int status = [_executor execute:kSudoPath arguments:args];
    if (status != 0) {
      if (error) {
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"Failed to remove packages with pkg_delete"
                                 }];
      }
      return NO;
    }
  }

  [progressHandler installDidProgress:1.0f message:@"Completed"];
  NSLog(@"GWOpenBSDBackend [OK] uninstallPackages succeeded");
  return YES;
}

#pragma mark - GWPackageManagerBackend - File Queries

- (NSArray<NSString *> *)filesForPackage:(NSString *)name error:(NSError **)error
{
  NSLog(@"GWOpenBSDBackend -> filesForPackage: %@", name);
  NSString *output = nil;

  int status = [_executor execute:kPkgInfoPath
                        arguments:@[@"-L", name]
                           output:&output];

  if (status != 0) {
    if (error) {
      *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                   code:GWPackageManagerErrorCommandFailed
                               userInfo:@{
                                 NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat:
                                     @"Failed to list files for package '%@'", name]
                               }];
    }
    return nil;
  }

  if ([output length] == 0) {
    NSLog(@"GWOpenBSDBackend <- filesForPackage: %@ -> (empty)", name);
    return @[];
  }

  // Split output into lines, trim whitespace, and filter empty lines.
  // pkg_info -L output has a "Files:" header line which we skip.
  NSArray *lines = [output componentsSeparatedByString:@"\n"];
  NSMutableArray *files = [NSMutableArray arrayWithCapacity:[lines count]];
  BOOL skipHeader = YES;

  for (NSString *line in lines) {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] == 0) {
      continue;
    }
    // Skip the first non-empty line (the "Files:" header)
    if (skipHeader) {
      skipHeader = NO;
      continue;
    }
    [files addObject:trimmed];
  }

  NSLog(@"GWOpenBSDBackend <- filesForPackage: %@ -> %lu files", name, (unsigned long)[files count]);
  return [files copy];
}

- (NSString *)packageOwningFile:(NSString *)path error:(NSError **)error
{
  NSLog(@"GWOpenBSDBackend -> packageOwningFile: %@", path);
  NSString *output = nil;

  int status = [_executor execute:kPkgInfoPath
                        arguments:@[@"-W", path]
                           output:&output];

  if (status != 0) {
    if (error) {
      *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                   code:GWPackageManagerErrorCommandFailed
                               userInfo:@{
                                 NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat:
                                     @"No package owns the file '%@'", path]
                               }];
    }
    return nil;
  }

  // pkg_info -W returns output like:
  // "/usr/local/bin/foo was installed by package foo-1.0"
  // Extract the package name by finding the substring between "by " and the version.
  // First, find the "by " marker.
  NSRange byRange = [output rangeOfString:@"by "];
  if (byRange.location == NSNotFound) {
    return nil;
  }

  NSString *afterBy = [output substringFromIndex:byRange.location + byRange.length];
  afterBy = [afterBy stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceAndNewlineCharacterSet]];

  // The package name is the part before the first space (which separates name from version)
  NSRange spaceRange = [afterBy rangeOfString:@" "];
  if (spaceRange.location == NSNotFound) {
    return nil;
  }

  NSString *pkgNameVer = [afterBy substringToIndex:spaceRange.location];

  // Strip version suffix: look for the last '-' which separates package name
  // from its version (e.g., "foo-1.0" -> "foo")
  NSRange lastDashRange = [pkgNameVer rangeOfString:@"-" options:NSBackwardsSearch];
  if (lastDashRange.location == NSNotFound) {
    NSLog(@"GWOpenBSDBackend <- packageOwningFile: %@ -> %@", path, pkgNameVer);
    return pkgNameVer;
  }

  NSString *pkg = [pkgNameVer substringToIndex:lastDashRange.location];
  NSLog(@"GWOpenBSDBackend <- packageOwningFile: %@ -> %@", path, pkg);
  return pkg;
}

@end

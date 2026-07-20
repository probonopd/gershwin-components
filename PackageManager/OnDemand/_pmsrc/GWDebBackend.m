/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWDebBackend - Debian/APT package manager backend implementation.
 */

#import "GWDebBackend.h"
#import "GWPackageManager.h"

#pragma mark - Constants

static NSString *const kAPTGetPath = @"/usr/bin/apt-get";
static NSString *const kDpkgPath = @"/usr/bin/dpkg";
static NSString *const kSudoPath = @"/usr/bin/sudo";

#pragma mark - GWDebBackend

@implementation GWDebBackend

@synthesize backendName = _backendName;

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
    _backendName = @"Debian (APT)";
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
  NSLog(@"GWDebBackend -> installPackages: %@ (local: %@)", packageNames, filePaths);
  [progressHandler installDidProgress:0.0f message:@"Preparing..."];
  _capturedErrorOutput = @"";

  // Install local .deb files first
  if ([filePaths count] > 0) {
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[@"-A", @"-E", kDpkgPath, @"-i"]];
    [args addObjectsFromArray:filePaths];

    NSLog(@"GWDebBackend -> dpkg -i local packages: %@", filePaths);
    NSString *dpkgStderr = nil;
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
               capturedErrorOutput:&dpkgStderr];
    _capturedErrorOutput = dpkgStderr ?: @"";
    NSLog(@"GWDebBackend <- dpkg exit code: %d", status);
    if (status != 0) {
      if (error) {
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"Failed to install local packages with dpkg"
                                 }];
      }
      return NO;
    }
  }

  [progressHandler installDidProgress:0.05f message:@"Installing packages..."];

  // Install packages from repositories
  if ([packageNames count] > 0) {
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[@"-A", @"-E", kAPTGetPath, @"install", @"-y"]];
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
            NSLog(@"GWDebBackend -> lock detected, retrying (%d/%d)...", retries, maxRetries);
            [NSThread sleepForTimeInterval:2.0];
            [progressHandler installDidProgress:0.5f
                                       message:@"Waiting for other installations to finish…"];
          }

        NSLog(@"GWDebBackend -> apt-get install -y %@", packageNames);
        NSString *aptStderr = nil;
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
              ([line rangeOfString:@"Waiting for cache lock"
                          options:NSCaseInsensitiveSearch].location != NSNotFound ||
               [line rangeOfString:@"Could not get lock"
                          options:NSCaseInsensitiveSearch].location != NSNotFound))
            {
              waitingWasReported = YES;
              [progressHandler installDidProgress:0.5f
                                         message:@"Waiting for other installations to finish…"];
            }
        }
                   capturedErrorOutput:&aptStderr];

        if (aptStderr)
          _capturedErrorOutput = [_capturedErrorOutput stringByAppendingString:aptStderr];

        retries++;
      }
    while (status != 0 && waitingWasReported && retries < maxRetries);

    NSLog(@"GWDebBackend <- apt-get exit code: %d", status);
    if (status != 0) {
      if (error) {
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"Failed to install packages with apt-get"
                                 }];
      }
      return NO;
    }
  }

  [progressHandler installDidProgress:1.0f message:@"Completed"];
  NSLog(@"GWDebBackend [OK] installPackages succeeded");
  return YES;
}

#pragma mark - GWPackageManagerBackend - Uninstall

- (BOOL)uninstallPackages:(NSArray<NSString *> *)packageNames
                 progress:(nullable id<GWInstallProgressHandler>)progressHandler
                    error:(NSError **)error
{
  NSLog(@"GWDebBackend -> uninstallPackages: %@", packageNames);
  [progressHandler installDidProgress:0.0f message:@"Preparing..."];
  [progressHandler installDidProgress:0.5f message:@"Removing packages..."];

  if ([packageNames count] > 0) {
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[@"-A", @"-E", kAPTGetPath, @"remove", @"-y"]];
    [args addObjectsFromArray:packageNames];

    int status = [_executor execute:kSudoPath arguments:args];
    if (status != 0) {
      if (error) {
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"Failed to remove packages with apt-get"
                                 }];
      }
      return NO;
    }
  }

  [progressHandler installDidProgress:1.0f message:@"Completed"];
  NSLog(@"GWDebBackend [OK] uninstallPackages succeeded");
  return YES;
}

#pragma mark - GWPackageManagerBackend - File Queries

- (NSArray<NSString *> *)filesForPackage:(NSString *)name error:(NSError **)error
{
  NSLog(@"GWDebBackend -> filesForPackage: %@", name);
  NSString *output = nil;

  int status = [_executor execute:kDpkgPath
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
    NSLog(@"GWDebBackend <- filesForPackage: %@ -> (empty)", name);
    return @[];
  }

  // Split output into lines, trimming whitespace, and filter empty lines
  NSArray *lines = [output componentsSeparatedByString:@"\n"];
  NSMutableArray *files = [NSMutableArray arrayWithCapacity:[lines count]];

  for (NSString *line in lines) {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] > 0) {
      [files addObject:trimmed];
    }
  }

  NSLog(@"GWDebBackend <- filesForPackage: %@ -> %lu files", name, (unsigned long)[files count]);
  return [files copy];
}

- (NSString *)packageOwningFile:(NSString *)path error:(NSError **)error
{
  NSLog(@"GWDebBackend -> packageOwningFile: %@", path);
  NSString *output = nil;

  int status = [_executor execute:kDpkgPath
                        arguments:@[@"-S", path]
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

  // dpkg -S returns "package-name: /path/to/file", extract the package name
  NSRange colonRange = [output rangeOfString:@":"];
  if (colonRange.location == NSNotFound) {
    return nil;
  }

  NSString *pkg = [output substringToIndex:colonRange.location];
  NSLog(@"GWDebBackend <- packageOwningFile: %@ -> %@", path, pkg);
  return pkg;
}

@end

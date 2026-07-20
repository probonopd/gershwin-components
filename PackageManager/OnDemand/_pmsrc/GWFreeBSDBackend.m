/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWFreeBSDBackend - FreeBSD/pkg package manager backend implementation.
 */

#import "GWFreeBSDBackend.h"
#import "GWPackageManager.h"

#pragma mark - Constants

static NSString *const kPkgPath = @"/usr/sbin/pkg";
static NSString *const kSudoPath = @"/usr/bin/sudo";

#pragma mark - GWFreeBSDBackend

@implementation GWFreeBSDBackend

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
    _backendName = @"FreeBSD (pkg)";
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
  NSLog(@"GWFreeBSDBackend -> installPackages: %@ (local: %@)", packageNames, filePaths);
  [progressHandler installDidProgress:0.0f message:@"Preparing..."];
  _capturedErrorOutput = @"";

  // Install local packages first
  if ([filePaths count] > 0) {
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[@"-A", @"-E", kPkgPath, @"add", @"-f"]];
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
                                     @"Failed to install local packages with pkg add"
                                 }];
      }
      return NO;
    }
  }

  [progressHandler installDidProgress:0.05f message:@"Installing packages..."];

  // Install packages from repositories
  if ([packageNames count] > 0) {
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[@"-A", @"-E", kPkgPath, @"install", @"-y"]];
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
            NSLog(@"GWFreeBSDBackend -> lock detected, retrying (%d/%d)...", retries, maxRetries);
            [NSThread sleepForTimeInterval:2.0];
            [progressHandler installDidProgress:0.5f
                                       message:@"Waiting for other installations to finish…"];
          }

        NSLog(@"GWFreeBSDBackend -> pkg install -y %@", packageNames);
        NSString *capturedStderr = nil;
        status = [_executor execute:kSudoPath
                          arguments:args
                     stdoutCallback:^(NSString *line) {
                       if ([progressHandler respondsToSelector:@selector(installDidOutputLine:)])
                         [progressHandler installDidOutputLine:line];
                     }
                     stderrCallback:^(NSString *line) {
                       if ([progressHandler respondsToSelector:@selector(installDidOutputLine:)])
                         [progressHandler installDidOutputLine:line];

                       if (!waitingWasReported &&
                           [line rangeOfString:@"database is locked"
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

    NSLog(@"GWFreeBSDBackend <- pkg exit code: %d", status);
    if (status != 0) {
      if (error) {
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"Failed to install packages with pkg install"
                                 }];
      }
      return NO;
    }
  }

  [progressHandler installDidProgress:1.0f message:@"Completed"];
  NSLog(@"GWFreeBSDBackend [OK] installPackages succeeded");
  return YES;
}

#pragma mark - GWPackageManagerBackend - Uninstall

- (BOOL)uninstallPackages:(NSArray<NSString *> *)packageNames
                 progress:(nullable id<GWInstallProgressHandler>)progressHandler
                    error:(NSError **)error
{
  NSLog(@"GWFreeBSDBackend -> uninstallPackages: %@", packageNames);
  [progressHandler installDidProgress:0.0f message:@"Preparing..."];
  [progressHandler installDidProgress:0.5f message:@"Removing packages..."];

  if ([packageNames count] > 0) {
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[@"-A", @"-E", kPkgPath, @"delete", @"-y"]];
    [args addObjectsFromArray:packageNames];

    int status = [_executor execute:kSudoPath arguments:args];
    if (status != 0) {
      if (error) {
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"Failed to remove packages with pkg delete"
                                 }];
      }
      return NO;
    }
  }

  [progressHandler installDidProgress:1.0f message:@"Completed"];
  NSLog(@"GWFreeBSDBackend [OK] uninstallPackages succeeded");
  return YES;
}

#pragma mark - GWPackageManagerBackend - File Queries

- (NSArray<NSString *> *)filesForPackage:(NSString *)name error:(NSError **)error
{
  NSLog(@"GWFreeBSDBackend -> filesForPackage: %@", name);
  NSString *output = nil;

  int status = [_executor execute:kPkgPath
                        arguments:@[@"info", @"-l", name]
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
    NSLog(@"GWFreeBSDBackend <- filesForPackage: %@ -> (empty)", name);
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

  NSLog(@"GWFreeBSDBackend <- filesForPackage: %@ -> %lu files", name, (unsigned long)[files count]);
  return [files copy];
}

- (NSString *)packageOwningFile:(NSString *)path error:(NSError **)error
{
  NSLog(@"GWFreeBSDBackend -> packageOwningFile: %@", path);
  NSString *output = nil;

  int status = [_executor execute:kPkgPath
                        arguments:@[@"which", path]
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

  // pkg which returns "package-name was installed by package package-name"
  // Extract just the package name from the output
  NSArray *components = [output componentsSeparatedByCharactersInSet:
    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([components count] >= 6) {
    NSString *pkg = components[5];
    NSLog(@"GWFreeBSDBackend <- packageOwningFile: %@ -> %@", path, pkg);
    return pkg;
  }

  NSLog(@"GWFreeBSDBackend <- packageOwningFile: %@ -> (not found)", path);
  return nil;
}

@end

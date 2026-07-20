/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWArchBackend - Arch Linux (Pacman) package manager backend implementation.
 */

#import "GWArchBackend.h"
#import "GWPackageManager.h"

#pragma mark - Constants

static NSString *const kPacmanPath = @"/usr/bin/pacman";
static NSString *const kSudoPath = @"/usr/bin/sudo";

#pragma mark - GWArchBackend

@implementation GWArchBackend

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
    _backendName = @"Arch Linux (Pacman)";
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
  [progressHandler installDidProgress:0.0f message:@"Preparing..."];
  _capturedErrorOutput = @"";

  // Install local .pkg.tar files first
  if ([filePaths count] > 0) {
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[@"-A", @"-E", kPacmanPath, @"-U", @"--noconfirm"]];
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
                                     @"Failed to install local packages with pacman -U"
                                 }];
      }
      return NO;
    }
  }

  [progressHandler installDidProgress:0.05f message:@"Installing packages..."];

  // Install packages from repositories
  if ([packageNames count] > 0) {
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[@"-A", @"-E", kPacmanPath, @"-S", @"--noconfirm"]];
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
            NSLog(@"GWArchBackend -> lock detected, retrying (%d/%d)...", retries, maxRetries);
            [NSThread sleepForTimeInterval:2.0];
            [progressHandler installDidProgress:0.5f
                                       message:@"Waiting for other installations to finish…"];
          }

        NSLog(@"GWArchBackend -> pacman -S --noconfirm %@", packageNames);
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
                           [line rangeOfString:@"unable to lock database"
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

    NSLog(@"GWArchBackend <- pacman exit code: %d", status);
    if (status != 0) {
      if (error) {
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"Failed to install packages with pacman -S"
                                 }];
      }
      return NO;
    }
  }

  [progressHandler installDidProgress:1.0f message:@"Completed"];
  NSLog(@"GWArchBackend [OK] installPackages succeeded");
  return YES;
}

#pragma mark - GWPackageManagerBackend - Uninstall

- (BOOL)uninstallPackages:(NSArray<NSString *> *)packageNames
                 progress:(nullable id<GWInstallProgressHandler>)progressHandler
                    error:(NSError **)error
{
  NSLog(@"GWArchBackend -> uninstallPackages: %@", packageNames);
  [progressHandler installDidProgress:0.0f message:@"Preparing..."];
  [progressHandler installDidProgress:0.5f message:@"Removing packages..."];

  if ([packageNames count] > 0) {
    NSMutableArray *args = [NSMutableArray arrayWithArray:@[@"-A", @"-E", kPacmanPath, @"-R", @"--noconfirm"]];
    [args addObjectsFromArray:packageNames];

    int status = [_executor execute:kSudoPath arguments:args];
    if (status != 0) {
      if (error) {
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                     code:GWPackageManagerErrorCommandFailed
                                 userInfo:@{
                                   NSLocalizedDescriptionKey:
                                     @"Failed to remove packages with pacman -R"
                                 }];
      }
      return NO;
    }
  }

  [progressHandler installDidProgress:1.0f message:@"Completed"];
  NSLog(@"GWArchBackend [OK] uninstallPackages succeeded");
  return YES;
}

#pragma mark - GWPackageManagerBackend - File Queries

- (NSArray<NSString *> *)filesForPackage:(NSString *)name error:(NSError **)error
{
  NSLog(@"GWArchBackend -> filesForPackage: %@", name);
  NSString *output = nil;

  int status = [_executor execute:kPacmanPath
                        arguments:@[@"-Ql", name]
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
    NSLog(@"GWArchBackend <- filesForPackage: %@ -> (empty)", name);
    return @[];
  }

  // pacman -Ql returns "package-name /path/to/file", extract the second column
  NSArray *lines = [output componentsSeparatedByString:@"\n"];
  NSMutableArray *files = [NSMutableArray arrayWithCapacity:[lines count]];

  for (NSString *line in lines) {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed length] > 0) {
      // Split on whitespace, second component is the file path
      NSArray *components = [trimmed componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
      if ([components count] >= 2) {
        [files addObject:components[1]];
      }
    }
  }

  NSLog(@"GWArchBackend <- filesForPackage: %@ -> %lu files", name, (unsigned long)[files count]);
  return [files copy];
}

- (NSString *)packageOwningFile:(NSString *)path error:(NSError **)error
{
  NSLog(@"GWArchBackend -> packageOwningFile: %@", path);
  NSString *output = nil;

  int status = [_executor execute:kPacmanPath
                        arguments:@[@"-Qo", path]
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

  // pacman -Qo returns "path is owned by package-name version"
  // Extract the package name (5th whitespace-delimited word if "is owned by" pattern)
  // Example: "/usr/bin/foo is owned by foo-pkg 1.0-1"
  NSArray *components = [output componentsSeparatedByCharactersInSet:
    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSUInteger count = [components count];

  // Look for the "owned by" pattern: word at index 2 is "is", index 3 is "owned", index 4 is "by"
  // The package name is at index 5
  for (NSUInteger i = 0; i < count - 4; i++) {
    if ([components[i + 2] isEqualToString:@"is"] &&
        [components[i + 3] isEqualToString:@"owned"] &&
        [components[i + 4] isEqualToString:@"by"]) {
      NSString *pkg = components[i + 5];
      NSLog(@"GWArchBackend <- packageOwningFile: %@ -> %@", path, pkg);
      return pkg;
    }
  }

  NSLog(@"GWArchBackend <- packageOwningFile: %@ -> (not found)", path);
  return nil;
}

@end

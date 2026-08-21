/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWFreeBSDBackend - FreeBSD/pkg package manager backend implementation.
 */

#import "GWFreeBSDBackend.h"
#import "GWPackageManager.h"
#import "GWSudoHelper.h"

#pragma mark - Constants

static NSString *const kPkgPath = @"/usr/sbin/pkg";

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
    NSArray *sudoArgs = GWSudoArgPrefix();
    NSString *launchPath = ([sudoArgs count] > 0) ? GWSudoPath() : kPkgPath;
    NSMutableArray *args = [NSMutableArray arrayWithArray:sudoArgs];
    [args addObject:kPkgPath];
    [args addObjectsFromArray:@[@"add", @"-f"]];
    [args addObjectsFromArray:filePaths];

    NSString *capturedStderr = nil;
    int status = [_executor execute:launchPath
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
    NSArray *sudoArgs = GWSudoArgPrefix();
    NSString *launchPath = ([sudoArgs count] > 0) ? GWSudoPath() : kPkgPath;
    NSMutableArray *args = [NSMutableArray arrayWithArray:sudoArgs];
    [args addObject:kPkgPath];
    [args addObjectsFromArray:@[@"install", @"-y"]];
    [args addObjectsFromArray:packageNames];

    int status = 0;
    int attempts = 0;
    const int maxAttempts = 30;
    __block BOOL lockSeen = NO;
    BOOL repoUpdateDone = NO;

    while (attempts < maxAttempts)
      {
        lockSeen = NO;

        if (attempts > 0)
          {
            [NSThread sleepForTimeInterval:2.0];
            [progressHandler installDidProgress:0.5f
                                       message:@"Waiting for other installations to finish…"];
          }

        NSLog(@"GWFreeBSDBackend -> pkg install -y %@", packageNames);
        NSString *capturedStderr = nil;
        status = [_executor execute:launchPath
                          arguments:args
                     stdoutCallback:^(NSString *line) {
                        if ([progressHandler respondsToSelector:@selector(installDidOutputLine:)])
                          [progressHandler installDidOutputLine:line];
                      }
                     stderrCallback:^(NSString *line) {
                        if ([progressHandler respondsToSelector:@selector(installDidOutputLine:)])
                          [progressHandler installDidOutputLine:line];

                        if (!lockSeen &&
                            [line rangeOfString:@"database is locked"
                                       options:NSCaseInsensitiveSearch].location != NSNotFound)
                          {
                            lockSeen = YES;
                            [progressHandler installDidProgress:0.5f
                                                       message:@"Waiting for other installations to finish…"];
                          }
                      }
                capturedErrorOutput:&capturedStderr];
        if (capturedStderr)
          _capturedErrorOutput = [_capturedErrorOutput stringByAppendingString:capturedStderr];

        if (status == 0)
          break;

        // The repository catalog may be missing or stale on a fresh install
        // ("Repository ... cannot be opened. 'pkg update' required"). Bring it
        // up to date once and retry, instead of failing outright.
        if (!repoUpdateDone && [self _repoNeedsUpdate:capturedStderr])
          {
            repoUpdateDone = YES;
            NSLog(@"GWFreeBSDBackend -> repo catalog missing/stale, running 'pkg update'");
            [self _runPkgUpdate:progressHandler];
            attempts++;
            continue;
          }

        // Transient lock contention: back off and retry.
        if (lockSeen)
          {
            NSLog(@"GWFreeBSDBackend -> lock detected, retrying (%d/%d)...", attempts, maxAttempts);
            attempts++;
            continue;
          }

        // Any other failure is fatal.
        break;
      }

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
    NSArray *sudoArgs = GWSudoArgPrefix();
    NSString *launchPath = ([sudoArgs count] > 0) ? GWSudoPath() : kPkgPath;
    NSMutableArray *args = [NSMutableArray arrayWithArray:sudoArgs];
    [args addObject:kPkgPath];
    [args addObjectsFromArray:@[@"delete", @"-y"]];
    [args addObjectsFromArray:packageNames];

    int status = [_executor execute:launchPath arguments:args];
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

#pragma mark - Repository Catalog Maintenance

/// Detect the "catalog missing/stale" condition from pkg's stderr.
/// pkg prints e.g. "Repository FreeBSD cannot be opened. 'pkg update' required"
/// or "the repository ... needs to be updated" when the local catalog is absent
/// or out of date; in both cases a `pkg update` recovers.
- (BOOL)_repoNeedsUpdate:(NSString *)stderrOutput
{
  if (!stderrOutput || [stderrOutput length] == 0)
    return NO;
  NSArray *signatures = @[@"cannot be opened",
                          @"pkg update",
                          @"needs to be updated",
                          @"needs updating",
                          @"repository cannot"];
  NSString *lower = [stderrOutput lowercaseString];
  for (NSString *sig in signatures)
    {
      if ([lower rangeOfString:sig].location != NSNotFound)
        return YES;
    }
  return NO;
}

/// Refresh the package catalog so repository installs can proceed.
- (void)_runPkgUpdate:(nullable id<GWInstallProgressHandler>)progress
{
  [progress installDidProgress:0.03f message:@"Updating package catalog..."];
  NSArray *sudoArgs = GWSudoArgPrefix();
  NSString *launchPath = ([sudoArgs count] > 0) ? GWSudoPath() : kPkgPath;
  NSMutableArray *args = [NSMutableArray arrayWithArray:sudoArgs];
  [args addObject:kPkgPath];
  [args addObject:@"update"];
  [_executor execute:launchPath
            arguments:args
       stdoutCallback:^(NSString *line) {
         if ([progress respondsToSelector:@selector(installDidOutputLine:)])
           [progress installDidOutputLine:line];
       }
       stderrCallback:^(NSString *line) {
         if ([progress respondsToSelector:@selector(installDidOutputLine:)])
           [progress installDidOutputLine:line];
       }
  capturedErrorOutput:NULL];
}

@end

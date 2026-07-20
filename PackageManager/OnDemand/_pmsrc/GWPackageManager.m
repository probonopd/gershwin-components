/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWPackageManager - Public API implementation.
 *
 * Provides a unified interface for package management operations across
 * multiple OS platforms. Automatically selects the correct backend based
 * on the current OS, or accepts an injected backend for testing.
 */

#import "GWPackageManager.h"
#import "GWPackageManagerBackend.h"
#import "GWOSDetector.h"
#import "GWPackageInstallSpec.h"

// Backend imports — included at compile time; only the relevant one is used
#import "GWDebBackend.h"
#import "GWArchBackend.h"
#import "GWFreeBSDBackend.h"
#import "GWOpenBSDBackend.h"

#pragma mark - GWPackageManager (Private)

@interface GWPackageManager ()
@property (readwrite, strong) id<GWPackageManagerBackend> backend;
@end

#pragma mark - Backend Factory

static id<GWPackageManagerBackend> _createBackend(void)
{
  NSString *osID = [GWOSDetector currentOSIdentifier];

  if ([osID isEqualToString:@"debian"] ||
      [osID isEqualToString:@"ubuntu"] ||
      [osID isEqualToString:@"devuan"] ||
      [osID isEqualToString:@"kali"] ||
      [osID isEqualToString:@"linuxmint"] ||
      [osID isEqualToString:@"raspbian"] ||
      [osID isEqualToString:@"pop"] ||
      [osID isEqualToString:@"elementary"] ||
      [osID isEqualToString:@"zorin"])
    {
      return [[GWDebBackend alloc] init];
    }

  if ([osID isEqualToString:@"arch"] ||
      [osID isEqualToString:@"manjaro"] ||
      [osID isEqualToString:@"endeavouros"] ||
      [osID isEqualToString:@"arcolinux"])
    {
      return [[GWArchBackend alloc] init];
    }

  if ([osID isEqualToString:@"freebsd"] ||
      [osID isEqualToString:@"ghostbsd"] ||
      [osID isEqualToString:@"dragonfly"])
    {
      return [[GWFreeBSDBackend alloc] init];
    }

  if ([osID isEqualToString:@"openbsd"])
    {
      return [[GWOpenBSDBackend alloc] init];
    }

  // Fallback: try debian-style as most common
  NSLog(@"GWPackageManager: Unknown OS '%@', falling back to Debian backend", osID);
  return [[GWDebBackend alloc] init];
}

#pragma mark - GWPackageManager Implementation

@implementation GWPackageManager

static GWPackageManager *sharedManager = nil;

+ (GWPackageManager *)sharedManager
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedManager = [[self alloc] _initWithAutomaticBackend];
  });
  return sharedManager;
}

- (instancetype)_initWithAutomaticBackend
{
  self = [super init];
  if (self)
    {
      NSLog(@"GWPackageManager -> detecting OS and selecting backend...");
      _backend = _createBackend();
      NSLog(@"GWPackageManager -> selected backend: %@", [_backend backendName]);
    }
  return self;
}

- (instancetype)initWithBackend:(id<GWPackageManagerBackend>)backend
{
  self = [super init];
  if (self)
    {
      if (backend)
        {
          NSLog(@"GWPackageManager -> initWithBackend: %@", [backend backendName]);
          _backend = backend;
        }
      else
        {
          NSLog(@"GWPackageManager -> initWithBackend: nil — auto-detecting backend");
          _backend = _createBackend();
          NSLog(@"GWPackageManager -> selected backend: %@", [_backend backendName]);
        }
    }
  return self;
}

#pragma mark - Basic Operations (no progress)

- (BOOL)installPackages:(NSArray<NSString *> *)packageNames
                  error:(NSError **)error
{
  NSLog(@"GWPackageManager -> installPackages (no-progress): %@", packageNames);
  return [self installPackages:packageNames
                localFilePaths:nil
                     progress:nil
                        error:error];
}

- (BOOL)installPackages:(NSArray<NSString *> *)packageNames
        localFilePaths:(NSArray<NSString *> *)filePaths
                  error:(NSError **)error
{
  NSLog(@"GWPackageManager -> installPackages (no-progress): %@ (local: %@)", packageNames, filePaths);
  return [self installPackages:packageNames
                localFilePaths:filePaths
                     progress:nil
                        error:error];
}

- (BOOL)uninstallPackages:(NSArray<NSString *> *)packageNames
                    error:(NSError **)error
{
  NSLog(@"GWPackageManager -> uninstallPackages (no-progress): %@", packageNames);
  return [self uninstallPackages:packageNames
                       progress:nil
                          error:error];
}

#pragma mark - Operations with Progress

- (BOOL)installPackages:(NSArray<NSString *> *)packageNames
        localFilePaths:(NSArray<NSString *> *)filePaths
             progress:(id<GWInstallProgressHandler>)progressHandler
                error:(NSError **)error
{
  NSLog(@"GWPackageManager -> installPackages (backend): %@ (local: %@)", packageNames, filePaths);

  if (!_backend)
    {
      NSLog(@"GWPackageManager [FAIL] installPackages: no backend available");
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                    code:GWPackageManagerErrorBackendUnavailable
                                userInfo:@{
                                  NSLocalizedDescriptionKey:
                                    @"No package manager backend is available",
                                }];
      return NO;
    }

  BOOL result = [_backend installPackages:packageNames
                           localFilePaths:filePaths
                                progress:progressHandler
                                   error:error];
  NSLog(@"GWPackageManager <- installPackages: %@", result ? @"succeeded" : @"failed");
  return result;
}

- (BOOL)uninstallPackages:(NSArray<NSString *> *)packageNames
                progress:(id<GWInstallProgressHandler>)progressHandler
                   error:(NSError **)error
{
  NSLog(@"GWPackageManager -> uninstallPackages (backend): %@", packageNames);

  if (!_backend)
    {
      NSLog(@"GWPackageManager [FAIL] uninstallPackages: no backend available");
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                    code:GWPackageManagerErrorBackendUnavailable
                                userInfo:@{
                                  NSLocalizedDescriptionKey:
                                    @"No package manager backend is available",
                                }];
      return NO;
    }

  BOOL result = [_backend uninstallPackages:packageNames
                                  progress:progressHandler
                                     error:error];
  NSLog(@"GWPackageManager <- uninstallPackages: %@", result ? @"succeeded" : @"failed");
  return result;
}

#pragma mark - File / Ownership Queries

- (NSArray<NSString *> *)filesForPackage:(NSString *)packageName
                                   error:(NSError **)error
{
  NSLog(@"GWPackageManager -> filesForPackage: %@", packageName);

  if (!_backend)
    {
      NSLog(@"GWPackageManager [FAIL] filesForPackage: no backend available");
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                    code:GWPackageManagerErrorBackendUnavailable
                                userInfo:@{
                                  NSLocalizedDescriptionKey:
                                    @"No package manager backend is available",
                                }];
      return nil;
    }

  NSArray *result = [_backend filesForPackage:packageName error:error];
  NSLog(@"GWPackageManager <- filesForPackage: %@ -> %lu files", packageName, (unsigned long)[result count]);
  return result;
}

- (NSString *)packageOwningFile:(NSString *)filePath
                          error:(NSError **)error
{
  NSLog(@"GWPackageManager -> packageOwningFile: %@", filePath);

  if (!_backend)
    {
      NSLog(@"GWPackageManager [FAIL] packageOwningFile: no backend available");
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                    code:GWPackageManagerErrorBackendUnavailable
                                userInfo:@{
                                  NSLocalizedDescriptionKey:
                                    @"No package manager backend is available",
                                }];
      return nil;
    }

  NSString *result = [_backend packageOwningFile:filePath error:error];
  NSLog(@"GWPackageManager <- packageOwningFile: %@ -> %@", filePath, result);
  return result;
}

#pragma mark - Plist-Based Operations

- (BOOL)_runPostCommand:(NSString *)command error:(NSError **)error
{
  if (!command || [command length] == 0)
    {
      NSLog(@"GWPackageManager -> _runPostCommand: (none)");
      return YES;
    }

  NSLog(@"GWPackageManager -> _runPostCommand: /bin/sh -c \"%@\"", command);

  // Simple command execution via system() - for real usage, use NSTask
  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:@"/bin/sh"];
  [task setArguments:@[@"-c", command]];

  @try
    {
      [task launch];
      [task waitUntilExit];
      int status = [task terminationStatus];
      if (status != 0)
        {
          NSLog(@"GWPackageManager [FAIL] _runPostCommand: exit code %d", status);
          if (error)
            *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                        code:GWPackageManagerErrorCommandFailed
                                    userInfo:@{
                                      NSLocalizedDescriptionKey:
                                        [NSString stringWithFormat:
                                          @"Post command failed with exit code %d", status],
                                    }];
          return NO;
        }
      NSLog(@"GWPackageManager [OK] _runPostCommand: succeeded");
      return YES;
    }
  @catch (NSException *e)
    {
      NSLog(@"GWPackageManager [FAIL] _runPostCommand: exception %@", e);
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                    code:GWPackageManagerErrorCommandFailed
                                userInfo:@{
                                  NSLocalizedDescriptionKey:
                                    [NSString stringWithFormat:@"Failed to run post command: %@", e],
                                }];
      return NO;
    }
}

- (BOOL)runInstallFromPlistAtPath:(NSString *)plistPath
                        progress:(id<GWInstallProgressHandler>)progressHandler
                           error:(NSError **)error
{
  NSLog(@"GWPackageManager -> runInstallFromPlistAtPath: %@", plistPath);

  // Parse the install plist
  GWPackageInstallSpec *spec = [[GWPackageInstallSpec alloc]
                                 initWithPlistAtPath:plistPath
                                            specType:GWPackageInstallSpecTypeInstall
                                               error:error];
  if (!spec)
    {
      NSLog(@"GWPackageManager [FAIL] runInstallFromPlistAtPath: failed to parse plist at %@", plistPath);
      return NO;
    }

  // Validate spec
  if (![spec isValid:error])
    {
      NSLog(@"GWPackageManager [FAIL] runInstallFromPlistAtPath: spec is invalid");
      return NO;
    }

  // Run the installation
  BOOL success = [self installPackages:[spec packages]
                        localFilePaths:[spec localFilePaths]
                             progress:progressHandler
                                error:error];
  if (!success)
    {
      NSLog(@"GWPackageManager [FAIL] runInstallFromPlistAtPath: installation failed");
      return NO;
    }

  // Run post-install command
  NSString *postCommand = [spec postCommand];
  if (postCommand)
    {
      return [self _runPostCommand:postCommand error:error];
    }

  NSLog(@"GWPackageManager [OK] runInstallFromPlistAtPath: completed successfully");
  return YES;
}

- (BOOL)runUninstallFromPlistAtPath:(NSString *)plistPath
                          progress:(id<GWInstallProgressHandler>)progressHandler
                             error:(NSError **)error
{
  NSLog(@"GWPackageManager -> runUninstallFromPlistAtPath: %@", plistPath);

  // Parse the uninstall plist
  GWPackageInstallSpec *spec = [[GWPackageInstallSpec alloc]
                                 initWithPlistAtPath:plistPath
                                            specType:GWPackageInstallSpecTypeUninstall
                                               error:error];
  if (!spec)
    {
      NSLog(@"GWPackageManager [FAIL] runUninstallFromPlistAtPath: failed to parse plist at %@", plistPath);
      return NO;
    }

  // Validate spec
  if (![spec isValid:error])
    {
      NSLog(@"GWPackageManager [FAIL] runUninstallFromPlistAtPath: spec is invalid");
      return NO;
    }

  // Run the uninstallation
  BOOL success = [self uninstallPackages:[spec packages]
                               progress:progressHandler
                                  error:error];
  if (!success)
    {
      NSLog(@"GWPackageManager [FAIL] runUninstallFromPlistAtPath: uninstallation failed");
      return NO;
    }

  // Run post-uninstall command
  NSString *postCommand = [spec postCommand];
  if (postCommand)
    {
      return [self _runPostCommand:postCommand error:error];
    }

  NSLog(@"GWPackageManager [OK] runUninstallFromPlistAtPath: completed successfully");
  return YES;
}

#pragma mark - User-Friendly Error Messages

+ (NSString *)friendlyErrorMessageForError:(NSError *)error
                                   appName:(NSString *)appName
{
  NSString *name = [appName length] > 0 ? appName : @"This application";

  if (!error)
    return [NSString stringWithFormat:
      @"%@ could not be downloaded due to an unexpected error.", name];

  if (![error.domain isEqualToString:GWPackageManagerErrorDomain])
    return [NSString stringWithFormat:
      @"%@ could not be downloaded. Please try again later.", name];

  switch ((GWPackageManagerError)error.code)
    {
    case GWPackageManagerErrorNotAuthorized:
      return [NSString stringWithFormat:
        @"%@ requires administrator access to be installed.\n"
        @"Please contact your system administrator.", name];

    case GWPackageManagerErrorPackageNotFound:
      return [NSString stringWithFormat:
        @"%@ was not found in the software repository.\n"
        @"It may have been removed or renamed.", name];

    case GWPackageManagerErrorBackendUnavailable:
      return [NSString stringWithFormat:
        @"%@ could not be installed because this system is not supported.", name];

    case GWPackageManagerErrorCommandFailed:
      return [NSString stringWithFormat:
        @"%@ could not be downloaded.\n"
        @"Please check your internet connection and try again.", name];

    case GWPackageManagerErrorPlistInvalid:
      return [NSString stringWithFormat:
        @"The setup information for %@ could not be read.", name];

    default:
      return [NSString stringWithFormat:
        @"%@ could not be downloaded due to an unexpected error.", name];
    }
}

#pragma mark - Captured Output

- (NSString *)capturedErrorOutput
{
  if ([_backend respondsToSelector:@selector(capturedErrorOutput)])
    return [_backend capturedErrorOutput];
  return nil;
}

@end

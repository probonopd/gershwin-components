/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWPackageInstallSpec - Parses install/uninstall plist files with
 * OS-specific override resolution.
 *
 * Override resolution:
 * 1. Start with top-level values (packages, local_packages, post_command)
 * 2. Check os_overrides for the current OS (in GWOSDetector search order)
 * 3. Override matching keys; missing keys fall back to top-level values
 */

#import "GWPackageInstallSpec.h"
#import "GWOSDetector.h"
#import "GWPackageManager.h"

NSString *const GWPackageManagerErrorDomain = @"GWPackageManagerErrorDomain";

@interface GWPackageInstallSpec ()
@property (readwrite, copy) NSArray<NSString *> *packages;
@property (readwrite, copy) NSArray<NSString *> *localFilePaths;
@property (readwrite, copy) NSString *postCommand;
@property (readwrite, copy) NSArray<NSString *> *postCommandArguments;
@property (readwrite) GWPackageInstallSpecType specType;
@property (readwrite) BOOL isAppImage;
@property (readwrite, copy) NSString *appImageDirectURL;
@property (readwrite, copy) NSString *appImageGitHubRepo;
@end

@implementation GWPackageInstallSpec

- (nullable instancetype)initWithPlistAtPath:(NSString *)path
                                    specType:(GWPackageInstallSpecType)specType
                                       error:(NSError **)error
{
  self = [super init];
  if (!self) return nil;

  _specType = specType;

  NSLog(@"GWPackageInstallSpec -> parsing plist at %@ (type: %@)", path,
        (specType == GWPackageInstallSpecTypeInstall) ? @"install" : @"uninstall");

  // Read plist file
  NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
  if (!plist)
    {
      NSLog(@"GWPackageInstallSpec [FAIL] could not read plist at %@", path);
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                    code:GWPackageManagerErrorPlistInvalid
                                userInfo:@{
                                  NSLocalizedDescriptionKey:
                                    [NSString stringWithFormat:@"Could not read plist at %@", path],
                                }];
      return nil;
    }

  // Start with top-level values
  NSArray *topPackages = plist[@"packages"];
  NSArray *topLocalFiles = plist[@"local_packages"];
  NSString *postCommandKey = (specType == GWPackageInstallSpecTypeInstall)
    ? @"postinstall_command" : @"postuninstall_command";
  NSString *topPostCommand = plist[postCommandKey];
  NSString *postArgsKey = (specType == GWPackageInstallSpecTypeInstall)
    ? @"postinstall_arguments" : @"postuninstall_arguments";
  NSArray *topPostArgs = plist[postArgsKey];

  // AppImage sources (resolved for the current architecture).
  NSDictionary *topAppImage = plist[@"AppImage"];
  id topAppImageGitHub = plist[@"AppImage_github"];

  NSLog(@"GWPackageInstallSpec -> top-level packages: %@, local: %@, post: %@, args: %@",
        topPackages, topLocalFiles, topPostCommand, topPostArgs);

  // Apply OS overrides
  NSDictionary *osOverrides = plist[@"os_overrides"];
  if (osOverrides)
    {
      NSLog(@"GWPackageInstallSpec -> os_overrides present, resolving...");
      NSArray *searchOrder = [GWOSDetector osSearchOrder];
      for (NSString *osID in searchOrder)
        {
          NSDictionary *override = osOverrides[osID];
          if (override)
            {
              NSLog(@"GWPackageInstallSpec -> matched OS override '%@': %@", osID, override);

              // Override packages if specified
              if (override[@"packages"])
                topPackages = override[@"packages"];

              // Override local_packages if specified
              if (override[@"local_packages"])
                topLocalFiles = override[@"local_packages"];

              // Override post command if specified
              if (override[postCommandKey])
                topPostCommand = override[postCommandKey];

              // Override post arguments if specified
              if (override[postArgsKey])
                topPostArgs = override[postArgsKey];

              // Override AppImage sources if specified
              if (override[@"AppImage"])
                topAppImage = override[@"AppImage"];
              if (override[@"AppImage_github"])
                topAppImageGitHub = override[@"AppImage_github"];

              break; // First matching OS wins
            }
          else
            {
              NSLog(@"GWPackageInstallSpec -> no override for OS '%s' in search order", osID.UTF8String);
            }
        }
    }
  else
    {
      NSLog(@"GWPackageInstallSpec -> no os_overrides in plist");
    }

  _packages = [topPackages copy] ?: @[];
  _localFilePaths = [topLocalFiles copy] ?: @[];
  _postCommand = [topPostCommand copy];
  _postCommandArguments = [topPostArgs copy] ?: @[];

  // Resolve the AppImage source for the current architecture.  A spec is an
  // AppImage install if either a direct per-arch URL map or a GitHub repo is
  // supplied.  AppImages only make sense on Linux, but we parse regardless and
  // let the installer fail later with a clear message on other platforms.
  NSString *arch = [GWOSDetector currentArchitecture];
  NSString *appImageDirectURL = nil;
  if ([topAppImage isKindOfClass:[NSDictionary class]] && topAppImage[arch])
    appImageDirectURL = topAppImage[arch];

  NSString *appImageGitHubRepo = nil;
  if ([topAppImageGitHub isKindOfClass:[NSDictionary class]])
    appImageGitHubRepo = topAppImageGitHub[@"repo"];
  else if ([topAppImageGitHub isKindOfClass:[NSString class]])
    appImageGitHubRepo = topAppImageGitHub;

  _appImageDirectURL = [appImageDirectURL copy];
  _appImageGitHubRepo = [appImageGitHubRepo copy];
  _isAppImage = (_appImageDirectURL != nil || _appImageGitHubRepo != nil);

  NSLog(@"GWPackageInstallSpec <- resolved: packages=%@, local=%@, post=%@ args=%@, AppImage=%@ github=%@",
        _packages, _localFilePaths, _postCommand, _postCommandArguments,
        _appImageDirectURL, _appImageGitHubRepo);

  return self;
}

- (BOOL)isValid:(NSError **)error
{
  if ([_packages count] == 0 && [_localFilePaths count] == 0 && !_isAppImage)
    {
      NSLog(@"GWPackageInstallSpec [FAIL] isValid: NO — no packages, local files, or AppImage specified");
      if (error)
        *error = [NSError errorWithDomain:GWPackageManagerErrorDomain
                                    code:GWPackageManagerErrorPlistInvalid
                                userInfo:@{
                                  NSLocalizedDescriptionKey:
                                    @"Plist must specify at least one package, local file path, or AppImage",
                                }];
      return NO;
    }

  NSLog(@"GWPackageInstallSpec [OK] isValid: YES");
  return YES;
}

@end

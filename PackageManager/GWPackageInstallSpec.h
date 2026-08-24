/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWPackageInstallSpec - Parses install/uninstall plist files
 * with OS-specific override resolution.
 *
 * Plist format supports:
 *   - packages: array of package names
 *   - local_packages: array of local file paths (install only)
 *   - postinstall_command / postuninstall_command: optional command to run
 *   - os_overrides: per-OS overrides for packages and commands
 */

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, GWPackageInstallSpecType) {
    GWPackageInstallSpecTypeInstall,
    GWPackageInstallSpecTypeUninstall,
};

@interface GWPackageInstallSpec : NSObject

// Parsed properties (resolved for current OS)
@property (readonly, copy) NSArray<NSString *> *packages;
@property (readonly, copy) NSArray<NSString *> *localFilePaths;  // Install only
@property (readonly, copy) NSString *postCommand;                // Command to run after operation
@property (readonly, copy) NSArray<NSString *> *postCommandArguments; // Arguments for postCommand
@property (readonly) GWPackageInstallSpecType specType;

// AppImage support.  A spec is an AppImage install when either a direct
// per-architecture URL map (`AppImage`) or a GitHub release repo
// (`AppImage_github`) is supplied.  AppImages are installed into
// ~/Library/Applications/<name>.app and need no distribution package manager
// (Linux only).
@property (readonly) BOOL isAppImage;
// Resolved direct download URL for the current architecture, if a direct
// `appimage` map lists the current arch.  nil otherwise.
@property (readonly, copy, nullable) NSString *appImageDirectURL;
// "owner/repo" GitHub repository whose latest release provides the AppImage,
// or nil if not a GitHub-sourced AppImage.
@property (readonly, copy, nullable) NSString *appImageGitHubRepo;

// Designated initializer: parse plist at path and resolve OS overrides
- (nullable instancetype)initWithPlistAtPath:(NSString *)path
                                    specType:(GWPackageInstallSpecType)specType
                                       error:(NSError **)error;

// Validate the spec has at least one package or local file path
- (BOOL)isValid:(NSError **)error;

@end

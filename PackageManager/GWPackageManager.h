/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWPackageManager - Public API for package management operations.
 * Provides a unified interface for installing/uninstalling packages
 * across multiple OS platforms via pluggable backends.
 */

#import <Foundation/Foundation.h>

// Forward declarations
@protocol GWPackageManagerBackend;
@protocol GWInstallProgressHandler;

#pragma mark - Error Domain & Codes

extern NSString *const GWPackageManagerErrorDomain;

typedef NS_ENUM(NSInteger, GWPackageManagerError) {
    GWPackageManagerErrorNotAuthorized = 1,
    GWPackageManagerErrorPackageNotFound,
    GWPackageManagerErrorBackendUnavailable,
    GWPackageManagerErrorCommandFailed,
    GWPackageManagerErrorPlistInvalid,
    GWPackageManagerErrorDatabaseUnavailable,
};

#pragma mark - Progress Handler Protocol

@protocol GWInstallProgressHandler <NSObject>
- (void)installDidProgress:(float)progress message:(NSString *)message;

@optional
/// Called for each line of stderr output produced by the underlying package
/// manager tool.  Lines are delivered as the command runs.  Implementors
/// should dispatch to the main queue before updating UI.
- (void)installDidOutputLine:(NSString *)line;
@end

#pragma mark - GWPackageManager Interface

@interface GWPackageManager : NSObject

// Singleton access
@property (class, readonly, strong) GWPackageManager *sharedManager;

// --- Basic operations (synchronous, no progress) ---
- (BOOL)installPackages:(NSArray<NSString *> *)packageNames
                  error:(NSError **)error;
- (BOOL)installPackages:(NSArray<NSString *> *)packageNames
        localFilePaths:(NSArray<NSString *> *)filePaths
                  error:(NSError **)error;
- (BOOL)uninstallPackages:(NSArray<NSString *> *)packageNames
                    error:(NSError **)error;

// --- Operations with progress reporting ---
- (BOOL)installPackages:(NSArray<NSString *> *)packageNames
        localFilePaths:(NSArray<NSString *> *)filePaths
             progress:(nullable id<GWInstallProgressHandler>)progressHandler
                error:(NSError **)error;
- (BOOL)uninstallPackages:(NSArray<NSString *> *)packageNames
                progress:(nullable id<GWInstallProgressHandler>)progressHandler
                   error:(NSError **)error;

// --- Files / ownership queries ---
- (NSArray<NSString *> *)filesForPackage:(NSString *)packageName error:(NSError **)error;
- (NSString *)packageOwningFile:(NSString *)filePath error:(NSError **)error;

// --- Plist-based install/uninstall ---
- (BOOL)runInstallFromPlistAtPath:(NSString *)plistPath
                        progress:(nullable id<GWInstallProgressHandler>)progressHandler
                           error:(NSError **)error;
- (BOOL)runUninstallFromPlistAtPath:(NSString *)plistPath
                          progress:(nullable id<GWInstallProgressHandler>)progressHandler
                             error:(NSError **)error;

// Dependency injection for testing
- (instancetype)initWithBackend:(id<GWPackageManagerBackend>)backend;

@property (readonly, strong) id<GWPackageManagerBackend> backend;

/// Full stderr output from the most recent backend command, suitable for
/// display in a "Details" disclosure area.  Valid after install/uninstall
/// operations complete.
@property (readonly, nullable) NSString *capturedErrorOutput;

// --- User-friendly error descriptions ---
// Converts a GWPackageManager error into a non-technical message suitable
// for display in a GUI dialog.  The returned string never contains
// internal error details, file paths, or exit codes.
+ (NSString *)friendlyErrorMessageForError:(NSError *)error
                                   appName:(NSString *)appName;

@end

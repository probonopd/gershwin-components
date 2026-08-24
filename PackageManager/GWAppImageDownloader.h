/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GWAppImageDownloader - Downloads an AppImage (direct URL or latest GitHub
 * release asset) and places it directly into ~/Library/Applications as a flat,
 * executable <name>.AppImage file (no .app wrapper).
 */

#import <Foundation/Foundation.h>

@protocol GWInstallProgressHandler;

@interface GWAppImageDownloader : NSObject

// Downloads an already-known AppImage URL into ~/Library/Applications/<appName>.app
- (BOOL)downloadAppImageFromURL:(NSString *)url
                         appName:(NSString *)appName
                        progress:(nullable id<GWInstallProgressHandler>)progress
                           error:(NSError **)error;

// Resolves the AppImage for the current architecture from the latest GitHub
// release of <repo> ("owner/repo"), then downloads it.
- (BOOL)downloadAppImageFromGitHubRepo:(NSString *)repo
                                appName:(NSString *)appName
                               progress:(nullable id<GWInstallProgressHandler>)progress
                                  error:(NSError **)error;

// Path of the launcher inside the downloaded .app bundle.  Used to launch the
// app after download and to detect an already-downloaded AppImage.
+ (NSString *)launcherPathForAppName:(NSString *)appName;

@end

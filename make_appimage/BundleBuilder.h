/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * BundleBuilder — builds a self-contained .app bundle with all GNUstep
 * dependencies deployed inside Resources/GNUstep/.  Used by both
 * make_appimage (via AppImagePackager) and make_standalone (standalone
 * .app bundles with AppRun as NSExecutable).
 */

#import <Foundation/Foundation.h>

@interface BundleBuilder : NSObject
{
    NSString *_appName;
    NSString *_appDir;
    NSString *_buildDir;
    NSString *_appDirPath;
    NSString *_comment;
    NSString *_categories;
    NSString *_mainExec;
    NSMutableArray *_allELFs;
    NSMutableArray *_seenDeps;
    NSMutableArray *_libraryLocations;
    NSArray *_excludedLibraries;
    NSArray *_extraBundles;
}

- (instancetype)initWithAppName:(NSString *)name;
- (void)setBuildDirectory:(NSString *)dir;
- (void)setMainExecutable:(NSString *)path;
- (void)setStandalone:(BOOL)flag;
- (void)setThemeName:(NSString *)name;
- (void)setDeployTheme:(BOOL)flag;
- (void)setFrameworks:(NSArray *)names;
- (void)setVerbose:(BOOL)flag;
- (void)setExtraBundles:(NSArray *)names;
- (void)setComment:(NSString *)comment;
- (void)setCategories:(NSString *)categories;
- (void)setStandaloneBundle:(BOOL)flag;

- (BOOL)build;

// Read-only accessors for AppImagePackager and finalization
@property (readonly) NSString *appDirPath;
@property (readonly) NSString *appName;
@property (readonly) NSString *mainExec;
@property (readonly) NSString *comment;
@property (readonly) NSString *categories;

@end

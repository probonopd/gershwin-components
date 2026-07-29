/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/**
 * Builds an AppImage from a GNUstep application.
 *
 * Typical usage:
 *
 *     AppImageBuilder *builder = [[AppImageBuilder alloc] initWithAppName:@"TextEdit"];
 *     [builder setOutputFile:@"TextEdit-1.0-x86_64-linux.AppImage"];
 *     [builder build];
 */
@interface AppImageBuilder : NSObject
{
    NSString *_appName;
    NSString *_appDir;
    NSString *_outputFile;
    NSString *_buildDir;
    NSString *_appDirPath;
    NSString *_comment;
    NSString *_categories;
    NSString *_mainExec;
    NSString *_appimageTool;
    NSMutableArray *_allELFs;
    NSMutableArray *_seenDeps;
    NSMutableArray *_libraryLocations;
    NSArray *_excludedLibraries;
}

- (instancetype)initWithAppName:(NSString *)name;
- (void)setOutputFile:(NSString *)path;
- (void)setBuildDirectory:(NSString *)dir;
- (void)setComment:(NSString *)comment;
- (void)setCategories:(NSString *)categories;
- (void)setMainExecutable:(NSString *)path;
- (void)setAppimageTool:(NSString *)path;
- (void)setStandalone:(BOOL)flag;
- (void)setVerbose:(BOOL)flag;

- (BOOL)build;

@end

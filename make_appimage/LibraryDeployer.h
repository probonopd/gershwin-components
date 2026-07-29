/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/**
 * Copies shared libraries into the AppDir, honouring an exclusion
 * list and optionally placing libraries under a libc subdirectory.
 *
 * Each library is copied as a regular file (symlinks are resolved)
 * to produce a self-contained AppDir.
 */
@interface LibraryDeployer : NSObject
{
    NSString *_appDirPath;
    NSArray *_excludedLibraries;
    BOOL _useLibcSubdirectory;
}

- (instancetype)initWithAppDir:(NSString *)appDirPath;

- (BOOL)deployLibrary:(NSString *)libPath;
- (BOOL)deployLibraries:(NSArray *)libPaths;

- (BOOL)isExcluded:(NSString *)libName;
- (void)setUseLibcSubdirectory:(BOOL)flag;
- (void)setStandalone:(BOOL)flag;
- (void)setVerbose:(BOOL)flag;

@end

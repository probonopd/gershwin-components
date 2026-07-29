/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/**
 * LibraryDeployer — copies resolved shared-library paths into the AppDir.
 *
 * Applies two layers of exclusion (exact filename + prefix-match) to
 * skip host-system libraries. In standalone mode all exclusions are
 * bypassed. Optionally places glibc internals into a libc/ subdirectory
 * for use with libapprun_hooks.
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

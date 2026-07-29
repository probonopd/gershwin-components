/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/**
 * LibraryResolver — discovers all shared libraries an AppDir's ELFs need.
 *
 * Walks the AppDir for ELF files, runs ldd on each, resolves transitive
 * dependencies, and excludes known system libraries. Standalone mode
 * disables exclusions. Also extracts RPATH entries to ensure ldd can
 * resolve app-bundled sibling libraries.
 */
@interface LibraryResolver : NSObject
{
    NSString *_appDirPath;
    NSMutableArray *_libraryLocations;
}

- (instancetype)initWithAppDir:(NSString *)appDirPath;
- (NSArray *)resolveDependenciesForExecutables:(NSArray *)executables;
- (NSArray *)findAllELFsInAppDir;
- (NSArray *)libraryLocations;
- (void)setVerbose:(BOOL)flag;
- (void)setStandalone:(BOOL)flag;

@end

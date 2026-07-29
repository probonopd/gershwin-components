/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/**
 * Resolves shared library dependencies for ELF binaries within an AppDir.
 *
 * Uses ldd to enumerate dependencies of each executable/ELF, walks
 * the AppDir recursively to find all ELF files, and maintains a list
 * of library search paths discovered during resolution.
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

@end

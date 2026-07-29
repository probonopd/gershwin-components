/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/**
 * Handles detection, deployment, and patching of the ld-linux
 * dynamic linker/loader within an AppDir.
 *
 * The interpreter is copied from the host system and its embedded
 * library search path is patched to point into the AppDir.
 */
@interface InterpreterDeployer : NSObject
{
    NSString *_appDirPath;
}

- (instancetype)initWithAppDir:(NSString *)appDirPath;
- (NSString *)detectInterpreter;
- (BOOL)deployInterpreter:(NSString *)interpreterPath;
- (BOOL)patchInterpreter:(NSString *)deployedPath;
- (BOOL)isMusl;
- (void)setVerbose:(BOOL)flag;

@end

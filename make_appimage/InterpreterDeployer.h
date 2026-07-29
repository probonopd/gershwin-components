/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/**
 * InterpreterDeployer — detects, deploys, and patches the ELF interpreter.
 *
 * Scans .app bundles and standard system paths for ld-linux / ld-musl,
 * copies the resolved real file into the AppDir, and optionally patches
 * its embedded search-path strings so the deployed interpreter looks
 * inside the AppDir for libraries.
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

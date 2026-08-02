/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * AppImagePackager — takes a fully-built .app bundle (from BundleBuilder)
 * and packages it as an AppImage: writes .desktop file, sets up .DirIcon,
 * and runs appimagetool.
 */

#import <Foundation/Foundation.h>

@class BundleBuilder;

@interface AppImagePackager : NSObject

+ (BOOL)findAppImageTool;
- (instancetype)initWithBuilder:(BundleBuilder *)builder;
- (void)setAppimageTool:(NSString *)path;
- (void)setOutputFile:(NSString *)path;
- (BOOL)package;

@end

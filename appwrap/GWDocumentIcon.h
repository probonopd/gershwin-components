/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface GWDocumentIcon : NSObject

+ (NSString *)createDocumentIconInResources:(NSString *)resourcesPath
                                    appName:(NSString *)appName
                           appIconFilename:(NSString *)appIconFilename
                                     mimeType:(NSString *)mimeType
                                     typeName:(NSString *)typeName
                                         size:(int)size;

+ (NSData *)createCombinedIconPNGWithAppIcon:(NSImage *)appIcon
                              extensionText:(NSString *)extensionText
                                       size:(int)size;

@end

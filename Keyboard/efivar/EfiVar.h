/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#define EFI_GUID_KEYBOARD @"7c436110-ab2a-4bbb-a880-fe41995c9f82"
#define EFI_VAR_PREV_LANG  @"prev-lang:kbd"

@interface EfiVar : NSObject
- (NSString *)platformName;
- (BOOL)isAvailable;
- (NSString *)ensureAvailable;
- (NSString *)readValue:(NSString *)name guid:(NSString *)guid;
- (BOOL)writeValue:(NSString *)value name:(NSString *)name guid:(NSString *)guid;
- (NSString *)lastError;
- (void)setLastError:(NSString *)err;
@end

@interface EfiVarLinux : EfiVar
@end

@interface EfiVarFreeBSD : EfiVar
@end

EfiVar *EfiVarCreate(void);

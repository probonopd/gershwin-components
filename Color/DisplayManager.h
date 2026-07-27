/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface DisplayManager : NSObject
{
    void *_display;
    int _screen;
    unsigned long _root;
}

- (BOOL)isAvailable;
- (NSArray<NSString *> *)listDisplays;
- (NSString *)outputIdentifierForDisplay:(NSString *)displayName;
- (unsigned long)crtcForDisplay:(NSString *)displayName;

- (NSString *)savedProfileForDisplay:(NSString *)displayName;
- (void)saveProfile:(NSString *)profilePath forDisplay:(NSString *)displayName;

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "GSAssistantFramework.h"

@interface CADisplayPage : GSAssistantStep
@end

@interface CAWhitePointPage : GSAssistantStep
- (double)whitePoint;
- (void)setWhitePoint:(double)wp;
@end

@interface CAGammaPage : GSAssistantStep
- (double)gammaValue;
- (void)setGammaValue:(double)g;
@end

@interface CAResponsePage : GSAssistantStep
@property BOOL advancedEnabled;
- (void)setWhitePoint:(double)wp gamma:(double)g;
@end

@interface CASavePage : GSAssistantStep
@property BOOL forAllUsers;
- (NSString *)profileName;
- (void)setWhitePoint:(double)wp gamma:(double)g;
@end

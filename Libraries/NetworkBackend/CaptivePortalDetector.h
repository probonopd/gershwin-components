/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface CaptivePortalDetector : NSObject

+ (void)checkForCaptivePortalWithCompletion:(void (^)(BOOL isCaptive, NSString *redirectURL))completion;
+ (void)checkForCaptivePortalForceWithCompletion:(void (^)(BOOL isCaptive, NSString *redirectURL))completion;

@end

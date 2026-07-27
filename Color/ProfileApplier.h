/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface ProfileApplier : NSObject

- (BOOL)applyProfile:(NSString *)profilePath forDisplay:(NSString *)displayName;
- (BOOL)revertForDisplay:(NSString *)displayName;
- (NSString *)activeProfileForDisplay:(NSString *)displayName;

@end

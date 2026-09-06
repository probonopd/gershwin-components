/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface SoundVolume : NSObject

+ (float)outputVolume;
+ (void)setOutputVolume:(float)volume;
+ (void)increaseVolume;
+ (void)decreaseVolume;
+ (void)toggleMute;
+ (BOOL)isMuted;
+ (void)toggleMicMute;

@end

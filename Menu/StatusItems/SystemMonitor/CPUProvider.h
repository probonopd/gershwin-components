/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "StatusItemProvider.h"

@interface CPUProvider : NSObject <StatusItemProvider>
{
    NSTimer *_timer;
    NSMenu *_detailMenu;
    double _cpuUsage;
    NSMutableArray *_perCoreCPU;
    unsigned long long _lastTotalTicks;
    unsigned long long _lastIdleTicks;
    CGFloat _cachedFixedWidth;
}
@end

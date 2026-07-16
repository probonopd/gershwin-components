/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import "StatusItemProvider.h"

@interface RAMProvider : NSObject <StatusItemProvider>
{
    NSTimer *_timer;
    NSMenu *_detailMenu;
    double _ramUsage;
    unsigned long long _memTotal;
    unsigned long long _memUsed;
    CGFloat _cachedFixedWidth;
}
@end

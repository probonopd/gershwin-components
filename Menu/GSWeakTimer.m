/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSWeakTimer.h"

@interface GSWeakTimer ()
@property (weak) id target;
@property (assign) SEL selector;
@end

@implementation GSWeakTimer

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)interval
                                     target:(id)target
                                   selector:(SEL)selector
                                   userInfo:(id)userInfo
                                    repeats:(BOOL)repeats
{
    GSWeakTimer *proxy = [[self alloc] init];
    proxy.target = target;
    proxy.selector = selector;
    return [NSTimer scheduledTimerWithTimeInterval:interval
                                            target:proxy
                                          selector:@selector(fire:)
                                          userInfo:userInfo
                                           repeats:repeats];
}

- (void)fire:(NSTimer *)timer
{
    id t = _target;
    if (t) {
        @try {
            void (*fn)(id, SEL, ...) = (void (*)(id, SEL, ...))(void *)[t methodForSelector:_selector];
            fn(t, _selector);
        } @catch (NSException *e) {
            NSLog(@"GSWeakTimer: exception: %@", e);
        }
    }
}

@end

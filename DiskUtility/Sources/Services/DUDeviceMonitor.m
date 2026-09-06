/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUDeviceMonitor.h"

#import "DUErrors.h"
#import "DUStorageManager.h"

// Defaults key overriding the poll interval in seconds.
static NSString *const DURefreshIntervalDefaultsKey = @"DURefreshInterval";
static const NSTimeInterval DUDefaultRefreshInterval = 10.0;

@implementation DUDeviceMonitor {
    DUStorageManager *_storageManager;
    NSTimer *_timer;
    NSLock *_lock;
    BOOL _refreshInFlight; // Skips ticks when the previous one still runs.
}

- (instancetype)initWithStorageManager:(DUStorageManager *)storageManager
{
    NSParameterAssert(storageManager != nil);
    if ((self = [super init]) == nil) {
        return nil;
    }
    _storageManager = storageManager;
    _lock = [[NSLock alloc] init];

    NSNumber *configured =
        [[NSUserDefaults standardUserDefaults]
            objectForKey:DURefreshIntervalDefaultsKey];
    if (configured != nil && configured.doubleValue >= 1.0) {
        _interval = configured.doubleValue;
    } else {
        _interval = DUDefaultRefreshInterval;
    }

    return self;
}

- (void)start
{
    [_lock lock];
    if (_timer != nil) {
        [_lock unlock];
        return;
    }
    // Retained cycle is deliberate and broken in -stop/dealloc.
    _timer = [NSTimer timerWithTimeInterval:_interval
                                     target:self
                                   selector:@selector(timerFired:)
                                   userInfo:nil
                                    repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    [_lock unlock];

    // First snapshot right away so the UI does not start empty.
    [self refreshOnce];
}

- (void)stop
{
    [_lock lock];
    if (_timer != nil) {
        [_timer invalidate];
        _timer = nil;
    }
    [_lock unlock];
}

- (void)dealloc
{
    // Timers retain their target; if we are deallocating anyway, make sure
    // the run loop lets go too.
    [_timer invalidate];
}

- (void)timerFired:(NSTimer *)timer
{
    (void)timer;
    [self refreshOnce];
}

- (void)refreshOnce
{
    [_lock lock];
    if (_refreshInFlight) {
        [_lock unlock];
        return;
    }
    _refreshInFlight = YES;
    [_lock unlock];

    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        @autoreleasepool {
            NSError *error = nil;
            // A failed poll keeps the previous snapshot; discovery errors on
            // transient devices are routine and must not tear down the model.
            if (![self.storageManager refreshWithError:&error] && error != nil) {
                NSLog(@"DUDeviceMonitor: refresh failed: %@",
                      error.localizedDescription);
            }
            [self->_lock lock];
            self->_refreshInFlight = NO;
            [self->_lock unlock];
        }
    }];
    thread.name = @"DUDeviceMonitor refresh";
    [thread start];
}

@end

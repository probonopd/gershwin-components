/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOperation.h"

#import "DUErrors.h"
#import "DUNotifications.h"

NSString *const DUOperationStateNamePending = @"Pending";
NSString *const DUOperationStateNamePreparing = @"Preparing";
NSString *const DUOperationStateNameRunning = @"Running";
NSString *const DUOperationStateNameCancelling = @"Cancelling";
NSString *const DUOperationStateNameCancelled = @"Cancelled";
NSString *const DUOperationStateNameCompleted = @"Completed";
NSString *const DUOperationStateNameFailed = @"Failed";

@implementation DUOperation {
    NSLock *_lock;
    NSString *_identifier;
    DUOperationState _state;
    double _progress;
    NSString *_message;
    NSDate *_startTime;
    NSDate *_finishTime;
    NSError *_error;
    BOOL _cancelRequested;
    BOOL _finalized;
}

@synthesize primaryObject = _primaryObject;

- (instancetype)initWithPrimaryObject:(DUStorageObject *)object
{
    if ((self = [super init]) == nil) {
        return nil;
    }
    _lock = [[NSLock alloc] init];
    _identifier = [[NSUUID UUID] UUIDString];
    _state = DUOperationStatePending;
    _primaryObject = object;
    return self;
}

- (NSString *)identifier
{
    // Immutable after init; no lock needed.
    return _identifier;
}

- (NSString *)displayName
{
    return [NSString stringWithFormat:@"%@ %@", [self class], _identifier];
}

// --- Locked state accessors ---------------------------------------------

- (DUOperationState)state
{
    [_lock lock];
    DUOperationState s = _state;
    [_lock unlock];
    return s;
}

- (double)progress
{
    [_lock lock];
    double p = _progress;
    [_lock unlock];
    return p;
}

- (NSString *)message
{
    [_lock lock];
    NSString *m = [_message copy];
    [_lock unlock];
    return m;
}

- (NSDate *)startTime
{
    [_lock lock];
    NSDate *d = [_startTime copy];
    [_lock unlock];
    return d;
}

- (NSDate *)finishTime
{
    [_lock lock];
    NSDate *d = [_finishTime copy];
    [_lock unlock];
    return d;
}

- (NSError *)error
{
    [_lock lock];
    NSError *e = [_error copy];
    [_lock unlock];
    return e;
}

- (BOOL)cancelRequested
{
    [_lock lock];
    BOOL c = _cancelRequested;
    [_lock unlock];
    return c;
}

// Caller must hold _lock.
- (BOOL)isTerminalStateLocked
{
    switch (_state) {
        case DUOperationStateCancelled:
        case DUOperationStateCompleted:
        case DUOperationStateFailed:
            return YES;
        default:
            return NO;
    }
}

// --- Notification delivery ----------------------------------------------

// All operation events funnel through here so the main-thread contract is
// enforced in one place: observers may touch AppKit without re-dispatch.
- (void)postNotificationName:(NSString *)name includeError:(BOOL)includeError
{
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[kDUUserInfoOperationKey] = self;
    if (_primaryObject != nil) {
        userInfo[kDUUserInfoObjectKey] = _primaryObject;
    }
    if (includeError) {
        NSError *e = self.error;
        if (e != nil) {
            userInfo[kDUUserInfoErrorKey] = e;
        }
    }

    NSNotification *note =
        [NSNotification notificationWithName:name object:self userInfo:userInfo];
    // postNotification: on the center runs on the main run loop, turning the
    // worker-thread event into a main-thread delivery.
    [[NSNotificationCenter defaultCenter]
        performSelectorOnMainThread:@selector(postNotification:)
                         withObject:note
                      waitUntilDone:NO];
}

- (void)setProgress:(double)progress message:(NSString *)message
{
    double clamped = progress < 0.0 ? 0.0 : (progress > 1.0 ? 1.0 : progress);
    [_lock lock];
    // Progress never moves backwards; late callbacks cannot confuse the UI.
    if (clamped > _progress) {
        _progress = clamped;
    }
    _message = [message copy];
    BOOL running = (_state == DUOperationStateRunning ||
                    _state == DUOperationStateCancelling);
    [_lock unlock];

    if (running) {
        [self postNotificationName:DUOperationDidUpdateNotification
                      includeError:NO];
    }
}

// --- Lifecycle -----------------------------------------------------------

- (void)start
{
    [_lock lock];
    if (_state != DUOperationStatePending) {
        [_lock unlock];
        return;
    }
    _state = DUOperationStatePreparing;
    _startTime = [NSDate date];
    [_lock unlock];

    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        [self runOnWorkerThread];
    }];
    thread.name = [NSString stringWithFormat:@"DUOperation %@", _identifier];
    [thread start];
}

- (void)runOnWorkerThread
{
    @autoreleasepool {
        [_lock lock];
        _state = DUOperationStateRunning;
        [_lock unlock];
        [self postNotificationName:DUOperationDidStartNotification
                      includeError:NO];

        @try {
            [self execute];
        } @catch (NSException *exception) {
            // A crashed execute must still reach a terminal state or the
            // managers would leak a busy lock forever.
            NSString *why = exception.reason ?: @"uncaught exception";
            [self finishWithError:DUErrorMake(DUErrorUnknown, why)];
        }
    }
}

- (void)cancel
{
    [_lock lock];
    if (_cancelRequested || [self isTerminalStateLocked]) {
        [_lock unlock];
        return;
    }
    _cancelRequested = YES;
    if (_state == DUOperationStatePending) {
        // Never started: settle it here, -execute will never run for it.
        _state = DUOperationStateCancelled;
        _finishTime = [NSDate date];
        [_lock unlock];
        [self postNotificationName:DUOperationDidFinishNotification
                      includeError:NO];
        return;
    }
    if (_state == DUOperationStateRunning || _state == DUOperationStatePreparing) {
        _state = DUOperationStateCancelling;
    }
    [_lock unlock];
    [self postNotificationName:DUOperationDidUpdateNotification
                  includeError:NO];
}

- (BOOL)finishWithError:(NSError *)error
{
    DUOperationState finalState;
    if (error == nil && ![self cancelRequested]) {
        finalState = DUOperationStateCompleted;
    } else if (error.code == DUErrorCancelled || error == nil) {
        // Success arriving after a cancel request is still a cancellation:
        // the user asked for it and the work did not outlive the request.
        finalState = DUOperationStateCancelled;
    } else {
        finalState = DUOperationStateFailed;
    }

    [_lock lock];
    if ([self isTerminalStateLocked] || _finalized) {
        [_lock unlock];
        return NO;
    }
    _finalized = YES;
    _error = [error copy];
    _finishTime = [NSDate date];
    _progress = 1.0;
    _state = finalState;
    [_lock unlock];

    NSString *name = (finalState == DUOperationStateFailed)
        ? DUOperationDidFailNotification
        : DUOperationDidFinishNotification;
    [self postNotificationName:name includeError:YES];
    return YES;
}

- (void)execute
{
    // Abstract-ish: a subclass that forgets to override must not pass as a
    // successful no-op.
    [NSException raise:NSInternalInconsistencyException
                format:@"-%@ must be overridden", NSStringFromSelector(_cmd)];
}

@end

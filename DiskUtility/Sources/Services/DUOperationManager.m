/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOperationManager.h"

#import "DUErrors.h"
#import "DUNotifications.h"
#import "DUOperation.h"

// History bound; older finished operations fall off the end.
static const NSUInteger DUMaxHistoryEntries = 20;

@implementation DUOperationManager {
    NSLock *_lock;
    NSMutableArray<DUOperation *> *_active;
    NSMutableArray<DUOperation *> *_history;
}

- (instancetype)init
{
    if ((self = [super init]) == nil) {
        return nil;
    }
    _lock = [[NSLock alloc] init];
    _active = [NSMutableArray array];
    _history = [NSMutableArray array];

    // Operations announce their own lifecycle; bookkeeping rides on the same
    // notifications instead of a parallel callback web.
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationNotification:)
               name:DUOperationDidStartNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationNotification:)
               name:DUOperationDidFinishNotification
             object:nil];
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(operationNotification:)
               name:DUOperationDidFailNotification
             object:nil];

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSArray<DUOperation *> *)activeOperations
{
    [_lock lock];
    NSArray *copy = [_active copy];
    [_lock unlock];
    return copy;
}

// Operations still warming up already hold the resource they will touch, so
// Preparing counts as active for the conflict rule.
- (BOOL)isActiveState:(DUOperation *)operation
{
    DUOperationState state = operation.state;
    return state == DUOperationStatePreparing ||
           state == DUOperationStateRunning ||
           state == DUOperationStateCancelling;
}

- (NSString *)resourceIdentifierOfOperationInList:(NSArray<DUOperation *> *)list
                                      excludingOp:(DUOperation *)candidate
{
    for (DUOperation *other in list) {
        if (other == candidate || other.primaryObject == nil) {
            continue;
        }
        // Same-object conflict rule (ARCHITECTURE.md sections 32/54): only
        // work on identical resources serializes, different devices run
        // concurrently.
        if ([self isActiveState:other] &&
            candidate.primaryObject != nil &&
            [other.primaryObject.identifier isEqualToString:
                     candidate.primaryObject.identifier]) {
            return other.primaryObject.identifier;
        }
    }
    return nil;
}

- (BOOL)startOperation:(DUOperation *)operation error:(NSError **)error
{
    NSParameterAssert(operation != nil);

    if (operation.primaryObject == nil) {
        // Objectless operations (image work) cannot conflict.
        [_lock lock];
        [_active addObject:operation];
        [_lock unlock];
        [operation start];
        return YES;
    }

    [_lock lock];
    NSString *busyWith =
        [self resourceIdentifierOfOperationInList:_active excludingOp:operation];
    if (busyWith != nil) {
        [_lock unlock];
        if (error != nil) {
            *error = DUErrorMake(
                DUErrorDeviceBusy,
                [NSString stringWithFormat:@"%@ is busy with another operation",
                                           operation.primaryObject.displayName]);
        }
        return NO;
    }
    [_active addObject:operation];
    [_lock unlock];

    [operation start];
    return YES;
}

- (DUOperation *)operationForIdentifier:(NSString *)identifier
{
    if (identifier.length == 0) {
        return nil;
    }
    [_lock lock];
    DUOperation *found = nil;
    for (DUOperation *operation in _active) {
        if ([operation.identifier isEqualToString:identifier]) {
            found = operation;
            break;
        }
    }
    if (found == nil) {
        for (DUOperation *operation in _history) {
            if ([operation.identifier isEqualToString:identifier]) {
                found = operation;
                break;
            }
        }
    }
    [_lock unlock];
    return found;
}

- (void)cancelOperation:(DUOperation *)operation
{
    [operation cancel];
}

- (void)cancelAllOperations
{
    [_lock lock];
    NSArray *snapshot = [_active copy];
    [_lock unlock];
    for (DUOperation *operation in snapshot) {
        [operation cancel];
    }
}

- (void)operationNotification:(NSNotification *)note
{
    DUOperation *operation = note.userInfo[kDUUserInfoOperationKey];
    BOOL terminal =
        [note.name isEqualToString:DUOperationDidFinishNotification] ||
        [note.name isEqualToString:DUOperationDidFailNotification];
    if (!terminal || operation == nil) {
        return;
    }

    [_lock lock];
    [_active removeObject:operation];
    [_history insertObject:operation atIndex:0];
    while (_history.count > DUMaxHistoryEntries) {
        [_history removeLastObject];
    }
    [_lock unlock];
}

@end

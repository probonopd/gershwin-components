/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DURepairOperation.h"

#import "DUErrors.h"

@implementation DURepairOperation {
    __weak id<DUStorageBackend> _backend;
}

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                         object:(DUStorageObject *)object
{
    NSParameterAssert(backend != nil);
    NSParameterAssert(object != nil);
    if ((self = [super initWithPrimaryObject:object]) == nil) {
        return nil;
    }
    _backend = backend;
    _object = object;
    return self;
}

- (NSString *)displayName
{
    return [NSString stringWithFormat:NSLocalizedString(@"Repair %@", nil),
                     _object.displayName];
}

- (void)execute
{
    if ([self cancelRequested]) {
        [self finishWithError:DUErrorMake(DUErrorCancelled, @"Cancelled before start")];
        return;
    }
    if (![_backend supportsOperation:kDUOperationRepair forObject:_object]) {
        [self finishWithError:
            DUErrorMake(DUErrorUnsupportedOperation,
                        [NSString stringWithFormat:@"%@ cannot be repaired",
                                                   _object.displayName])];
        return;
    }

    [_backend repairObject:_object
                   progress:^(double progress, NSString *message) {
                       [self setProgress:progress message:message];
                 }
                 completion:^(NSError *error) {
                     [self finishWithError:error];
                 }];
}

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUPartitionOperation.h"

#import "DUErrors.h"

@implementation DUPartitionOperation {
    __weak id<DUStorageBackend> _backend;
}

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                         device:(DUStorageObject *)device
                           plan:(DUPartitionPlan *)plan
{
    NSParameterAssert(backend != nil);
    NSParameterAssert(device != nil);
    NSParameterAssert(plan != nil);
    if ((self = [super initWithPrimaryObject:device]) == nil) {
        return nil;
    }
    _backend = backend;
    _device = device;
    _plan = [plan copy];
    return self;
}

- (NSString *)displayName
{
    return [NSString stringWithFormat:NSLocalizedString(@"Partition %@", nil),
                     _device.displayName];
}

- (void)execute
{
    if ([self cancelRequested]) {
        [self finishWithError:DUErrorMake(DUErrorCancelled, @"Cancelled before start")];
        return;
    }
    // The plan snapshot was validated at plan time; re-checking the device
    // here keeps the operation honest even when handed a stale plan.
    if (![_backend supportsOperation:kDUOperationPartition forObject:_device]) {
        [self finishWithError:
            DUErrorMake(DUErrorUnsupportedOperation,
                        [NSString stringWithFormat:@"%@ cannot be partitioned",
                                                   _device.displayName])];
        return;
    }

    [_backend partitionDevice:_device
                      withPlan:_plan
                      progress:^(double progress, NSString *message) {
                          [self setProgress:progress message:message];
                    }
                    completion:^(NSError *error) {
                        [self finishWithError:error];
                    }];
}

@end

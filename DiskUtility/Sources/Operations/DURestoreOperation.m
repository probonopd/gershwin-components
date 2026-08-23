/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DURestoreOperation.h"

#import "DUErrors.h"

@implementation DURestoreOperation {
    __weak id<DUStorageBackend> _backend;
}

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                         source:(DUStorageObject *)source
                     destination:(DUStorageObject *)destination
                         options:(NSDictionary *)options
{
    NSParameterAssert(backend != nil);
    NSParameterAssert(source != nil);
    NSParameterAssert(destination != nil);
    if ((self = [super initWithPrimaryObject:source]) == nil) {
        return nil;
    }
    _backend = backend;
    _source = source;
    _destination = destination;
    _options = [options copy];
    return self;
}

- (NSString *)displayName
{
    return [NSString stringWithFormat:NSLocalizedString(@"Restore %@ to %@", nil),
                     _source.displayName, _destination.displayName];
}

- (void)execute
{
    if ([self cancelRequested]) {
        [self finishWithError:DUErrorMake(DUErrorCancelled, @"Cancelled before start")];
        return;
    }
    if ([_source isEqual:_destination]) {
        [self finishWithError:
            DUErrorMake(DUErrorInvalidArgument,
                        @"Source and destination must differ")];
        return;
    }
    if (![_backend supportsOperation:kDUOperationRestore forObject:_source]) {
        [self finishWithError:
            DUErrorMake(DUErrorUnsupportedOperation,
                        [NSString stringWithFormat:@"%@ cannot be restored from",
                                                   _source.displayName])];
        return;
    }

    [_backend restoreFromSource:_source
                    destination:_destination
                        options:_options
                       progress:^(double progress, NSString *message) {
                           [self setProgress:progress message:message];
                         }
                       completion:^(NSError *error) {
                           [self finishWithError:error];
                         }];
}

@end

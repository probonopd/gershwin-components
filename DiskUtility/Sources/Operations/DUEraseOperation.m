/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUEraseOperation.h"

#import "DUErrors.h"

@implementation DUEraseOperation {
    __weak id<DUStorageBackend> _backend;
}

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                         object:(DUStorageObject *)object
                        options:(NSDictionary *)options
{
    NSParameterAssert(backend != nil);
    NSParameterAssert(object != nil);
    NSParameterAssert(options != nil);
    if ((self = [super initWithPrimaryObject:object]) == nil) {
        return nil;
    }
    _backend = backend;
    _object = object;
    _options = [options copy];
    return self;
}

- (NSString *)displayName
{
    return [NSString stringWithFormat:NSLocalizedString(@"Erase %@", nil),
                     _object.displayName];
}

- (void)execute
{
    if ([self cancelRequested]) {
        [self finishWithError:DUErrorMake(DUErrorCancelled, @"Cancelled before start")];
        return;
    }
    if (![_backend supportsOperation:kDUOperationErase forObject:_object]) {
        [self finishWithError:
            DUErrorMake(DUErrorUnsupportedOperation,
                        [NSString stringWithFormat:@"%@ cannot be erased",
                                                   _object.displayName])];
        return;
    }

    [_backend eraseObject:_object
                  options:_options
                  progress:^(double progress, NSString *message) {
                      [self setProgress:progress message:message];
                }
                completion:^(NSError *error) {
                    [self finishWithError:error];
                }];
}

@end

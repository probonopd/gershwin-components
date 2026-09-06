/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUConvertImageOperation.h"

#import "DUErrors.h"

@interface DUConvertImageOperation ()
@property (nonatomic, weak) id<DUStorageBackend> backend;
@property (nonatomic, strong, readwrite) DUStorageObject *object;
@property (nonatomic, copy, readwrite) NSDictionary *options;
@end

@implementation DUConvertImageOperation

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                         object:(DUStorageObject *)object
                        options:(NSDictionary *)options
{
    NSParameterAssert(backend != nil);
    NSParameterAssert(object != nil);
    self = [super initWithPrimaryObject:object];
    if (self == nil) {
        return nil;
    }
    _backend = backend;
    _object = object;
    _options = [options copy];
    return self;
}

// Runs on the operation worker thread (base-class contract); progress and
// completion arrive on arbitrary threads per the backend contract.
- (void)execute
{
    void (^progressBlock)(double, NSString *) =
        ^(double value, NSString *message) {
            [self setProgress:value message:message];
        };
    __weak typeof(self) weakSelf = self;
    void (^completionBlock)(NSError *) =
        ^(NSError *error) {
            [weakSelf finishWithError:error];
        };

    id<DUStorageBackend> backend = self.backend;
    if (![backend respondsToSelector:@selector(convertImage:options:
                                                        progress:
                                                      completion:)]) {
        [self finishWithError:DUErrorMake(
                                  DUErrorUnsupportedOperation,
                                  NSLocalizedString(
                                      @"This backend cannot convert "
                                      @"images.", nil))];
        return;
    }
    [backend convertImage:self.object
                  options:self.options
                 progress:progressBlock
               completion:completionBlock];
}

@end

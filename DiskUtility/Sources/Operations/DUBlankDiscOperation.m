/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUBlankDiscOperation.h"

#import "DUErrors.h"

@interface DUBlankDiscOperation ()
@property (nonatomic, weak) id<DUStorageBackend> backend;
@property (nonatomic, strong, readwrite) DUStorageObject *opticalDrive;
@property (nonatomic, copy) NSDictionary *options;
@end

@implementation DUBlankDiscOperation

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                    opticalDrive:(DUStorageObject *)opticalDrive
                         options:(NSDictionary *)options
{
    NSParameterAssert(backend != nil);
    NSParameterAssert(opticalDrive != nil);
    self = [super initWithPrimaryObject:opticalDrive];
    if (self == nil) {
        return nil;
    }
    _backend = backend;
    _opticalDrive = opticalDrive;
    _options = options ?: @{};
    return self;
}

- (instancetype)initWithPrimaryObject:(DUStorageObject *)object
{
    return [self initWithBackend:nil opticalDrive:object options:nil];
}

- (NSString *)displayName
{
    return [NSString stringWithFormat:NSLocalizedString(@"Blank %@",
                                                       @"blank disc operation"),
                      self.opticalDrive.displayName ?: @"disc"];
}

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
    if (![backend respondsToSelector:@selector(blankOpticalDisc:
                                                       options:
                                                       progress:
                                                     completion:)]) {
        [self finishWithError:DUErrorMake(
                                  DUErrorUnsupportedOperation,
                                  NSLocalizedString(
                                      @"This backend cannot blank discs.",
                                      nil))];
        return;
    }
    [backend blankOpticalDisc:self.opticalDrive
                      options:self.options
                     progress:progressBlock
                   completion:completionBlock];
}

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUBurnOperation.h"

#import "DUErrors.h"

@interface DUBurnOperation ()
@property (nonatomic, weak) id<DUStorageBackend> backend;
@property (nonatomic, strong, readwrite) DUStorageObject *image;
@property (nonatomic, strong, readwrite) DUStorageObject *opticalDrive;
@end

@implementation DUBurnOperation

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                          image:(DUStorageObject *)image
                   opticalDrive:(DUStorageObject *)opticalDrive
{
    NSParameterAssert(backend != nil);
    NSParameterAssert(image != nil);
    NSParameterAssert(opticalDrive != nil);
    self = [super initWithPrimaryObject:opticalDrive];
    if (self == nil) {
        return nil;
    }
    _backend = backend;
    _image = image;
    _opticalDrive = opticalDrive;
    return self;
}

- (NSString *)displayName
{
    return [NSString stringWithFormat:NSLocalizedString(@"Burn %@",
                                                        @"burn operation"),
                     self.image.displayName ?: @"image"];
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
    if (![backend respondsToSelector:@selector(burnImage:toObject:
                                                        progress:
                                                      completion:)]) {
        [self finishWithError:DUErrorMake(
                                  DUErrorUnsupportedOperation,
                                  NSLocalizedString(
                                      @"This backend cannot burn discs.",
                                      nil))];
        return;
    }
    [backend burnImage:self.image
              toObject:self.opticalDrive
              progress:progressBlock
            completion:completionBlock];
}

@end

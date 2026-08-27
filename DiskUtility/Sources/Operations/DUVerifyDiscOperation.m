/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUVerifyDiscOperation.h"

#import "DUErrors.h"

@interface DUVerifyDiscOperation ()
@property (nonatomic, weak) id<DUStorageBackend> backend;
@property (nonatomic, strong, readwrite) DUStorageObject *opticalDrive;
@property (nonatomic, strong, readwrite) DUStorageObject *image;
@end

@implementation DUVerifyDiscOperation

- (instancetype)initWithBackend:(id<DUStorageBackend>)backend
                    opticalDrive:(DUStorageObject *)opticalDrive
                           image:(DUStorageObject *)image
{
    NSParameterAssert(backend != nil);
    NSParameterAssert(opticalDrive != nil);
    NSParameterAssert(image != nil);
    self = [super initWithPrimaryObject:opticalDrive];
    if (self == nil) {
        return nil;
    }
    _backend = backend;
    _opticalDrive = opticalDrive;
    _image = image;
    return self;
}

- (instancetype)initWithPrimaryObject:(DUStorageObject *)object
{
    return [self initWithBackend:nil opticalDrive:object image:nil];
}

- (NSString *)displayName
{
    return [NSString stringWithFormat:NSLocalizedString(@"Verify %@",
                                                       @"verify disc operation"),
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
    if (![backend respondsToSelector:@selector(verifyDisc:
                                                  againstImage:
                                                      progress:
                                                    completion:)]) {
        [self finishWithError:DUErrorMake(
                                  DUErrorUnsupportedOperation,
                                  NSLocalizedString(
                                      @"This backend cannot verify discs.",
                                      nil))];
        return;
    }
    [backend verifyDisc:self.opticalDrive
           againstImage:self.image
               progress:progressBlock
             completion:completionBlock];
}

@end

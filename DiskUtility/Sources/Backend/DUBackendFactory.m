/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUBackendFactory.h"

#import <sys/utsname.h>

#import "DUBackendCapabilities.h"
#import "DUMockStorageBackend.h"
#import "DUErrors.h"

// Hosted here because DUBackendCapabilities.h is pinned header-only in the
// wave file set (see comment there).
@implementation DUBackendReport

- (void)setAll:(BOOL)value
{
    _discovery = value;
    _mountManagement = value;
    _partitioning = value;
    _filesystemFormat = value;
    _filesystemRepair = value;
    _secureErase = value;
    _raidManagement = value;
    _imageCreate = value;
    _imageConvert = value;
    _imageResize = value;
    _burn = value;
}

- (NSDictionary<NSString *, NSString *> *)reportDictionary
{
    struct utsname un;
    NSString *platform =
        (uname(&un) == 0) ? @(un.sysname) : NSLocalizedString(@"Unknown", nil);

    return @{
        @"Platform" : platform,
        @"Device discovery" : _discovery ? @"yes" : @"no",
        @"Mount management" : _mountManagement ? @"yes" : @"no",
        @"Partitioning" : _partitioning ? @"yes" : @"no",
        @"Filesystem formatting" : _filesystemFormat ? @"yes" : @"no",
        @"Filesystem repair" : _filesystemRepair ? @"yes" : @"no",
        @"Secure erase" : _secureErase ? @"yes" : @"no",
        @"RAID management" : _raidManagement ? @"yes" : @"no",
        @"Disk image creation" : _imageCreate ? @"yes" : @"no",
        @"Disk image conversion" : _imageConvert ? @"yes" : @"no",
        @"Disk image resizing" : _imageResize ? @"yes" : @"no",
        @"Optical burning" : _burn ? @"yes" : @"no",
    };
}

@end

@implementation DUBackendFactory

+ (NSString *)backendClassNameForPlatform
{
#if defined(__linux__)
    return @"DULinuxStorageBackend";
#elif defined(__FreeBSD__)
    return @"DUFreeBSDStorageBackend";
#elif defined(__OpenBSD__)
    return @"DUOpenBSDStorageBackend";
#elif defined(__NetBSD__)
    return @"DUNetBSDStorageBackend";
#else
    // Unknown platform: no backend class name at all, so the factory falls
    // through to the degraded mock and the app stays launchable.
    return nil;
#endif
}

+ (id<DUStorageBackend>)backendForArguments:(NSArray *)arguments
                                     error:(NSError **)error
{
    // --mock must stay per-process: an earlier build wrote it to the
    // persistent defaults, which made every later launch silently run the
    // mock backend.
    if ([arguments indexOfObject:@"--mock"] != NSNotFound) {
        return [[DUMockStorageBackend alloc] init];
    }

    NSString *className = [self backendClassNameForPlatform];
    Class cls = NSClassFromString(className);
    if (cls != Nil) {
        id<DUStorageBackend> backend = [[cls alloc] init];
        if (backend != nil) {
            return backend;
        }
    }

    // Known OS whose backend was not compiled in, or unknown OS entirely:
    // degrade gracefully instead of failing startup (ARCHITECTURE.md 65/66).
    if (error != NULL) {
        *error = DUErrorMake(DUErrorBackendUnavailable,
                             NSLocalizedString(
                                 @"Storage management is not available on this "
                                 @"system. No compatible storage backend was "
                                 @"detected.",
                                 nil));
    }
    return [DUMockStorageBackend degradedBackend];
}

+ (id<DUStorageBackend>)backendWithError:(NSError **)error
{
    return [self backendForArguments:
                    [NSProcessInfo processInfo].arguments
                                      error:error];
}

@end

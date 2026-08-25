/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageDevice.h"

@implementation DUStorageDevice

- (instancetype)initWithIdentifier:(NSString *)identifier
{
    return [super initWithType:DUStorageObjectTypeDevice identifier:identifier];
}

// The type is fixed by the class; refuse mismatches instead of guessing.
- (instancetype)initWithType:(DUStorageObjectType)type
                   identifier:(NSString *)identifier
{
    NSParameterAssert(type == DUStorageObjectTypeDevice);
    return [super initWithType:DUStorageObjectTypeDevice identifier:identifier];
}

// Best-effort SMART self-assessment for a block device.  Relies on
// smartmontools' smartctl, which may be absent or require privileges; any
// failure degrades to "Not Supported" rather than fabricating a result.
+ (DUStorageSmartStatus)querySmartStatusForPath:(NSString *)devicePath
{
    if (devicePath.length == 0) {
        return DUStorageSmartStatusNotSupported;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *launchPath = nil;
    for (NSString *candidate in @[
             @"/usr/sbin/smartctl", @"/usr/local/sbin/smartctl",
             @"/sbin/smartctl"
         ]) {
        if ([fm isExecutableFileAtPath:candidate]) {
            launchPath = candidate;
            break;
        }
    }
    if (launchPath == nil) {
        return DUStorageSmartStatusNotSupported;
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:launchPath];
    [task setArguments:@[ @"-H", devicePath ]];
    NSPipe *outPipe = [NSPipe pipe];
    [task setStandardOutput:outPipe];
    [task setStandardError:[NSPipe pipe]];
    @try {
        [task launch];
    } @catch (NSException *e) {
        return DUStorageSmartStatusNotSupported;
    }
    [task waitUntilExit];

    // smartctl exit codes: 0 = passed, 2 = device open failed / not
    // capable, 4 = FAILED. 1 is a usage error.
    int status = [task terminationStatus];
    if (status == 4) {
        return DUStorageSmartStatusFailing;
    }
    if (status == 2) {
        return DUStorageSmartStatusNotSupported;
    }

    NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = data != nil
        ? [[NSString alloc] initWithData:data
                                encoding:NSUTF8StringEncoding]
        : @"";
    NSString *upper = [output uppercaseString];
    if ([upper containsString:@"FAILED"] ||
        [upper containsString:@"FAILURE"]) {
        return DUStorageSmartStatusFailing;
    }
    if ([upper containsString:@"PASSED"] || [upper containsString:@"OK"]) {
        return DUStorageSmartStatusVerified;
    }
    return DUStorageSmartStatusNotSupported;
}

+ (NSString *)localizedSmartStatus:(DUStorageSmartStatus)status
{
    switch (status) {
        case DUStorageSmartStatusVerified:
            return NSLocalizedString(@"Verified", nil);
        case DUStorageSmartStatusFailing:
            return NSLocalizedString(@"Failing", nil);
        case DUStorageSmartStatusNotSupported:
            return NSLocalizedString(@"Not Supported", nil);
        case DUStorageSmartStatusUnknown:
        default:
            return NSLocalizedString(@"Unknown", nil);
    }
}

@end

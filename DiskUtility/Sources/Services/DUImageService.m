/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUImageService.h"

#import "DUErrors.h"

NSString *const kDUImageFormatRaw = @"raw";
NSString *const kDUImageFormatQCow2 = @"qcow2";
NSString *const kDUImageFormatVMDK = @"vmdk";
NSString *const kDUImageFormatVDI = @"vdi";

// Enough to cover the VDI magic at offset 0x40 plus margin.
static const NSUInteger DUImageMagicProbeLength = 128;

@implementation DUImageService

+ (BOOL)createImageAtPath:(NSString *)path
                sizeBytes:(unsigned long long)sizeBytes
                    error:(NSError **)error
{
    NSParameterAssert(path.length > 0);

    NSFileManager *fileManager = [NSFileManager defaultManager];
    // createFileContentsAttributes yields an empty file we can truncate;
    // existing files are resized in place, matching truncate semantics.
    if (![fileManager fileExistsAtPath:path]) {
        if (![fileManager createFileAtPath:path contents:nil attributes:nil]) {
            if (error != nil) {
                *error = DUErrorMake(DUErrorUnknown,
                                     [NSString stringWithFormat:NSLocalizedString(@"Cannot create %@", nil),
                                                path]);
            }
            return NO;
        }
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle == nil) {
        if (error != nil) {
            *error = DUErrorMake(DUErrorPermissionDenied,
                                 [NSString stringWithFormat:NSLocalizedString(@"Cannot open %@ for writing", nil),
                                            path]);
        }
        return NO;
    }
    @try {
        [handle truncateFileAtOffset:sizeBytes];
        [handle synchronizeFile];
    } @catch (NSException *exception) {
        if (error != nil) {
            *error = DUErrorMake(DUErrorUnknown,
                                 exception.reason ?: NSLocalizedString(@"Truncate failed", nil));
        }
        [handle closeFile];
        return NO;
    }
    [handle closeFile];
    return YES;
}

+ (NSString *)imageFormatAtPath:(NSString *)path
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (handle == nil) {
        return kDUImageFormatRaw;
    }
    NSData *probe = [handle readDataOfLength:DUImageMagicProbeLength];
    [handle closeFile];

    const unsigned char *bytes = probe.bytes;
    if (probe.length < 4) {
        return kDUImageFormatRaw;
    }

    // qcow2: "QFI\xfb" at offset 0.
    if (memcmp(bytes, "QFI\xfb", 4) == 0) {
        return kDUImageFormatQCow2;
    }
    // VMDK: "KDMV" at offset 0.
    if (memcmp(bytes, "KDMV", 4) == 0) {
        return kDUImageFormatVMDK;
    }
    // VDI: magic 0xbeda107f little-endian at offset 0x40.
    static const NSUInteger vdiOffset = 0x40;
    if (probe.length >= vdiOffset + 4 &&
        bytes[vdiOffset] == 0x7f && bytes[vdiOffset + 1] == 0x10 &&
        bytes[vdiOffset + 2] == 0xda && bytes[vdiOffset + 3] == 0xbe) {
        return kDUImageFormatVDI;
    }
    return kDUImageFormatRaw;
}

@end

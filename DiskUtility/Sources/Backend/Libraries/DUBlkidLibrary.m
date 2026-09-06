/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUBlkidLibrary.h"
#import <string.h>

// The C library header is only pulled in when the build enables libblkid;
// the stub path must compile on systems without the header at all.
#ifdef HAVE_LIBBLKID
#import <blkid/blkid.h>
#endif

NSString * const kDUBlkidFstype = @"fstype";
NSString * const kDUBlkidUuid = @"uuid";
NSString * const kDUBlkidLabel = @"label";
NSString * const kDUBlkidUsage = @"usage";

#ifdef HAVE_LIBBLKID
// Copies a NUL-terminated blkid value into an NSString, returning nil for
// values that are not valid UTF-8 (labels may hold arbitrary bytes); such
// properties stay absent from the result instead of being garbled.
static NSString *BlkidValueToString(const char *value)
{
    if (value == NULL) {
        return nil;
    }
    return [NSString stringWithUTF8String:value];
}
#endif

@implementation DUBlkidLibrary

+ (BOOL)isAvailable
{
#ifdef HAVE_LIBBLKID
    return YES;
#else
    // Explicit "not compiled in" state; see header documentation.
    return NO;
#endif
}

+ (NSDictionary *)probeDevicePath:(NSString *)path
{
#ifndef HAVE_LIBBLKID
    return nil;
#else
    if (path == nil || path.length == 0) {
        return nil;
    }
    const char *filesystemPath = path.fileSystemRepresentation;
    if (filesystemPath == NULL || strlen(filesystemPath) == 0) {
        return nil;
    }

    blkid_probe probe = blkid_new_probe_from_filename(filesystemPath);
    if (probe == NULL) {
        return nil;
    }

    NSDictionary *result = nil;
    if (blkid_probe_enable_superblocks(probe, 1) == 0 &&
        blkid_probe_set_superblocks_flags(
            probe, BLKID_SUBLKS_DEFAULT | BLKID_SUBLKS_USAGE) == 0 &&
        blkid_do_fullprobe(probe) == 0) {
        // Values returned by blkid_probe_lookup_value() are owned by the
        // probe and released with it; no separate free is needed.
        NSMutableDictionary *properties = [NSMutableDictionary dictionary];
        const char *names[] = { "TYPE", "UUID", "LABEL", "USAGE" };
        NSString *keys[] = { kDUBlkidFstype, kDUBlkidUuid,
                             kDUBlkidLabel, kDUBlkidUsage };
        for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
            const char *data = NULL;
            size_t length = 0;
            if (blkid_probe_lookup_value(probe, names[i],
                                         &data, &length) == 0 &&
                data != NULL && length > 0) {
                NSString *value = BlkidValueToString(data);
                if (value != nil) {
                    properties[keys[i]] = value;
                }
            }
        }
        result = properties;
    }

    blkid_free_probe(probe);
    return result;
#endif
}

@end

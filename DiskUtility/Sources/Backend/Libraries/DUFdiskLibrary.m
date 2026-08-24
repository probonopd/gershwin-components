/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUFdiskLibrary.h"
#import <string.h>

// The C library header is only pulled in when the build enables libfdisk;
// the stub path must compile on systems without the header at all.
#ifdef HAVE_LIBFDISK
#import <libfdisk/libfdisk.h>
#endif

NSString * const kDUFdiskScheme = @"scheme";
NSString * const kDUFdiskPartitions = @"partitions";
NSString * const kDUFdiskIndex = @"index";
NSString * const kDUFdiskStartBytes = @"startBytes";
NSString * const kDUFdiskSizeBytes = @"sizeBytes";
NSString * const kDUFdiskType = @"type";
NSString * const kDUFdiskName = @"name";
NSString * const kDUFdiskUuid = @"uuid";

#ifdef HAVE_LIBFDISK
// Copies a NUL-terminated libfdisk value into an NSString, returning nil
// for values that are not valid UTF-8; such properties stay absent from
// the result instead of being garbled. Strings returned by libfdisk
// accessors are owned by their objects and need no separate free.
static NSString *FdiskValueToString(const char *value)
{
    if (value == NULL) {
        return nil;
    }
    return [NSString stringWithUTF8String:value];
}
#endif

@implementation DUFdiskLibrary

+ (BOOL)isAvailable
{
#ifdef HAVE_LIBFDISK
    return YES;
#else
    // Explicit "not compiled in" state; see header documentation.
    return NO;
#endif
}

+ (NSDictionary *)inspectPath:(NSString *)path
{
#ifndef HAVE_LIBFDISK
    (void)path;
    return nil;
#else
    if (path == nil || path.length == 0) {
        return nil;
    }
    const char *devicePath = path.fileSystemRepresentation;
    if (devicePath == NULL || strlen(devicePath) == 0) {
        return nil;
    }

    struct fdisk_context *context = fdisk_new_context();
    if (context == NULL) {
        return nil;
    }

    NSDictionary *result = nil;
    BOOL assigned =
        // readonly=1: inspection must never open the target writable.
        fdisk_assign_device(context, devicePath, 1) == 0;
    if (assigned && fdisk_has_label(context) > 0) {
        NSMutableDictionary *inspection = [NSMutableDictionary dictionary];
        const struct fdisk_label *label = fdisk_get_label(context, NULL);
        NSString *scheme =
            FdiskValueToString(label != NULL ?
                                   fdisk_label_get_name(label) : NULL);
        if (scheme.length > 0) {
            // Label names arrive as short lowercase tokens ("gpt", "dos",
            // "bsd"); normalize defensively so callers can rely on that.
            inspection[kDUFdiskScheme] = scheme.lowercaseString;
        }

        unsigned long sectorSize = fdisk_get_sector_size(context);
        if (sectorSize == 0) {
            sectorSize = 512;
        }

        struct fdisk_table *table = NULL;
        if (fdisk_get_partitions(context, &table) == 0 && table != NULL) {
            NSMutableArray<NSDictionary *> *partitions = [NSMutableArray array];
            struct fdisk_iter *iterator = fdisk_new_iter(FDISK_ITER_FORWARD);
            struct fdisk_partition *partition = NULL;
            while (iterator != NULL &&
                   fdisk_table_next_partition(table, iterator,
                                              &partition) == 0 &&
                   partition != NULL) {
                // Free-space rows describe gaps, not partitions.
                if (fdisk_partition_is_freespace(partition)) {
                    continue;
                }
                NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                entry[kDUFdiskIndex] =
                    @((NSUInteger)fdisk_partition_get_partno(partition));
                entry[kDUFdiskStartBytes] = @(
                    (unsigned long long)fdisk_partition_get_start(partition)
                    * sectorSize);
                entry[kDUFdiskSizeBytes] = @(
                    (unsigned long long)fdisk_partition_get_size(partition)
                    * sectorSize);
                const struct fdisk_parttype *type =
                    fdisk_partition_get_type(partition);
                if (type != NULL) {
                    // GUID string for GPT, numeric id for DOS tables; the
                    // human-readable name fills in when a table carries no
                    // type string.
                    NSString *typeValue =
                        FdiskValueToString(fdisk_parttype_get_string(type));
                    if (typeValue.length == 0) {
                        typeValue = FdiskValueToString(
                            fdisk_parttype_get_name(type));
                    }
                    if (typeValue.length > 0) {
                        entry[kDUFdiskType] = typeValue;
                    }
                }
                NSString *name =
                    FdiskValueToString(fdisk_partition_get_name(partition));
                if (name.length > 0) {
                    entry[kDUFdiskName] = name;
                }
                NSString *uuid =
                    FdiskValueToString(fdisk_partition_get_uuid(partition));
                if (uuid.length > 0) {
                    entry[kDUFdiskUuid] = uuid;
                }
                [partitions addObject:entry];
            }
            if (iterator != NULL) {
                fdisk_free_iter(iterator);
            }
            inspection[kDUFdiskPartitions] = partitions;
            result = inspection;
        }
    }

    // deassign asserts on a never-assigned context (failed open), so it
    // only runs after a successful assign; unref is always safe and frees
    // the context itself. nosync=1 avoids flushing a read-only handle.
    if (assigned) {
        fdisk_deassign_device(context, 1);
    }
    fdisk_unref_context(context);
    return result;
#endif
}

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUMountLibrary.h"

NSString * const kDUMountDevice = @"device";
NSString * const kDUMountPoint = @"mountPoint";
NSString * const kDUMountFstype = @"fstype";
NSString * const kDUMountReadOnly = @"readOnly";

#ifdef HAVE_LIBMOUNT
#import <libmount/libmount.h>

// WHY not mnt_fs_is_readonly(): that function is not declared by the
// libmount.h of every supported platform version, so read-only state is
// derived from the mount option string instead - the same information the
// libmount helper itself uses (the bare "ro" flag token).
static BOOL MountOptionsAreReadOnly(const char *options)
{
    if (options == NULL) {
        return NO;
    }
    const char *cursor = options;
    while (*cursor != '\0') {
        const char *tokenEnd = strchr(cursor, ',');
        size_t tokenLength = (tokenEnd != NULL)
            ? (size_t)(tokenEnd - cursor)
            : strlen(cursor);
        if (tokenLength == 2 && strncmp(cursor, "ro", 2) == 0) {
            return YES;
        }
        if (tokenEnd == NULL) {
            break;
        }
        cursor = tokenEnd + 1;
    }
    return NO;
}
#endif /* HAVE_LIBMOUNT */

@implementation DUMountLibrary

+ (BOOL)isAvailable
{
#ifdef HAVE_LIBMOUNT
    return YES;
#else
    // Explicit "not compiled in" state; see header documentation.
    return NO;
#endif
}

+ (NSArray *)listMounts
{
#ifndef HAVE_LIBMOUNT
    return nil;
#else
    struct libmnt_table *table = mnt_new_table();
    if (table == NULL) {
        return nil;
    }

    NSArray *result = nil;
    // Passing a NULL filename makes libmount resolve the appropriate
    // mount table source itself (/proc/self/mountinfo and friends).
    if (mnt_table_parse_mtab(table, NULL) == 0) {
        struct libmnt_iter *iterator = mnt_new_iter(MNT_ITER_FORWARD);
        NSMutableArray *mounts = [NSMutableArray array];
        if (iterator != NULL) {
            struct libmnt_fs *filesystem = NULL;
            while (mnt_table_next_fs(table, iterator, &filesystem) == 0 &&
                   filesystem != NULL) {
                const char *source = mnt_fs_get_source(filesystem);
                const char *target = mnt_fs_get_target(filesystem);
                const char *type = mnt_fs_get_fstype(filesystem);
                const char *options = mnt_fs_get_options(filesystem);
                // Strings are owned by the table entry and stay valid for
                // the duration of this call; copied into NSStrings below.
                NSMutableDictionary *entry =
                    [NSMutableDictionary dictionary];
                if (source != NULL) {
                    entry[kDUMountDevice] = @(source);
                }
                if (target != NULL) {
                    entry[kDUMountPoint] = @(target);
                }
                if (type != NULL) {
                    entry[kDUMountFstype] = @(type);
                }
                entry[kDUMountReadOnly] =
                    @(MountOptionsAreReadOnly(options));
                [mounts addObject:entry];
            }
            mnt_free_iter(iterator);
            result = mounts;
        }
    }

    mnt_unref_table(table);
    return result;
#endif
}

@end

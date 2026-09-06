/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUExt2Library.h"
#import <string.h>

// Pulled in only when the build enables libext2fs; the stub path must
// compile on systems without the header at all.
#ifdef HAVE_LIBEXT2FS
#import <ext2fs/ext2fs.h>
#endif

NSString * const kDUExt2TotalBytes = @"totalBytes";
NSString * const kDUExt2FreeBytes = @"freeBytes";
NSString * const kDUExt2VolumeLabel = @"volumeLabel";
NSString * const kDUExt2Uuid = @"uuid";

@implementation DUExt2Library

+ (BOOL)isAvailable
{
#ifdef HAVE_LIBEXT2FS
    // Linked-in libext2fs is what provides the ability to open ext
    // filesystems; per-path outcomes are reported by the methods below.
    return YES;
#else
    // Explicit "not compiled in" state; see header documentation.
    return NO;
#endif
}

#ifdef HAVE_LIBEXT2FS

// Shared read-only open. Flags verified against the installed ext2fs.h:
// there is no EXT2_FLAG_RDONLY - omitting EXT2_FLAG_RW is what makes the
// open strictly read-only. EXT2_FLAG_FORCE tolerates unclean states,
// EXT2_FLAG_SKIP_MMP avoids MMP interference during the read.
+ (NSDictionary *)statsForPathInternal:(const char *)filesystemPath
{
    ext2_filsys filesystem = NULL;
    // superblock=0 and block_size=0 make libext2fs read both from the
    // primary superblock instead of assuming fixed values.
    errcode_t status =
        ext2fs_open(filesystemPath, EXT2_FLAG_FORCE | EXT2_FLAG_SKIP_MMP,
                    0, 0, unix_io_manager, &filesystem);
    if (status != 0 || filesystem == NULL) {
        return nil;
    }

    NSDictionary *result = nil;
    struct ext2_super_block *superblock = filesystem->super;
    if (superblock != NULL) {
        unsigned long long blockSize = EXT2_BLOCK_SIZE(superblock);
        unsigned long long totalBlocks = ext2fs_blocks_count(superblock);
        unsigned long long freeBlocks = ext2fs_free_blocks_count(superblock);

        NSMutableDictionary *stats = [NSMutableDictionary dictionary];
        stats[kDUExt2TotalBytes] =
            @(totalBlocks * blockSize);
        stats[kDUExt2FreeBytes] =
            @(freeBlocks * blockSize);

        // s_volume_name is a fixed 16-byte field without a guaranteed NUL
        // terminator, so it is copied out bounded before conversion.
        char label[EXT2_LABEL_LEN + 1];
        memcpy(label, superblock->s_volume_name, EXT2_LABEL_LEN);
        label[EXT2_LABEL_LEN] = '\0';
        NSString *volumeLabel = [NSString stringWithUTF8String:label];
        if (volumeLabel.length > 0) {
            stats[kDUExt2VolumeLabel] = volumeLabel;
        }

        const unsigned char *uuidBytes = superblock->s_uuid;
        BOOL uuidIsZero = YES;
        for (int i = 0; i < 16; i++) {
            if (uuidBytes[i] != 0) {
                uuidIsZero = NO;
                break;
            }
        }
        if (!uuidIsZero) {
            stats[kDUExt2Uuid] =
                [NSString stringWithFormat:
                    @"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-"
                    @"%02x%02x%02x%02x%02x%02x",
                    uuidBytes[0], uuidBytes[1], uuidBytes[2],
                    uuidBytes[3], uuidBytes[4], uuidBytes[5],
                    uuidBytes[6], uuidBytes[7], uuidBytes[8],
                    uuidBytes[9], uuidBytes[10], uuidBytes[11],
                    uuidBytes[12], uuidBytes[13], uuidBytes[14],
                    uuidBytes[15]];
        }

        result = stats;
    }

    // Closes in all paths; also releases the handle on success.
    ext2fs_close_free(&filesystem);
    return result;
}

#endif /* HAVE_LIBEXT2FS */

+ (BOOL)isExtFilesystemPath:(NSString *)path
{
#ifndef HAVE_LIBEXT2FS
    return NO;
#else
    if (path == nil || path.length == 0) {
        return NO;
    }
    const char *filesystemPath = path.fileSystemRepresentation;
    if (filesystemPath == NULL || strlen(filesystemPath) == 0) {
        return NO;
    }

    // Read-only probe: an ext signature opens successfully, anything else
    // fails to open under these flags.
    ext2_filsys filesystem = NULL;
    errcode_t status =
        ext2fs_open(filesystemPath, EXT2_FLAG_FORCE | EXT2_FLAG_SKIP_MMP,
                    0, 0, unix_io_manager, &filesystem);
    if (status != 0 || filesystem == NULL) {
        return NO;
    }
    ext2fs_close_free(&filesystem);
    return YES;
#endif
}

+ (NSDictionary *)statsForPath:(NSString *)path
{
#ifndef HAVE_LIBEXT2FS
    return nil;
#else
    if (path == nil || path.length == 0) {
        return nil;
    }
    const char *filesystemPath = path.fileSystemRepresentation;
    if (filesystemPath == NULL || strlen(filesystemPath) == 0) {
        return nil;
    }
    return [self statsForPathInternal:filesystemPath];
#endif
}

@end

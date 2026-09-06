/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUArchiveLibrary.h"

// Pulled in only when the build enables libarchive; the stub path must
// compile on systems without the header at all.
#ifdef HAVE_LIBARCHIVE
#import <archive.h>
#import <archive_entry.h>
#endif

NSString * const kDUArchiveFormat = @"format";
NSString * const kDUArchiveEntryCount = @"entryCount";

const NSUInteger kDUArchiveEntryCountCap = 512;

@implementation DUArchiveLibrary

+ (BOOL)isAvailable
{
#ifdef HAVE_LIBARCHIVE
    return YES;
#else
    // Explicit "not compiled in" state; see header documentation.
    return NO;
#endif
}

+ (NSDictionary *)identifyPath:(NSString *)path
{
#ifndef HAVE_LIBARCHIVE
    return nil;
#else
    if (path == nil || path.length == 0) {
        return nil;
    }
    const char *filesystemPath = path.fileSystemRepresentation;
    if (filesystemPath == NULL || strlen(filesystemPath) == 0) {
        return nil;
    }

    struct archive *reader = archive_read_new();
    if (reader == NULL) {
        return nil;
    }

    NSDictionary *result = nil;
    archive_read_support_filter_all(reader);
    archive_read_support_format_all(reader);
    // 8 KB block size; opens strictly read-only by nature.
    if (archive_read_open_filename(reader, filesystemPath, 8 * 1024) ==
        ARCHIVE_OK) {
        NSUInteger entryCount = 0;
        const char *formatName = NULL;
        int status = ARCHIVE_OK;
        while (entryCount < kDUArchiveEntryCountCap) {
            struct archive_entry *entry = NULL;
            status = archive_read_next_header(reader, &entry);
            if (status != ARCHIVE_OK && status != ARCHIVE_WARN) {
                break;
            }
            if (formatName == NULL) {
                formatName = archive_format_name(reader);
            }
            entryCount++;
        }

        // Format detection happens with the first parsed header, so EOF
        // or a capped scan after at least one entry still yields it; a
        // fatal error before any header means no recognized archive.
        if ((status == ARCHIVE_EOF ||
             entryCount >= kDUArchiveEntryCountCap) &&
            formatName != NULL) {
            result = @{
                kDUArchiveFormat: @(formatName),
                kDUArchiveEntryCount: @(entryCount)
            };
        }
    }

    // Frees the handle in all paths; free implies close.
    archive_read_free(reader);
    return result;
#endif
}

@end

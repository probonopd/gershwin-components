/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUPartitionTableParser.h"

NSString * const kDisklabelKeyTotalSectors = @"totalSectors";
NSString * const kDisklabelKeySectorSize = @"sectorSize";
NSString * const kDisklabelKeyPartitions = @"partitions";

NSString * const kDisklabelKeyLetter = @"letter";
NSString * const kDisklabelKeySizeBytes = @"sizeBytes";
NSString * const kDisklabelKeyOffsetBytes = @"offsetBytes";
NSString * const kDisklabelKeyFstype = @"fstype";
NSString * const kDisklabelKeyMountPoint = @"mountPoint";

// Filesystem display table; extended by adding entries here.
static NSDictionary<NSString *, NSString *> *sFilesystemTable = nil;

@implementation DUPartitionTableParser

+ (void)initialize
{
    if (self == [DUPartitionTableParser class]) {
        // Built in +initialize so creation happens exactly once under the
        // runtime's class-initialization lock; avoids lazy-init races
        // without resorting to libdispatch.
        sFilesystemTable = @{
            @"ext2": @"Extended filesystem (ext2)",
            @"ext3": @"Extended filesystem (ext3)",
            @"ext4": @"Extended filesystem (ext4)",
            @"vfat": @"FAT",
            @"fat": @"FAT",
            @"msdos": @"FAT",
            @"ufs": @"UFS",
            @"zfs": @"ZFS",
            @"ntfs": @"NTFS",
            @"iso9660": @"ISO 9660",
            @"cd9660": @"ISO 9660",
            @"swap": @"Swap",
        };
    }
}

+ (NSString *)normalizeSchemeToken:(NSString *)token
{
    if (token == nil) {
        return nil;
    }
    NSMutableString *t = [[token stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]] mutableCopy];
    [t replaceOccurrencesOfString:@"_"
                        withString:@" "
                           options:NSLiteralSearch
                             range:NSMakeRange(0, [t length])];
    NSString *lower = [t lowercaseString];

    if ([lower containsString:@"guid"] || [lower isEqualToString:@"gpt"]) {
        return @"gpt";
    }
    if ([lower isEqualToString:@"guid partition table"] ||
        [lower containsString:@"guid"] || [lower isEqualToString:@"gpt"]) {
        return @"gpt";
    }
    if ([lower isEqualToString:@"mbr"] || [lower isEqualToString:@"dos"] ||
        [lower isEqualToString:@"msdos"]) {
        return @"mbr";
    }
    if ([lower containsString:@"disklabel"] || [lower isEqualToString:@"bsd"]) {
        return @"bsd";
    }
    return lower;
}

+ (NSString *)displayNameForScheme:(NSString *)scheme
{
    if (scheme == nil) {
        return nil;
    }
    NSString *token = [self normalizeSchemeToken:scheme];
    if ([token isEqual:@"gpt"]) {
        return @"GUID Partition Table";
    }
    if ([token isEqual:@"mbr"]) {
        return @"Master Boot Record";
    }
    if ([token isEqual:@"bsd"]) {
        return @"BSD Disklabel";
    }
    // Unknown scheme: surface the raw string so nothing is silently renamed.
    return [scheme stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (NSString *)filesystemDisplayName:(NSString *)fstype
{
    if (fstype == nil) {
        return @"-";
    }
    NSString *key = [fstype stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([key length] == 0) {
        return @"-";
    }
    NSString *display = sFilesystemTable[[key lowercaseString]];
    return display != nil ? display : key;
}

@end

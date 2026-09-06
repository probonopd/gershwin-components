/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUOpenBSDDisklabelParser.h"

static NSString *Trimmed(NSString *s)
{
    return [s stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL IsDigits(NSString *s)
{
    NSUInteger length = [s length];
    if (length == 0) {
        return NO;
    }
    for (NSUInteger i = 0; i < length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < '0' || c > '9') {
            return NO;
        }
    }
    return YES;
}

// Extracts the leading integer from a "prefix: N" geometry line. Accepts
// both "total sectors: 78165360" and "sectors/unit: 78165360" spellings via
// the prefix argument, with or without the colon after the prefix.
static BOOL NumberAfterPrefix(NSString *line, NSString *prefix,
                              long long *outValue)
{
    if (![[line lowercaseString] hasPrefix:[prefix lowercaseString]]) {
        return NO;
    }
    NSString *rest = Trimmed([line substringFromIndex:[prefix length]]);
    if ([rest hasPrefix:@":"]) {
        rest = Trimmed([rest substringFromIndex:1]);
    }

    // Only the leading numeric run counts; anything non-blank behind it
    // means we misidentified the line rather than that the value is wrong.
    NSUInteger end = 0;
    NSUInteger length = [rest length];
    while (end < length &&
           [[NSCharacterSet decimalDigitCharacterSet]
               characterIsMember:[rest characterAtIndex:end]]) {
        end++;
    }
    if (end == 0) {
        return NO;
    }
    if (end < length) {
        NSString *tail = Trimmed([rest substringFromIndex:end]);
        if ([tail length] > 0 && ![tail hasPrefix:@"#"]) {
            return NO;
        }
    }
    *outValue = [[rest substringToIndex:end] longLongValue];
    return YES;
}

// Matches "<N> partitions:" table markers ("16 partitions:", "8 partitions:").
static BOOL IsPartitionTableMarker(NSString *line)
{
    NSArray<NSString *> *tokens = [line componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
    return [tokens count] >= 2 && IsDigits(tokens[0]) &&
           [tokens[1] isEqualToString:@"partitions:"];
}

// Parses one row like:
//   a: 2104515 64 4.2BSD 2048 16384 1 # /
// Fields are [letter]: size offset fstype [bracket group] # mountpoint.
// Bracket groups ([fsize bsize cpg], [fsize bsize cpg/sgs]) are skipped.
// Rows that do not start "<letter>:" are ignored.
static void ParsePartitionRow(NSString *line,
                              long long sectorSize,
                              NSMutableArray<NSDictionary<NSString *, id> *>
                                  *partitions)
{
    NSUInteger length = [line length];
    if (length < 3 || [line characterAtIndex:1] != ':') {
        return;
    }
    unichar letter = [line characterAtIndex:0];
    if (letter < 'a' || letter > 'p') {
        return;
    }

    NSArray<NSString *> *tokens = [line componentsSeparatedByCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray<NSString *> *fields =
        [NSMutableArray arrayWithCapacity:[tokens count]];
    for (NSString *t in tokens) {
        if ([t length] > 0) {
            [fields addObject:t];
        }
    }
    // fields[0] is "a:", then size, offset, fstype at minimum.
    if ([fields count] < 4) {
        return;
    }
    if (!IsDigits(fields[1]) || !IsDigits(fields[2])) {
        return;
    }

    long long sizeSectors = [fields[1] longLongValue];
    long long offsetSectors = [fields[2] longLongValue];

    NSMutableDictionary<NSString *, id> *partition =
        [NSMutableDictionary dictionary];
    partition[kDisklabelKeyLetter] =
        [[NSString stringWithFormat:@"%C", letter] copy];
    partition[kDisklabelKeySizeBytes] = @(sizeSectors * sectorSize);
    partition[kDisklabelKeyOffsetBytes] = @(offsetSectors * sectorSize);
    partition[kDisklabelKeyFstype] = fields[3];

    // The mount point rides in a trailing comment: "... # /usr". Everything
    // up to the '#' (bracket groups, cylinder notes) is display noise.
    NSRange hash = [line rangeOfString:@"#"];
    if (hash.location != NSNotFound) {
        NSString *mountPoint = Trimmed([line substringFromIndex:
            hash.location + 1]);
        if ([mountPoint length] > 0) {
            partition[kDisklabelKeyMountPoint] = mountPoint;
        }
    }

    [partitions addObject:partition];
}

@implementation DUOpenBSDDisklabelParser

+ (NSDictionary<NSString *, id> *)parseDisklabelOutput:(NSString *)output
{
    if ([output length] == 0) {
        return nil;
    }

    NSCharacterSet *newlines = [NSCharacterSet newlineCharacterSet];
    NSArray<NSString *> *lines =
        [output componentsSeparatedByCharactersInSet:newlines];

    long long sectorSize = 512;
    long long totalSectors = -1;
    BOOL haveTotal = NO;
    BOOL inTable = NO;
    NSMutableArray<NSDictionary<NSString *, id> *> *partitions =
        [NSMutableArray array];

    for (NSString *rawLine in lines) {
        NSString *line = Trimmed(rawLine);
        if ([line length] == 0) {
            continue;
        }

        // Geometry lines only appear before the table marker; once inside
        // the table, rows and comments are all there is.
        if (!inTable) {
            long long value;
            if (NumberAfterPrefix(line, @"bytes/sector", &value)) {
                sectorSize = value;
                continue;
            }
            if (NumberAfterPrefix(line, @"total sectors", &value) ||
                NumberAfterPrefix(line, @"sectors/unit", &value)) {
                totalSectors = value;
                haveTotal = YES;
                continue;
            }
            if (IsPartitionTableMarker(line)) {
                inTable = YES;
            }
            continue;
        }

        if (![line hasPrefix:@"#"]) {
            ParsePartitionRow(line, sectorSize, partitions);
        }
    }

    if (!inTable) {
        return nil;
    }

    NSMutableDictionary<NSString *, id> *result =
        [NSMutableDictionary dictionary];
    result[kDisklabelKeySectorSize] = @(sectorSize);
    if (haveTotal) {
        result[kDisklabelKeyTotalSectors] = @(totalSectors);
    }
    result[kDisklabelKeyPartitions] = [NSArray arrayWithArray:partitions];
    return [NSDictionary dictionaryWithDictionary:result];
}

@end

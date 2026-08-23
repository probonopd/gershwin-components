/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DULsblkParser.h"
#import "DUParsing.h"

NSString * const kLsblkKeyName = @"name";
NSString * const kLsblkKeyParentName = @"parentName";
NSString * const kLsblkKeyPath = @"path";
NSString * const kLsblkKeyType = @"type";
NSString * const kLsblkKeySizeBytes = @"sizeBytes";
NSString * const kLsblkKeyFstype = @"fstype";
NSString * const kLsblkKeyMountPoint = @"mountPoint";
NSString * const kLsblkKeyLabel = @"label";
NSString * const kLsblkKeyPartUUID = @"partUUID";
NSString * const kLsblkKeyUUID = @"uuid";
NSString * const kLsblkKeyModel = @"model";
NSString * const kLsblkKeyReadOnly = @"readOnly";
NSString * const kLsblkKeyRemovable = @"removable";
NSString * const kLsblkKeyHotplug = @"hotplug";
NSString * const kLsblkKeyMajorMinor = @"majorMinor";

// lsblk -P encodes characters that would break the pair format (spaces,
// quotes, non-printables) as \xHH byte escapes, so values are reassembled at
// the byte level and only decoded to a string once complete.
static void AppendUtf8Bytes(NSMutableData *data, unichar ch)
{
    uint8_t buf[4];
    unsigned int len = 0;
    if (ch < 0x80) {
        buf[len++] = (uint8_t)ch;
    } else if (ch < 0x800) {
        buf[len++] = (uint8_t)(0xC0 | (ch >> 6));
        buf[len++] = (uint8_t)(0x80 | (ch & 0x3F));
    } else {
        buf[len++] = (uint8_t)(0xE0 | (ch >> 12));
        buf[len++] = (uint8_t)(0x80 | ((ch >> 6) & 0x3F));
        buf[len++] = (uint8_t)(0x80 | (ch & 0x3F));
    }
    [data appendBytes:buf length:len];
}

static int HexDigitValue(unichar ch)
{
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return 10 + (ch - 'a');
    if (ch >= 'A' && ch <= 'F') return 10 + (ch - 'A');
    return -1;
}

// Appends the UTF-8 bytes of the value starting at 'start' up to len,
// resolving \xHH escape sequences.
static NSData *DecodedValueData(NSString *line, NSUInteger start, NSUInteger end)
{
    NSMutableData *data = [NSMutableData data];
    NSUInteger i = start;
    while (i < end) {
        unichar ch = [line characterAtIndex:i];
        if (ch == '\\' && i + 1 < end) {
            unichar next = [line characterAtIndex:i + 1];
            if ((next == 'x' || next == 'X') && i + 3 < end) {
                int hi = HexDigitValue([line characterAtIndex:i + 2]);
                int lo = HexDigitValue([line characterAtIndex:i + 3]);
                if (hi >= 0 && lo >= 0) {
                    uint8_t byte = (uint8_t)((hi << 4) | lo);
                    [data appendBytes:&byte length:1];
                    i += 4;
                    continue;
                }
            }
            // Unknown escape: keep the escaped character itself.
            AppendUtf8Bytes(data, next);
            i += 2;
            continue;
        }
        AppendUtf8Bytes(data, ch);
        i++;
    }
    return data;
}

static NSString *StringFromValueData(NSData *data)
{
    NSString *value = [[NSString alloc] initWithData:data
                                            encoding:NSUTF8StringEncoding];
    if (value == nil) {
        // Model strings occasionally carry vendor junk; Latin-1 never fails
        // and keeps every byte visible instead of dropping the whole value.
        value = [[NSString alloc] initWithData:data
                                      encoding:NSISOLatin1StringEncoding];
    }
    return value;
}

@implementation DULsblkParser

+ (NSArray<NSDictionary<NSString *, id> *> *)parsePairsOutput:(NSString *)output
{
    if ([output length] == 0) {
        return @[];
    }

    // Raw lsblk column -> result key. Unknown columns are ignored on purpose:
    // newer lsblk versions may add columns without breaking consumers here.
    static NSDictionary<NSString *, NSString *> *columnMap = nil;
    if (columnMap == nil) {
        columnMap = @{
            @"NAME":      kLsblkKeyName,
            @"PKNAME":    kLsblkKeyParentName,
            @"PATH":      kLsblkKeyPath,
            @"TYPE":      kLsblkKeyType,
            @"SIZE":      kLsblkKeySizeBytes,
            @"FSTYPE":    kLsblkKeyFstype,
            @"MOUNTPOINT": kLsblkKeyMountPoint,
            @"LABEL":     kLsblkKeyLabel,
            @"PARTUUID":  kLsblkKeyPartUUID,
            @"UUID":      kLsblkKeyUUID,
            @"MODEL":     kLsblkKeyModel,
            @"RO":        kLsblkKeyReadOnly,
            @"RM":        kLsblkKeyRemovable,
            @"HOTPLUG":   kLsblkKeyHotplug,
            @"MAJ:MIN":   kLsblkKeyMajorMinor,
        };
    }

    NSCharacterSet *newlines = [NSCharacterSet newlineCharacterSet];
    NSArray<NSString *> *lines =
        [output componentsSeparatedByCharactersInSet:newlines];
    NSMutableArray<NSDictionary<NSString *, id> *> *devices =
        [NSMutableArray array];

    for (NSString *line in lines) {
        NSMutableDictionary<NSString *, id> *device =
            [NSMutableDictionary dictionary];
        NSUInteger length = [line length];
        NSUInteger i = 0;

        while (i < length) {
            unichar c = [line characterAtIndex:i];
            if (c == ' ' || c == '\t') {
                i++;
                continue;
            }

            NSUInteger keyStart = i;
            while (i < length && [line characterAtIndex:i] != '=' &&
                   [line characterAtIndex:i] != ' ') {
                i++;
            }
            NSUInteger keyEnd = i;
            if (keyEnd == keyStart || i >= length ||
                [line characterAtIndex:i] != '=') {
                // Stray token without '='; skip past it to stay in sync.
                while (i < length && [line characterAtIndex:i] != ' ') {
                    i++;
                }
                continue;
            }

            i++; // past '='
            NSUInteger valueStart;
            NSUInteger valueEnd;
            BOOL quoted = (i < length && [line characterAtIndex:i] == '"');
            if (quoted) {
                i++;
                valueStart = i;
                // A literal '"' cannot terminate the value because lsblk
                // encodes it as \x22; scan to the closing quote.
                while (i < length && [line characterAtIndex:i] != '"') {
                    i++;
                }
                valueEnd = i;
                if (i < length) {
                    i++; // closing quote
                }
            } else {
                valueStart = i;
                while (i < length && [line characterAtIndex:i] != ' ' &&
                       [line characterAtIndex:i] != '\t') {
                    i++;
                }
                valueEnd = i;
            }

            NSString *key = [line substringWithRange:
                NSMakeRange(keyStart, keyEnd - keyStart)];
            NSString *resultKey = columnMap[key];
            if (resultKey == nil) {
                continue;
            }
            NSString *value = StringFromValueData(
                DecodedValueData(line, valueStart, valueEnd));
            if ([value length] == 0) {
                continue; // absent key for empty lsblk columns
            }

            if ([resultKey isEqualToString:kLsblkKeySizeBytes]) {
                NSNumber *bytes = [DUParsing parseSizeString:value];
                if (bytes == nil) {
                    continue;
                }
                device[resultKey] = bytes;
            } else if ([resultKey isEqualToString:kLsblkKeyReadOnly] ||
                       [resultKey isEqualToString:kLsblkKeyRemovable] ||
                       [resultKey isEqualToString:kLsblkKeyHotplug]) {
                device[resultKey] = @([value intValue] != 0);
            } else {
                device[resultKey] = value;
            }
        }

        if ([device count] > 0) {
            [devices addObject:[NSDictionary dictionaryWithDictionary:device]];
        }
    }

    return [NSArray arrayWithArray:devices];
}

@end

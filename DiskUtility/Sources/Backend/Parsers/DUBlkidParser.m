/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUBlkidParser.h"

NSString * const kBkidKeyDevice = @"device";
NSString * const kBkidKeyUuid = @"uuid";
NSString * const kBkidKeyType = @"type";
NSString * const kBkidKeyLabel = @"label";
NSString * const kBkidKeyPartUuid = @"partUuid";
NSString * const kBkidKeyPartLabel = @"partLabel";
NSString * const kBkidKeyPartEntryNumber = @"partEntryNumber";

// blkid escapes bytes that would break the quoted format as \xHH, so values
// are reassembled at the byte level before being turned into a string.
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

static NSString *DecodedValue(NSString *line, NSUInteger start, NSUInteger end)
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
            AppendUtf8Bytes(data, next);
            i += 2;
            continue;
        }
        AppendUtf8Bytes(data, ch);
        i++;
    }

    NSString *value = [[NSString alloc] initWithData:data
                                            encoding:NSUTF8StringEncoding];
    if (value == nil) {
        value = [[NSString alloc] initWithData:data
                                      encoding:NSISOLatin1StringEncoding];
    }
    return value;
}

// PART_ENTRY_NUMBER -> "partEntryNumber": first word lowercased, following
// words capitalized and joined. Keeps pass-through tokens predictable.
static NSString *NormalizedTokenKey(NSString *token)
{
    NSArray<NSString *> *words =
        [token componentsSeparatedByString:@"_"];
    NSMutableString *key = [NSMutableString string];
    for (NSUInteger w = 0; w < [words count]; w++) {
        NSString *word = words[w];
        if ([word length] == 0) {
            continue;
        }
        NSString *lower = [word lowercaseString];
        if (w == 0) {
            [key appendString:lower];
        } else {
            NSString *capitalized =
                [[lower substringToIndex:1] uppercaseString];
            if ([lower length] > 1) {
                capitalized = [capitalized stringByAppendingString:
                    [lower substringFromIndex:1]];
            }
            [key appendString:capitalized];
        }
    }
    return key;
}

@implementation DUBlkidParser

+ (NSArray<NSDictionary<NSString *, id> *> *)parseFullOutput:(NSString *)output
{
    if ([output length] == 0) {
        return @[];
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

        // "classic" form puts the device path in front of the first colon;
        // udev-style lines carry it as a DEVICE= token instead.
        NSRange colonRange = [line rangeOfString:@":"];

        NSUInteger i = 0;
        if (colonRange.location != NSNotFound && colonRange.location > 0 &&
            [line hasPrefix:@"/"]) {
            NSString *dev = [[line substringToIndex:colonRange.location]
                stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
            if ([dev length] > 0) {
                device[kBkidKeyDevice] = dev;
            }
            i = colonRange.location + 1;
        }

        BOOL sawPair = NO;
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
                while (i < length && [line characterAtIndex:i] != ' ') {
                    i++;
                }
                continue;
            }

            i++; // past '='
            NSUInteger valueStart;
            NSUInteger valueEnd;
            if (i < length && [line characterAtIndex:i] == '"') {
                i++;
                valueStart = i;
                while (i < length && [line characterAtIndex:i] != '"') {
                    i++;
                }
                valueEnd = i;
                if (i < length) {
                    i++;
                }
            } else {
                valueStart = i;
                while (i < length && [line characterAtIndex:i] != ' ' &&
                       [line characterAtIndex:i] != '\t') {
                    i++;
                }
                valueEnd = i;
            }

            NSString *token = [line substringWithRange:
                NSMakeRange(keyStart, keyEnd - keyStart)];
            NSString *value = DecodedValue(line, valueStart, valueEnd);
            if ([value length] == 0) {
                continue;
            }
            sawPair = YES;

            // DEVICE= is the udev-style spelling of the path prefix.
            NSString *resultKey;
            if ([token isEqualToString:@"DEVICE"]) {
                resultKey = kBkidKeyDevice;
            } else if ([token isEqualToString:@"UUID"]) {
                resultKey = kBkidKeyUuid;
            } else if ([token isEqualToString:@"TYPE"]) {
                resultKey = kBkidKeyType;
            } else if ([token isEqualToString:@"LABEL"]) {
                resultKey = kBkidKeyLabel;
            } else if ([token isEqualToString:@"PARTUUID"]) {
                resultKey = kBkidKeyPartUuid;
            } else if ([token isEqualToString:@"PARTLABEL"]) {
                resultKey = kBkidKeyPartLabel;
            } else if ([token isEqualToString:@"PART_ENTRY_NUMBER"]) {
                resultKey = kBkidKeyPartEntryNumber;
            } else {
                resultKey = NormalizedTokenKey(token);
            }
            device[resultKey] = value;
        }

        if (sawPair || [device count] > 0) {
            [devices addObject:[NSDictionary dictionaryWithDictionary:device]];
        }
    }

    return [NSArray arrayWithArray:devices];
}

@end

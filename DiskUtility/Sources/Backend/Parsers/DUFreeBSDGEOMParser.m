/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUFreeBSDGEOMParser.h"

static NSString *Trimmed(NSString *s)
{
    return [s stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// "Geom name" -> "geomname", "Mediasize" -> "mediasize". Inner spaces are
// removed so multi-word attributes still yield a single stable key.
static NSString *NormalizedAttrKey(NSString *raw)
{
    NSMutableString *key = [Trimmed(raw) mutableCopy];
    [key replaceOccurrencesOfString:@" "
                          withString:@""
                             options:NSLiteralSearch
                               range:NSMakeRange(0, [key length])];
    if ([key length] > 0) {
        unichar first = [key characterAtIndex:0];
        if (first >= 'A' && first <= 'Z') {
            [key replaceCharactersInRange:NSMakeRange(0, 1)
                               withString:[[key substringToIndex:1]
                                   lowercaseString]];
        }
    }
    return key;
}

// Splits "Attr: value" and stores it; the value keeps everything after the
// FIRST colon (values such as efimedia contain further colons).
// Returns YES when a usable attribute was stored.
static BOOL StoreAttr(NSMutableDictionary *dict, NSString *attrLine)
{
    NSRange colon = [attrLine rangeOfString:@":"];
    if (colon.location == NSNotFound || colon.location == 0) {
        return NO;
    }
    NSString *key = NormalizedAttrKey([attrLine substringToIndex:
        colon.location]);
    NSString *value = Trimmed([attrLine substringFromIndex:
        colon.location + 1]);
    if ([key length] == 0 || [value length] == 0) {
        return NO;
    }
    dict[key] = value;
    return YES;
}

// Matches numbered provider/consumer lines like "1. Name: ada0p1".
static BOOL IsNumberedBlockLine(NSString *line, NSUInteger *attrStart)
{
    NSUInteger i = 0;
    NSUInteger length = [line length];
    while (i < length && [line characterAtIndex:i] >= '0' &&
           [line characterAtIndex:i] <= '9') {
        i++;
    }
    if (i == 0 || i + 1 >= length || [line characterAtIndex:i] != '.' ||
        [line characterAtIndex:i + 1] != ' ') {
        return NO;
    }
    *attrStart = i + 2;
    return YES;
}

@implementation DUFreeBSDGEOMParser

+ (NSArray<NSDictionary<NSString *, id> *> *)parseListOutput:(NSString *)output
{
    if ([output length] == 0) {
        return @[];
    }

    NSCharacterSet *newlines = [NSCharacterSet newlineCharacterSet];
    NSArray<NSString *> *lines =
        [output componentsSeparatedByCharactersInSet:newlines];
    NSMutableArray<NSDictionary<NSString *, id> *> *providers =
        [NSMutableArray array];

    NSMutableDictionary<NSString *, NSString *> *geomAttrs =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *current = nil;
    BOOL inConsumers = NO;

    for (NSString *rawLine in lines) {
        NSString *line = Trimmed(rawLine);
        if ([line length] == 0) {
            // Blank line ends the current provider block.
            current = nil;
            continue;
        }

        NSString *lower = [line lowercaseString];
        if ([lower isEqualToString:@"providers:"] ||
            [lower isEqualToString:@"geoms:"]) {
            inConsumers = NO;
            current = nil;
            continue;
        }
        if ([lower isEqualToString:@"consumers:"]) {
            inConsumers = YES;
            current = nil;
            continue;
        }

        NSUInteger attrStart = 0;
        if (IsNumberedBlockLine(line, &attrStart)) {
            if (inConsumers) {
                continue; // consumer blocks are not part of the output
            }
            // A new provider inherits the enclosing geom's header attributes.
            current = [geomAttrs mutableCopy];
            [providers addObject:current];
            StoreAttr(current, [line substringFromIndex:attrStart]);
            continue;
        }

        if ([lower hasPrefix:@"geom name:"]) {
            // New geom context in `geom disk list` listings.
            [geomAttrs removeAllObjects];
            StoreAttr(geomAttrs, line);
            current = nil;
            continue;
        }

        if (inConsumers) {
            continue;
        }
        if (current != nil) {
            StoreAttr(current, line);
        } else {
            StoreAttr(geomAttrs, line);
        }
    }

    return [NSArray arrayWithArray:providers];
}

@end

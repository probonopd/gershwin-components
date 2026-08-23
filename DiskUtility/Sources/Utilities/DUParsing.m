/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUParsing.h"

#import <stdlib.h>

@implementation DUParsing

+ (NSNumber *)parseSizeString:(NSString *)token
{
    if (token.length == 0) {
        return nil;
    }
    NSString *trimmed = [self trimmedString:token];
    if (trimmed.length == 0 || [trimmed isEqualToString:@"-"]) {
        return nil;
    }

    // Built per call; trivially cheap and avoids any threading dependency.
    unsigned long long k = 1024ull;
    NSDictionary<NSString *, NSNumber *> *multipliers = @{
        @"b"  : @(1ull),
        @"k"  : @(k),
        @"m"  : @(k * k),
        @"g"  : @(k * k * k),
        @"t"  : @(k * k * k * k),
        @"p"  : @(k * k * k * k * k),
        @"ki" : @(1000ull),
        @"mi" : @(1000000ull),
        @"gi" : @(1000000000ull),
    };

    // Split numeric prefix from unit suffix; tools emit forms like "500G"
    // or plain sector/byte counts.
    NSUInteger i = 0;
    BOOL sawDigit = NO, sawDot = NO;
    while (i < trimmed.length) {
        unichar c = [trimmed characterAtIndex:i];
        if (c >= '0' && c <= '9') {
            sawDigit = YES;
        } else if (c == '.' && !sawDot) {
            sawDot = YES;
        } else {
            break;
        }
        i++;
    }
    if (!sawDigit) {
        return nil;
    }

    double value = [trimmed substringToIndex:i].doubleValue;
    NSString *suffix = [[trimmed substringFromIndex:i]
        stringByReplacingOccurrencesOfString:@" " withString:@""];
    suffix = suffix.lowercaseString;

    unsigned long long multiplier = 1;
    if (suffix.length > 0) {
        // Exact matches first ("Ki"/"Gi" style), then single-letter units.
        NSNumber *exact = multipliers[suffix];
        if (exact != nil) {
            multiplier = exact.unsignedLongLongValue;
        } else {
            NSNumber *single = multipliers[[suffix substringToIndex:1]];
            if (single == nil) {
                return nil;
            }
            multiplier = single.unsignedLongLongValue;
        }
    }

    // Round fractional sizes up to whole bytes so capacity checks never
    // under-report available space.
    double scaled = value * (double)multiplier;
    if (scaled >= (double)ULLONG_MAX) {
        return @(ULLONG_MAX);
    }
    return @(ceil(scaled));
}

+ (NSString *)humanReadableSizeFromBytes:(unsigned long long)bytes
{
    static const char *units[] = { "B", "KB", "MB", "GB", "TB", "PB" };
    double value = (double)bytes;
    NSUInteger unit = 0;
    while (value >= 1024.0 && unit < sizeof(units) / sizeof(units[0]) - 1) {
        value /= 1024.0;
        unit++;
    }
    if (unit == 0) {
        return [NSString stringWithFormat:@"%llu %@", bytes,
                       [NSString stringWithUTF8String:units[0]]];
    }
    return [NSString stringWithFormat:@"%.1f %@",
                   value,
                   [NSString stringWithUTF8String:units[unit]]];
}

+ (unsigned long long)unsignedLongLongFromString:(NSString *)text
{
    if (text == nil) {
        return 0;
    }
    // strtoull with explicit base 10 keeps parsing locale- and
    // Foundation-version-independent (GNUstep NSScanner lacks an
    // unsigned-long-long API on all supported versions).
    return strtoull(text.UTF8String, NULL, 10);
}

+ (BOOL)boolFromToken:(NSString *)token
{
    NSString *value = [self trimmedString:token].lowercaseString;
    NSArray<NSString *> *trueTokens =
        @[ @"1", @"yes", @"true", @"on", @"y", @"enabled" ];
    for (NSString *candidate in trueTokens) {
        if ([value isEqualToString:candidate]) {
            return YES;
        }
    }
    return NO;
}

+ (NSString *)trimmedString:(NSString *)text
{
    if (text == nil) {
        return @"";
    }
    return [text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (BOOL)caseInsensitiveContains:(NSString *)haystack
                          needle:(NSString *)needle
{
    if (haystack.length == 0 || needle.length == 0) {
        return NO;
    }
    return [haystack rangeOfString:needle
                           options:NSCaseInsensitiveSearch].location
           != NSNotFound;
}

@end

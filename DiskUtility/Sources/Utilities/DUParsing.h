/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Shared parsing helpers for locale-independent backend output.
// All functions take raw tool output and never touch the filesystem.

@interface DUParsing : NSObject

// Parses tool size tokens such as "500G", "8M", "1024", "1.5T", "512B"
// into bytes. Returns nil when the token cannot be understood.
+ (NSNumber *)parseSizeString:(NSString *)token;

// Human display string in the SPEC section 22 style, e.g. "149.1 GB".
+ (NSString *)humanReadableSizeFromBytes:(unsigned long long)bytes;

// Locale-independent number parsing (accepts both "." decimal separator
// forms used by tools regardless of user locale).
+ (unsigned long long)unsignedLongLongFromString:(NSString *)text;

// Interprets tool boolean tokens: yes/no, true/false, 1/0, on/off.
+ (BOOL)boolFromToken:(NSString *)token;

// Trims surrounding whitespace; returns @"" for nil input.
+ (NSString *)trimmedString:(NSString *)text;

// Case-insensitive substring test. GNUstep-base lacks
// -localizedCaseInsensitiveContainsString:, so backends use this instead.
+ (BOOL)caseInsensitiveContains:(NSString *)haystack
                          needle:(NSString *)needle;

@end

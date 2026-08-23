/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUNetBKSDisklabelParser.h"
#import "DUOpenBSDDisklabelParser.h"

@implementation DUNetBKSDisklabelParser

+ (NSDictionary<NSString *, id> *)parseDisklabelOutput:(NSString *)output
{
    // NetBSD labels share the OpenBSD grammar; one engine, two front doors.
    return [DUOpenBSDDisklabelParser parseDisklabelOutput:output];
}

@end

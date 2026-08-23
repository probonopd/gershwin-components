/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// Shared fixture loader for the DiskUtility test tools. Fixtures live under
// Tests/Fixtures; the tools are run with the Tests directory as working
// directory (see run.sh). A missing fixture is a broken environment, not a
// test result, so we abort loudly instead of failing individual assertions.
#import <Foundation/Foundation.h>

static inline NSString *TestFixtureNamed(NSString *relativeName)
{
    NSString *path = [@"Fixtures"
        stringByAppendingPathComponent:relativeName];
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];
    if (content == nil) {
        fprintf(stderr,
                "FATAL: cannot read fixture %s: %s\n",
                path.fileSystemRepresentation ?: "(nil)",
                error.localizedDescription.UTF8String ?: "unknown error");
        exit(2);
    }
    return content;
}

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#import <string.h>
#import "AppDelegate.h"

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (getenv("GNUSTEP_SYSTEM_ROOT") == NULL) {
            setenv("GNUSTEP_SYSTEM_ROOT", "/System", 1);
        }
        if (getenv("GNUSTEP_SYSTEM_LIBRARY") == NULL) {
            setenv("GNUSTEP_SYSTEM_LIBRARY", "/System/Library", 1);
        }

        const char *ld = getenv("LD_LIBRARY_PATH");
        if (!ld || strstr(ld, "/System/Library/Libraries") == NULL) {
            NSMutableString *newLd = [NSMutableString stringWithString:@"/System/Library/Libraries"];
            if (ld && strlen(ld) > 0) {
                [newLd appendFormat:@":%s", ld];
            }
            setenv("LD_LIBRARY_PATH", [newLd UTF8String], 1);
        }

        [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [NSApp setDelegate:delegate];
        [NSApp run];
    }
    return 0;
}

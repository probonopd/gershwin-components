/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/NSApplication.h>
#import <Foundation/NSAutoreleasePool.h>
#import "WhisperController.h"

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    [NSApplication sharedApplication];

    WhisperController *controller = [[WhisperController alloc] init];
    [[NSApplication sharedApplication] setDelegate:controller];

    [pool release];

    [[NSApplication sharedApplication] run];
    return 0;
}

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ProcessInfo.h"

@implementation ProcessInfo

@synthesize pid = _pid;
@synthesize name = _name;
@synthesize command = _command;
@synthesize rssBytes = _rssBytes;
@synthesize virtualBytes = _virtualBytes;
@synthesize cpuPercent = _cpuPercent;

- (void)dealloc
{
    [_name release];
    [_command release];
    [super dealloc];
}

@end

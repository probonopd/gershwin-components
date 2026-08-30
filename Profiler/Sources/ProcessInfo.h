/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#include <sys/types.h>

@interface ProcessInfo : NSObject
{
    pid_t _pid;
    NSString *_name;
    NSString *_command;
    unsigned long long _rssBytes;
    unsigned long long _virtualBytes;
    double _cpuPercent;
}

@property (nonatomic, assign) pid_t pid;
@property (nonatomic, strong) NSString *name;
@property (nonatomic, strong) NSString *command;
@property (nonatomic, assign) unsigned long long rssBytes;
@property (nonatomic, assign) unsigned long long virtualBytes;
@property (nonatomic, assign) double cpuPercent;

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ProcessMonitor.h"
#import "ProcessInfo.h"

#if defined(__FreeBSD__) || defined(__FreeBSD_kernel__)
#include <libutil.h>
#include <sys/sysctl.h>
#include <sys/param.h>
#include <sys/proc.h>
#include <sys/user.h>
#define BSD_PROCESS_LIST
#elif defined(__OpenBSD__) || defined(__NetBSD__)
#include <sys/sysctl.h>
#include <sys/param.h>
#include <sys/proc.h>
#include <sys/user.h>
#define BSD_PROCESS_LIST
#endif

@implementation ProcessMonitor

- (NSArray *)processes
{
#ifdef BSD_PROCESS_LIST
    return [self bsdProcessList];
#else
    return [self linuxProcessList];
#endif
}

- (NSArray *)linuxProcessList
{
    NSMutableArray *result = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *entries = [fm contentsOfDirectoryAtPath:@"/proc" error:NULL];

    for (NSString *entry in entries) {
        NSScanner *scanner = [NSScanner scannerWithString:entry];
        int pidValue = 0;
        if (![scanner scanInt:&pidValue] || !scanner.isAtEnd || pidValue <= 0)
            continue;

        NSString *statusPath = [NSString stringWithFormat:@"/proc/%d/status", pidValue];
        NSString *status = [NSString stringWithContentsOfFile:statusPath
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
        if (!status)
            continue;

        NSString *name = nil;
        unsigned long long rss = 0, vm = 0;
        for (NSString *line in [status componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"Name:"])
                name = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
            else if ([line hasPrefix:@"VmRSS:"]) {
                NSScanner *s = [NSScanner scannerWithString:line];
                [s scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:NULL];
                long long kb = 0;
                [s scanLongLong:&kb];
                rss = (unsigned long long)kb * 1024ULL;
            } else if ([line hasPrefix:@"VmSize:"]) {
                NSScanner *s = [NSScanner scannerWithString:line];
                [s scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:NULL];
                long long kb = 0;
                [s scanLongLong:&kb];
                vm = (unsigned long long)kb * 1024ULL;
            }
        }

        if (name == nil)
            continue;
        if ([name hasPrefix:@"["])
            continue;

        ProcessInfo *info = [[ProcessInfo alloc] init];
        info.pid = (pid_t)pidValue;
        info.name = name;
        info.rssBytes = rss;
        info.virtualBytes = vm;
        NSString *cmdline = [NSString stringWithContentsOfFile:
                            [NSString stringWithFormat:@"/proc/%d/cmdline", pidValue]
                            encoding:NSUTF8StringEncoding error:NULL];
        if (cmdline && [cmdline length] > 0) {
            info.command = [cmdline stringByReplacingOccurrencesOfString:@"\0" withString:@" "];
        } else {
            info.command = info.name;
        }
        [result addObject:[info autorelease]];
    }

    return [result sortedArrayUsingComparator:
            ^NSComparisonResult(ProcessInfo *a, ProcessInfo *b) {
        if (a.rssBytes > b.rssBytes) return NSOrderedAscending;
        if (a.rssBytes < b.rssBytes) return NSOrderedDescending;
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
}

#ifdef BSD_PROCESS_LIST
- (NSArray *)bsdProcessList
{
    NSMutableArray *result = [NSMutableArray array];
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PROC, 0 };
    size_t mibSize = sizeof(mib) / sizeof(mib[0]);
    struct kinfo_proc *procs = NULL;
    size_t procSize = 0;

    if (sysctl(mib, mibSize, NULL, &procSize, NULL, 0) != 0)
        return result;

    procs = malloc(procSize);
    if (!procs)
        return result;

    if (sysctl(mib, mibSize, procs, &procSize, NULL, 0) != 0) {
        free(procs);
        return result;
    }

    size_t count = procSize / sizeof(*procs);
    for (size_t i = 0; i < count; i++) {
        struct kinfo_proc *p = &procs[i];
        ProcessInfo *info = [[ProcessInfo alloc] init];
        info.pid = p->ki_pid;
        info.name = [NSString stringWithUTF8String:p->ki_comm];
        info.command = [NSString stringWithUTF8String:p->ki_comm];

        info.rssBytes = (unsigned long long)p->ki_rssize * (unsigned long long)getpagesize();
        info.virtualBytes = (unsigned long long)p->ki_size;

        [result addObject:[info autorelease]];
    }

    free(procs);

    return [result sortedArrayUsingComparator:
            ^NSComparisonResult(ProcessInfo *a, ProcessInfo *b) {
        if (a.rssBytes > b.rssBytes) return NSOrderedAscending;
        if (a.rssBytes < b.rssBytes) return NSOrderedDescending;
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
}
#else
- (NSArray *)bsdProcessList
{
    return [NSArray array];
}
#endif

- (void)refreshProcessList
{
}

- (ProcessInfo *)sampleProcess:(pid_t)pid
{
#ifdef BSD_PROCESS_LIST
    return [self bsdSampleProcess:pid];
#else
    return [self linuxSampleProcess:pid];
#endif
}

- (ProcessInfo *)linuxSampleProcess:(pid_t)pid
{
    NSString *statusPath = [NSString stringWithFormat:@"/proc/%d/status", pid];
    NSString *status = [NSString stringWithContentsOfFile:statusPath
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
    if (!status) return nil;

    ProcessInfo *info = [[ProcessInfo alloc] init];
    info.pid = pid;

    for (NSString *line in [status componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"Name:"])
            info.name = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
        else if ([line hasPrefix:@"VmRSS:"]) {
            NSScanner *s = [NSScanner scannerWithString:line];
            [s scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:NULL];
            long long kb = 0;
            [s scanLongLong:&kb];
            info.rssBytes = (unsigned long long)kb * 1024ULL;
        } else if ([line hasPrefix:@"VmSize:"]) {
            NSScanner *s = [NSScanner scannerWithString:line];
            [s scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:NULL];
            long long kb = 0;
            [s scanLongLong:&kb];
            info.virtualBytes = (unsigned long long)kb * 1024ULL;
        }
    }
    return [info autorelease];
}

#ifdef BSD_PROCESS_LIST
- (ProcessInfo *)bsdSampleProcess:(pid_t)pid
{
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    size_t mibSize = sizeof(mib) / sizeof(mib[0]);
    struct kinfo_proc *p = NULL;
    size_t procSize = 0;

    if (sysctl(mib, mibSize, NULL, &procSize, NULL, 0) != 0)
        return nil;

    p = malloc(procSize);
    if (!p)
        return nil;

    if (sysctl(mib, mibSize, p, &procSize, NULL, 0) != 0) {
        free(p);
        return nil;
    }

    ProcessInfo *info = [[ProcessInfo alloc] init];
    info.pid = p->ki_pid;
    info.name = [NSString stringWithUTF8String:p->ki_comm];
    info.command = [NSString stringWithUTF8String:p->ki_comm];
    info.rssBytes = (unsigned long long)p->ki_rssize * (unsigned long long)getpagesize();
    info.virtualBytes = (unsigned long long)p->ki_size;

    free(p);
    return [info autorelease];
}
#else
- (ProcessInfo *)bsdSampleProcess:(pid_t)pid
{
    (void)pid;
    return nil;
}
#endif

@end

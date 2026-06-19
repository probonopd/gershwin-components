/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ProcessesController.h"
#import <dirent.h>
#import <pwd.h>
#import <sys/stat.h>
#include <stdint.h>
#ifndef __linux__
#import <sys/sysctl.h>
#ifdef __FreeBSD__
#import <sys/user.h>
#endif
#endif
#import <unistd.h>
#import <errno.h>
#import <sys/wait.h>
#import <string.h>

// Simple logging macro for this module
// Logging macros: PC_INFO is always enabled; PC_DBG is enabled only when PROCESSES_DEBUG is set to 1
#ifndef PROCESSES_DEBUG
#define PROCESSES_DEBUG 0
#endif

#ifndef PC_INFO
#define PC_INFO(fmt, ...) NSDebugLLog(@"gwcomp", (@"[Processes] " fmt), ##__VA_ARGS__)
#endif

#ifndef PC_DBG
#if PROCESSES_DEBUG
#define PC_DBG(fmt, ...) NSDebugLLog(@"gwcomp", (@"[Processes] " fmt), ##__VA_ARGS__)
#else
#define PC_DBG(fmt, ...) ((void)0)
#endif
#endif

// NSTableView subclass that draws full-row alternating backgrounds (no per-cell gaps)
@interface ProcessTableView : NSTableView
@end

@implementation ProcessTableView

- (void)drawRow:(NSInteger)row clipRect:(NSRect)clipRect
{
    NSRect rowRect = [self rectOfRow:row];

    if ([self isRowSelected:row]) {
        [[NSColor selectedControlColor] setFill];
    } else if (row % 2 == 0) {
        [[NSColor controlBackgroundColor] setFill];
    } else {
        [[NSColor colorWithCalibratedWhite:0.93 alpha:1.0] setFill];
    }
    NSRectFill(rowRect);

    [super drawRow:row clipRect:clipRect];
}

@end

// Helper function to get total system memory in KB
static long getTotalSystemMemoryKB(void) {
    long totalMemory = 0;
    
#ifdef __linux__
    // Linux: Read from /proc/meminfo
    FILE *memFile = fopen("/proc/meminfo", "r");
    if (memFile) {
        char line[256];
        while (fgets(line, sizeof(line), memFile)) {
            if (strncmp(line, "MemTotal:", 9) == 0) {
                sscanf(line, "MemTotal: %ld", &totalMemory);
                break;
            }
        }
        fclose(memFile);
    }
#else
    // BSD and other Unix-like systems: prefer sysctlbyname for portability
    uint64_t memsize = 0;
    size_t len = sizeof(memsize);
#if defined(__OpenBSD__)
    // OpenBSD has no sysctlbyname(); read physical memory via the numeric mib.
#ifdef HW_PHYSMEM64
    int mib[2] = {CTL_HW, HW_PHYSMEM64};
    len = sizeof(memsize);
    if (sysctl(mib, 2, &memsize, &len, NULL, 0) == 0) {
        totalMemory = (long)(memsize / 1024);
    }
#endif
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__NetBSD__) || defined(__DragonFly__)
    // Try several common sysctl names across BSDs/macOS
    const char *names[] = { "hw.memsize", "hw.physmem", "hw.realmem", "hw.physmem64", NULL };
    const char **n;
    for (n = names; *n != NULL; n++) {
        len = sizeof(memsize);
        if (sysctlbyname(*n, &memsize, &len, NULL, 0) == 0 && len > 0) {
            totalMemory = (long)(memsize / 1024);
            break;
        }
    }
    if (totalMemory == 0) {
#ifdef HW_MEMSIZE
        int mib[2] = {CTL_HW, HW_MEMSIZE};
        len = sizeof(memsize);
        if (sysctl(mib, 2, &memsize, &len, NULL, 0) == 0) {
            totalMemory = (long)(memsize / 1024);
        }
#endif
    }
#else
#ifdef HW_MEMSIZE
    int mib[2] = {CTL_HW, HW_MEMSIZE};
    unsigned long memsize_ul = 0;
    size_t len_ul = sizeof(memsize_ul);
    if (sysctl(mib, 2, &memsize_ul, &len_ul, NULL, 0) == 0) {
        totalMemory = memsize_ul / 1024;
    }
#endif
#endif
#endif
    
    return totalMemory;
}



@implementation ProcessesController

@synthesize processes = _processes;

static ProcessesController *sharedController = nil;

+ (ProcessesController *)sharedController
{
    if (!sharedController) {
        sharedController = [[ProcessesController alloc] init];
    }
    return sharedController;
}

- (id)init
{
    self = [super init];
    if (self) {
        _processes = [[NSMutableArray alloc] init];
        _processesLock = [[NSLock alloc] init];
        _refreshInterval = 5.0; // Refresh every 5 seconds
        _prevCpuTimes = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    // Cleanup not involving object releases (ARC handles memory)
    [self stopMonitoring];
    // Other cleanup if necessary
}

- (void)awakeFromNib
{
    // Not using nib
}

- (void)startMonitoring
{
    if (!_refreshTimer) {
        _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:_refreshInterval
                                                          target:self
                                                        selector:@selector(refreshProcesses)
                                                        userInfo:nil
                                                         repeats:YES];
    }
}

- (void)stopMonitoring
{
    if (_refreshTimer) {
        [_refreshTimer invalidate];
        _refreshTimer = nil;
    }
}

- (BOOL)isRefreshing
{
    return _isRefreshing;
}

- (void)refreshProcesses
{
    // Don't re-enter a refresh if one is already running
    if (_isRefreshing) {
        return;
    }
    _isRefreshing = YES;
    PC_INFO(@"refreshProcesses entered");

    // Snapshot previous CPU times safely
    NSMutableDictionary *prevCpuSnapshot = nil;
    [_processesLock lock];
    prevCpuSnapshot = [NSMutableDictionary dictionaryWithDictionary:_prevCpuTimes];
    [_processesLock unlock];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        PC_DBG(@"background worker started");
        PC_DBG(@"background refresh starting");
        NSMutableArray *newProcesses = [[NSMutableArray alloc] init];
        NSMutableDictionary *updatedCpuTimes = [NSMutableDictionary dictionaryWithDictionary:prevCpuSnapshot];

        // Get system info for calculations
        long totalMemory = getTotalSystemMemoryKB();
        PC_DBG(@"totalMemoryKB=%ld", totalMemory);

        DIR *procDir = opendir("/proc");
        if (procDir) {
            PC_DBG(@"Using /proc for enumeration");
            struct dirent *entry;
            int procDirEntries = 0;
            int procAdded = 0;
#if !PROCESSES_DEBUG
            (void)procDirEntries; (void)procAdded;
#endif
            NSTimeInterval startTime = [[NSDate date] timeIntervalSince1970];
            double maxDuration = 3.0; // seconds
            while ((entry = readdir(procDir)) != NULL) {
                procDirEntries++;
                // Stop if we've been running for too long to avoid pegging CPU
                if (([[NSDate date] timeIntervalSince1970] - startTime) > maxDuration) {
                    break;
                }
                // Check if entry is a number (PID)
                char *endptr;
                int pid = (int)strtol(entry->d_name, &endptr, 10);
                if (*endptr == '\0' && pid > 0) {
                    // Read /proc/pid/stat
                    char statPath[256];
                    snprintf(statPath, sizeof(statPath), "/proc/%d/stat", pid);

                    FILE *statFile = fopen(statPath, "r");
                    if (statFile) {
                        char statLine[1024];
                        if (fgets(statLine, sizeof(statLine), statFile)) {
                            ProcessInfo *info = [[ProcessInfo alloc] init];
                            info.pid = pid;

                            // Parse stat line: pid (comm) state ppid ... uid vsize rss ...
                            char comm[256];

                            // Simplified parsing - find the fields we need
                            int parsedPid, parsedPpid;
                            unsigned long parsedVsize, parsedRss;
                            char parsedState;
                            sscanf(statLine, "%d (%[^)]) %c %d %*d %*d %*d %*d %*u %*u %*u %*u %*u %*d %*d %*d %*d %*d %*d %*u %*u %*d %*u %lu %lu", 
                                   &parsedPid, comm, &parsedState, &parsedPpid, &parsedVsize, &parsedRss);

                            info.pid = parsedPid;
                            info.ppid = parsedPpid;
                            info.state = [NSString stringWithFormat:@"%c", parsedState];
                            // Parse fields after the closing parenthesis in /proc/[pid]/stat
                            char *rparen = strrchr(statLine, ')');
                            unsigned long utime = 0, stime = 0;
                            unsigned long parsedVsizeUL = 0;
                            long parsedRssLong = 0;
                            int parsedPpidLocal = 0;
                            if (rparen) {
                                char *rest = rparen + 2; // skip ") "
                                int field = 1;
                                char *saveptr = NULL;
                                char *token = strtok_r(rest, " ", &saveptr);
                                while (token) {
                                    if (field == 1) {
                                        // state
                                    } else if (field == 2) {
                                        parsedPpidLocal = atoi(token);
                                    } else if (field == 12) {
                                        utime = strtoul(token, NULL, 10);
                                    } else if (field == 13) {
                                        stime = strtoul(token, NULL, 10);
                                    } else if (field == 21) {
                                        parsedVsizeUL = strtoul(token, NULL, 10);
                                    } else if (field == 22) {
                                        parsedRssLong = atol(token);
                                        break; // we have what we need
                                    }
                                    token = strtok_r(NULL, " ", &saveptr);
                                    field++;
                                }
                            }

                            info.pid = parsedPid;
                            info.ppid = parsedPpidLocal ? parsedPpidLocal : parsedPpid;
                            info.state = [NSString stringWithFormat:@"%c", parsedState];
                            long pageSize = sysconf(_SC_PAGESIZE);
                            info.virtualMemory = parsedVsizeUL / 1024; // KB
                            info.residentMemory = (parsedRssLong * pageSize) / 1024; // convert pages -> KB

                            // Read command line
                            char cmdPath[256];
                            snprintf(cmdPath, sizeof(cmdPath), "/proc/%d/cmdline", pid);
                            FILE *cmdFile = fopen(cmdPath, "r");
                            if (cmdFile) {
                                char cmdLine[1024];
                                size_t len = fread(cmdLine, 1, sizeof(cmdLine) - 1, cmdFile);
                                if (len > 0) {
                                    cmdLine[len] = '\0';
                                    // Replace null bytes with spaces
                                    for (size_t i = 0; i < len; i++) {
                                        if (cmdLine[i] == '\0') cmdLine[i] = ' ';
                                    }
                                    info.command = [NSString stringWithUTF8String:cmdLine];
                                }
                                fclose(cmdFile);
                            }

                            if (!info.command || [info.command length] == 0) {
                                info.command = [NSString stringWithUTF8String:comm];
                            }

                            // Compute CPU% using previous samples
                            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                            unsigned long totalTicks = utime + stime;
                            NSString *pidKey = [NSString stringWithFormat:@"%d", info.pid];
                            NSDictionary *prev = [prevCpuSnapshot objectForKey:pidKey];
                            float cpuPercent = 0.0;
                            long ticksPerSec = sysconf(_SC_CLK_TCK);
                            if (prev) {
                                unsigned long prevTicks = [[prev objectForKey:@"totalTicks"] unsignedLongValue];
                                NSTimeInterval prevTime = [[prev objectForKey:@"time"] doubleValue];
                                NSTimeInterval dt = now - prevTime;
                                if (dt > 0 && totalTicks >= prevTicks) {
                                    double dTicks = (double)(totalTicks - prevTicks);
                                    double dSeconds = dTicks / (double)ticksPerSec;
                                    cpuPercent = (float)((dSeconds / dt) * 100.0);
                                    if (cpuPercent < 0) cpuPercent = 0.0;
                                }
                            }
                            NSDictionary *sample = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithUnsignedLong:totalTicks], @"totalTicks", [NSNumber numberWithDouble:now], @"time", nil];
                            [updatedCpuTimes setObject:sample forKey:pidKey];
                            info.cpu = cpuPercent;

                            // Memory percentage
                            if (totalMemory > 0) {
                                long rss_kb = info.residentMemory; // already KB
                                info.memory = (float)(rss_kb * 100.0 / totalMemory);
                            } else {
                                info.memory = 0.0;
                            }

                            info.user = @"unknown"; // Would need to read uid and map to username

                            [newProcesses addObject:info];
                            procAdded++;
                        }
                        fclose(statFile);
                    }
                }
            }
            PC_DBG(@"/proc scanned entries=%d added=%d", procDirEntries, procAdded);
            if ([newProcesses count] == 0) {
                PC_INFO(@"/proc scan yielded no processes; attempting sysctl fallback");
                // Fall back to sysctl on FreeBSD when /proc yields nothing
#if defined(__FreeBSD__)
                int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
                size_t len2 = 0;
                if (sysctl(mib, 4, NULL, &len2, NULL, 0) == 0 && len2 > 0) {
                    struct kinfo_proc *procs2 = malloc(len2);
                    if (procs2) {
                        if (sysctl(mib, 4, procs2, &len2, NULL, 0) == 0) {
                            int count2 = (int)(len2 / sizeof(struct kinfo_proc));
                            PC_DBG(@"sysctl returned %d entries (fallback)", count2);
                            long pageSize2 = sysconf(_SC_PAGESIZE);
                            long ticksPerSec2 = sysconf(_SC_CLK_TCK);
                            for (int i = 0; i < count2; i++) {
                                struct kinfo_proc *p = &procs2[i];
                                ProcessInfo *info = [[ProcessInfo alloc] init];
                                info.pid = p->ki_pid;
                                info.ppid = p->ki_ppid;
                                info.command = (p->ki_comm[0] != '\0') ? [NSString stringWithUTF8String:p->ki_comm] : @"";
                                struct passwd *pw = getpwuid(p->ki_uid);
                                if (pw) info.user = [NSString stringWithUTF8String:pw->pw_name]; else info.user = @"unknown";
                                info.residentMemory = (long)((long)p->ki_rssize * pageSize2 / 1024); // KB
                                info.virtualMemory = (long)(p->ki_size / 1024);
                                // CPU
                                unsigned long utime_ticks = (unsigned long)(p->ki_rusage.ru_utime.tv_sec * ticksPerSec2 + p->ki_rusage.ru_utime.tv_usec * ticksPerSec2 / 1000000);
                                unsigned long stime_ticks = (unsigned long)(p->ki_rusage.ru_stime.tv_sec * ticksPerSec2 + p->ki_rusage.ru_stime.tv_usec * ticksPerSec2 / 1000000);
                                unsigned long totalTicks = utime_ticks + stime_ticks;
                                NSTimeInterval now2 = [[NSDate date] timeIntervalSince1970];
                                NSString *pidKey2 = [NSString stringWithFormat:@"%d", info.pid];
                                NSDictionary *prev2 = [prevCpuSnapshot objectForKey:pidKey2];
                                float cpuPercent2 = 0.0;
                                if (prev2) {
                                    unsigned long prevTicks = [[prev2 objectForKey:@"totalTicks"] unsignedLongValue];
                                    NSTimeInterval prevTime = [[prev2 objectForKey:@"time"] doubleValue];
                                    NSTimeInterval dt = now2 - prevTime;
                                    if (dt > 0 && totalTicks >= prevTicks) {
                                        double dTicks = (double)(totalTicks - prevTicks);
                                        double dSeconds = dTicks / (double)ticksPerSec2;
                                        cpuPercent2 = (float)((dSeconds / dt) * 100.0);
                                        if (cpuPercent2 < 0) cpuPercent2 = 0.0;
                                    }
                                }
                                NSDictionary *sample2 = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithUnsignedLong:totalTicks], @"totalTicks", [NSNumber numberWithDouble:now2], @"time", nil];
                                [updatedCpuTimes setObject:sample2 forKey:pidKey2];
                                info.cpu = cpuPercent2;
                                if (totalMemory > 0) info.memory = (float)(info.residentMemory * 100.0 / totalMemory); else info.memory = 0.0;
                                [newProcesses addObject:info];
                            }
                        } else {
                            PC_INFO(@"sysctl second call failed (fallback)");
                        }
                        free(procs2);
                    } else {
                        PC_INFO(@"Failed to allocate memory for process list (fallback)");
                    }
                } else {
                    PC_INFO(@"Failed to get process buffer size via sysctl or no processes found (fallback)");
                }
#endif
            }

            // If both /proc and sysctl fail to yield processes, fallback to parsing `ps aux`
            if ([newProcesses count] == 0) {
                PC_INFO(@"Falling back to parsing `ps aux`");
                FILE *ps = popen("ps aux", "r");
                if (ps) {
                    char line[2048];
                    // Skip header
                    if (fgets(line, sizeof(line), ps)) {
                        // header line skipped
                    }
                    while (fgets(line, sizeof(line), ps)) {
                        // Trim newline
                        size_t l = strlen(line);
                        if (l > 0 && line[l-1] == '\n') line[l-1] = '\0';
                        @autoreleasepool {
                            NSString *s = [NSString stringWithUTF8String:line];
                            ProcessInfo *pi = [[ProcessInfo alloc] initWithPsLine:s];
                            if (pi && pi.pid > 0) {
                                [newProcesses addObject:pi];
                            }
                        }
                    }
                    pclose(ps);
                    PC_INFO(@"ps aux fallback added %lu processes", (unsigned long)[newProcesses count]);
                } else {
                    PC_INFO(@"ps aux popen failed");
                }
            }

            closedir(procDir);
        } else {
#if defined(__FreeBSD__)
            // /proc not available - use sysctl on FreeBSD
            PC_DBG(@"/proc not available - attempting sysctl KERN_PROC_ALL");
            int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
            size_t len = 0;
            if (sysctl(mib, 4, NULL, &len, NULL, 0) == 0 && len > 0) {
                struct kinfo_proc *procs = malloc(len);
                if (procs) {
                    if (sysctl(mib, 4, procs, &len, NULL, 0) == 0) {
                        int count = (int)(len / sizeof(struct kinfo_proc));
                        PC_DBG(@"sysctl returned %d entries", count);
                        long pageSize = sysconf(_SC_PAGESIZE);
                        long ticksPerSec = sysconf(_SC_CLK_TCK);
                        for (int i = 0; i < count; i++) {
                            struct kinfo_proc *p = &procs[i];
                            ProcessInfo *info = [[ProcessInfo alloc] init];
                            info.pid = p->ki_pid;
                            info.ppid = p->ki_ppid;

                            // Command
                            if (p->ki_comm[0] != '\0') {
                                info.command = [NSString stringWithUTF8String:p->ki_comm];
                            } else {
                                info.command = @"";
                            }

                            // User
                            struct passwd *pw = getpwuid(p->ki_uid);
                            if (pw) info.user = [NSString stringWithUTF8String:pw->pw_name];
                            else info.user = @"unknown";

                            // Memory
                            info.residentMemory = (long)((long)p->ki_rssize * pageSize / 1024); // KB
                            info.virtualMemory = (long)(p->ki_size / 1024);

                            // State
                            char stateChar = '?';
                            switch (p->ki_stat) {
                                case SZOMB: stateChar = 'Z'; break;
                                case SSTOP: stateChar = 'T'; break;
                                case SRUN: stateChar = 'R'; break;
                                case SSLEEP: stateChar = 'S'; break;
                                default: stateChar = 'R'; break;
                            }
                            info.state = [NSString stringWithFormat:@"%c", stateChar];

                            // CPU: use ki_rusage (utime + stime)
                            unsigned long utime_ticks = (unsigned long)(p->ki_rusage.ru_utime.tv_sec * ticksPerSec + p->ki_rusage.ru_utime.tv_usec * ticksPerSec / 1000000);
                            unsigned long stime_ticks = (unsigned long)(p->ki_rusage.ru_stime.tv_sec * ticksPerSec + p->ki_rusage.ru_stime.tv_usec * ticksPerSec / 1000000);
                            unsigned long totalTicks = utime_ticks + stime_ticks;

                            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                            NSString *pidKey = [NSString stringWithFormat:@"%d", info.pid];
                            NSDictionary *prev = [prevCpuSnapshot objectForKey:pidKey];
                            float cpuPercent = 0.0;
                            if (prev) {
                                unsigned long prevTicks = [[prev objectForKey:@"totalTicks"] unsignedLongValue];
                                NSTimeInterval prevTime = [[prev objectForKey:@"time"] doubleValue];
                                NSTimeInterval dt = now - prevTime;
                                if (dt > 0 && totalTicks >= prevTicks) {
                                    double dTicks = (double)(totalTicks - prevTicks);
                                    double dSeconds = dTicks / (double)ticksPerSec;
                                    cpuPercent = (float)((dSeconds / dt) * 100.0);
                                    if (cpuPercent < 0) cpuPercent = 0.0;
                                }
                            }
                            NSDictionary *sample = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithUnsignedLong:totalTicks], @"totalTicks", [NSNumber numberWithDouble:now], @"time", nil];
                            [updatedCpuTimes setObject:sample forKey:pidKey];
                            info.cpu = cpuPercent;

                            // Memory percentage
                            if (totalMemory > 0) {
                                info.memory = (float)(info.residentMemory * 100.0 / totalMemory);
                            } else {
                                info.memory = 0.0;
                            }

                            [newProcesses addObject:info];
                        }
                    } else {
                        PC_INFO(@"sysctl second call failed");
                    }
                    free(procs);
                } else {
                    PC_INFO(@"Failed to allocate memory for process list");
                }
            } else {
                PC_INFO(@"Failed to get process buffer size via sysctl or no processes found");
            }
#endif
        }

        // Apply results on main thread (or directly if app not running)
        if ([NSApp isRunning]) {
            PC_DBG(@"scheduling apply-results on main thread newProcesses=%lu", (unsigned long)[newProcesses count]);
            NSDictionary *payload = [NSDictionary dictionaryWithObjectsAndKeys:newProcesses, @"new", updatedCpuTimes, @"updated", nil];
            [self performSelectorOnMainThread:@selector(_applyResultsOnMainThread:) withObject:payload waitUntilDone:NO];
        } else {
            // No runloop -> apply synchronously
            [_processesLock lock];
            PC_DBG(@"applying results synchronously (no runloop) newProcesses=%lu", (unsigned long)[newProcesses count]);
            [_processes removeAllObjects];
            [_processes addObjectsFromArray:newProcesses];
            _prevCpuTimes = updatedCpuTimes;
            [_processesLock unlock];

            [_processesTableView reloadData];

            [self sortProcesses];

            _isRefreshing = NO;
        }
    });
}

- (void)_applyResultsOnMainThread:(NSDictionary *)payload
{
    NSArray *newProcesses = [payload objectForKey:@"new"];
    NSDictionary *updatedCpuTimes = [payload objectForKey:@"updated"];
    PC_DBG(@"_applyResultsOnMainThread entered newProcesses=%lu", (unsigned long)[newProcesses count]);

    [_processesLock lock];
    [_processes removeAllObjects];
    [_processes addObjectsFromArray:newProcesses];
    _prevCpuTimes = [NSMutableDictionary dictionaryWithDictionary:updatedCpuTimes];
    [_processesLock unlock];

    [_processesTableView reloadData];

    PC_INFO(@"applied newProcesses count=%lu (from _applyResultsOnMainThread)", (unsigned long)[_processes count]);

    [self sortProcesses];

    _isRefreshing = NO;
}

- (IBAction)forceQuitProcess:(id)sender
{
    NSInteger selectedRow = [_processesTableView selectedRow];
    if (selectedRow >= 0) {
        [_processesLock lock];
        ProcessInfo *info = nil;
        if (selectedRow < [_processes count]) {
            info = [_processes objectAtIndex:selectedRow];
        }
        [_processesLock unlock];
        
        if (info) {
            // First try to send SIGKILL directly
            if (kill(info.pid, SIGKILL) == -1) {
                if (errno == EPERM) {
                    // Permission denied - try using sudo
                    char pidstr[16];
                    snprintf(pidstr, sizeof(pidstr), "%d", info.pid);
                    pid_t child = fork();
                    if (child == 0) {
                        // In child
                        execlp("sudo", "sudo", "-A", "-E", "kill", "-9", pidstr, (char *)NULL);
                        _exit(127); // exec failed
                    } else if (child > 0) {
                        int status = 0;
                        waitpid(child, &status, 0);
                    } else {
                        // fork failed
                    }
                } else {
                    // Other errors - nothing to do
                }
            }
            
            // Refresh after a short delay
            [self performSelector:@selector(refreshProcesses) withObject:nil afterDelay:0.5];
        }
    }
}

- (void)sortProcesses
{
    if (_sortDescriptors && [_sortDescriptors count] > 0) {
        [_processes sortUsingDescriptors:_sortDescriptors];
    }
}

// NSTableViewDataSource
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    [_processesLock lock];
    NSInteger count = [_processes count];
    [_processesLock unlock];
    PC_DBG(@"numberOfRowsInTableView returning %ld", (long)count);
    return count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    [_processesLock lock];
    if (row < 0 || row >= [_processes count]) {
        [_processesLock unlock];
        return @"";
    }
    ProcessInfo *info = [_processes objectAtIndex:row];
    [_processesLock unlock];
    
    NSString *identifier = [tableColumn identifier];
    NSString *result = @"";
    
    if ([identifier isEqualToString:@"pid"]) {
        result = [NSString stringWithFormat:@"%d", info.pid];
    } else if ([identifier isEqualToString:@"user"]) {
        result = info.user ? info.user : @"";
    } else if ([identifier isEqualToString:@"cpu"]) {
        result = [NSString stringWithFormat:@"%.1f", info.cpu];
    } else if ([identifier isEqualToString:@"memory"]) {
        result = [NSString stringWithFormat:@"%.1f", info.memory];
    } else if ([identifier isEqualToString:@"command"]) {
        result = info.command ? info.command : @"";
    } else if ([identifier isEqualToString:@"state"]) {
        result = info.state ? info.state : @"";
    }
    
    return result;
}

// NSTableViewDelegate
- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    NSInteger selectedRow = [_processesTableView selectedRow];
    if (selectedRow >= 0) {
        [_processesLock lock];
        ProcessInfo *info = nil;
        if (selectedRow < [_processes count]) {
            info = [_processes objectAtIndex:selectedRow];
        }
        [_processesLock unlock];
        
        if (info) {
            // Create drawer lazily if needed
            if (!_infoDrawer) {
                _infoDrawer = [[NSDrawer alloc] initWithContentSize:NSMakeSize(300, 400) preferredEdge:NSMaxXEdge];
                [_infoDrawer setParentWindow:_mainWindow];
                [_infoDrawer setDelegate:self];
                
                NSView *drawerContent = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 400)];
                [_infoDrawer setContentView:drawerContent];
                
                // Info text field
                _infoTextField = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 50, 280, 320)];
                [_infoTextField setEditable:NO];
                [_infoTextField setSelectable:YES];
                [_infoTextField setBordered:YES];
                [_infoTextField setBezeled:YES];
                [[_infoDrawer contentView] addSubview:_infoTextField];
                
                // Force quit button
                _forceQuitButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, 10, 100, 24)];
                [_forceQuitButton setTitle:@"Force Quit"];
                [_forceQuitButton setTarget:self];
                [_forceQuitButton setAction:@selector(forceQuitProcess:)];
                [_forceQuitButton setEnabled:NO];
                [[_infoDrawer contentView] addSubview:_forceQuitButton];
            }
            
            // Populate drawer with safe access
            NSMutableString *infoString = [NSMutableString string];
            [infoString appendString:@"Process Information:\n\n"];
            [infoString appendFormat:@"PID: %d\n", info.pid];
            [infoString appendFormat:@"User: %@\n", (info.user ? info.user : @"N/A")];
            [infoString appendFormat:@"CPU: %.1f%%\n", info.cpu];
            [infoString appendFormat:@"Memory: %.1f%%\n", info.memory];
            [infoString appendFormat:@"State: %@\n", (info.state ? info.state : @"N/A")];
            [infoString appendFormat:@"Command: %@\n", (info.command ? info.command : @"N/A")];
            
            [_infoTextField setStringValue:infoString];

            
            [_forceQuitButton setEnabled:YES];
            [_infoDrawer open];
        } else {
            [_processesLock unlock];
            [_forceQuitButton setEnabled:NO];
            if (_infoDrawer) [_infoDrawer close];
        }
    } else {
        [_forceQuitButton setEnabled:NO];
        if (_infoDrawer) [_infoDrawer close];
    }
    [_processesTableView setNeedsDisplay:YES];
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    [cell setDrawsBackground:NO];

    if ([tableView isRowSelected:row]) {
        [cell setTextColor:[NSColor selectedTextColor]];
    } else {
        [cell setTextColor:[NSColor controlTextColor]];
    }
}

- (void)tableView:(NSTableView *)tableView didClickTableColumn:(NSTableColumn *)tableColumn
{
    // Not needed, handled by sortDescriptorsDidChange
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray *)oldDescriptors
{
    _sortDescriptors = [tableView sortDescriptors];
    [_processesLock lock];
    [self sortProcesses];
    [_processesLock unlock];
    [_processesTableView reloadData];
}

// NSApplicationDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    PC_INFO(@"applicationDidFinishLaunching start");
    [self createUI];
    PC_INFO(@"created UI");
    [self startMonitoring];
    PC_INFO(@"started monitoring");
    [_mainWindow makeKeyAndOrderFront:self];
    
    // Force a couple of refresh attempts to ensure background worker runs
    [self performSelector:@selector(refreshProcesses) withObject:nil afterDelay:0.1];
    [self performSelector:@selector(refreshProcesses) withObject:nil afterDelay:1.0];
    // Also call refresh synchronously once as a last resort
    [self refreshProcesses];
}

- (void)setupMenu
{
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"Processes"];
    NSMenuItem *appMenuItem = (NSMenuItem *)[mainMenu addItemWithTitle:@"Processes" action:NULL keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Processes"];
    
    [appMenu addItemWithTitle:@"About Processes" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide Processes" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@""];
    [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit Processes" action:@selector(terminate:) keyEquivalent:@"q"];
    
    [mainMenu setSubmenu:appMenu forItem:appMenuItem];
    
    // Window Menu
    NSMenuItem *windowMenuItem = (NSMenuItem *)[mainMenu addItemWithTitle:@"Window" action:NULL keyEquivalent:@""];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [mainMenu setSubmenu:windowMenu forItem:windowMenuItem];
    [NSApp setWindowsMenu:windowMenu];
    
    [NSApp setMainMenu:mainMenu];
}

- (void)createUI
{
    // Create main window
    _mainWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 800, 600)
                                                styleMask:(NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    [_mainWindow setTitle:@"Processes"];
    [_mainWindow setDelegate:self];
    
    [self setupMenu];
    
    // Create scroll view for table
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:[[_mainWindow contentView] bounds]];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:YES];
    [scrollView setAutohidesScrollers:YES];
    [scrollView setBorderType:NSBezelBorder];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    // Create table view
    _processesTableView = [[ProcessTableView alloc] initWithFrame:[scrollView bounds]];
    [_processesTableView setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    [_processesTableView setRowHeight:[_processesTableView rowHeight] - 2.0];
    [_processesTableView setDataSource:self];
    [_processesTableView setDelegate:self];
    [_processesTableView setAllowsMultipleSelection:NO];
    [_processesTableView setIntercellSpacing:NSMakeSize(0, 0)];
    [_processesTableView setGridStyleMask:NSTableViewGridNone];

    NSTableColumn *pidColumn = [[NSTableColumn alloc] initWithIdentifier:@"pid"];
    [[pidColumn headerCell] setStringValue:@"PID"];
    [pidColumn setWidth:60];
    [pidColumn setSortDescriptorPrototype:[[NSSortDescriptor alloc] initWithKey:@"pid" ascending:YES]];
    [_processesTableView addTableColumn:pidColumn];
    
    NSTableColumn *userColumn = [[NSTableColumn alloc] initWithIdentifier:@"user"];
    [[userColumn headerCell] setStringValue:@"User"];
    [userColumn setWidth:80];
    [userColumn setSortDescriptorPrototype:[[NSSortDescriptor alloc] initWithKey:@"user" ascending:YES]];
    [_processesTableView addTableColumn:userColumn];
    
    NSTableColumn *cpuColumn = [[NSTableColumn alloc] initWithIdentifier:@"cpu"];
    [[cpuColumn headerCell] setStringValue:@"CPU %"];
    [cpuColumn setWidth:60];
    [cpuColumn setSortDescriptorPrototype:[[NSSortDescriptor alloc] initWithKey:@"cpu" ascending:NO]];
    [_processesTableView addTableColumn:cpuColumn];
    
    NSTableColumn *memColumn = [[NSTableColumn alloc] initWithIdentifier:@"memory"];
    [[memColumn headerCell] setStringValue:@"Memory %"];
    [memColumn setWidth:80];
    [memColumn setSortDescriptorPrototype:[[NSSortDescriptor alloc] initWithKey:@"memory" ascending:YES]];
    [_processesTableView addTableColumn:memColumn];
    
    NSTableColumn *stateColumn = [[NSTableColumn alloc] initWithIdentifier:@"state"];
    [[stateColumn headerCell] setStringValue:@"State"];
    [stateColumn setWidth:50];
    [stateColumn setSortDescriptorPrototype:[[NSSortDescriptor alloc] initWithKey:@"state" ascending:YES]];
    [_processesTableView addTableColumn:stateColumn];
    
    NSTableColumn *commandColumn = [[NSTableColumn alloc] initWithIdentifier:@"command"];
    [[commandColumn headerCell] setStringValue:@"Command"];
    [commandColumn setWidth:300];
    [commandColumn setSortDescriptorPrototype:[[NSSortDescriptor alloc] initWithKey:@"command" ascending:YES]];
    [_processesTableView addTableColumn:commandColumn];
    
    // Default sort: CPU descending (highest first) ✅
    NSSortDescriptor *cpuDesc = [[NSSortDescriptor alloc] initWithKey:@"cpu" ascending:NO];
    _sortDescriptors = @[cpuDesc];
    [_processesTableView setSortDescriptors:_sortDescriptors];
    
    [scrollView setDocumentView:_processesTableView];
    [[_mainWindow contentView] addSubview:scrollView];

#if PROCESSES_DEBUG
    // Diagnostic: log frames and column count to ensure table is visible and sized correctly
    NSString *svFrameStr = NSStringFromRect([scrollView frame]);
    NSString *tvFrameStr = NSStringFromRect([_processesTableView frame]);
    PC_DBG(@"createUI: scrollView frame=%s table frame=%s columns=%lu", [svFrameStr UTF8String], [tvFrameStr UTF8String], (unsigned long)[[_processesTableView tableColumns] count]);
#else
    (void)scrollView; (void)_processesTableView;
#endif

    // Buttons removed as requested
    
    // Create drawer - temporarily disabled to debug crash
    /*
    _infoDrawer = [[NSDrawer alloc] initWithContentSize:NSMakeSize(300, 400) preferredEdge:NSMaxXEdge];
    [_infoDrawer setParentWindow:_mainWindow];
    [_infoDrawer setDelegate:self];
    
    NSView *drawerContent = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 400)];
    [_infoDrawer setContentView:drawerContent];
    
    // Info text field
    _infoTextField = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 50, 280, 320)];
    [_infoTextField setEditable:NO];
    [_infoTextField setSelectable:YES];
    [_infoTextField setBordered:YES];
    [_infoTextField setBezeled:YES];
    [drawerContent addSubview:_infoTextField];
    
    // Force quit button
    _forceQuitButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, 10, 100, 24)];
    [_forceQuitButton setTitle:@"Force Quit"];
    [_forceQuitButton setTarget:self];
    [_forceQuitButton setAction:@selector(forceQuitProcess:)];
    [_forceQuitButton setEnabled:NO];
    [drawerContent addSubview:_forceQuitButton];
    */
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

@end
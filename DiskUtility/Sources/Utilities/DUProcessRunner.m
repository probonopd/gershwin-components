/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUProcessRunner.h"

#import "DUErrors.h"

static const NSTimeInterval kDefaultTimeoutSeconds = 300.0;
// Grace period after SIGTERM before escalating to SIGKILL.
static const NSTimeInterval kTerminateGraceSeconds = 5.0;

@interface DUProcessResult ()
@property (nonatomic, readwrite) int terminationStatus;
@property (nonatomic, readwrite, copy) NSString *standardOutput;
@property (nonatomic, readwrite, copy) NSString *standardError;
@property (nonatomic, readwrite) BOOL exitedNormally;
@property (nonatomic, readwrite) BOOL wasCancelled;
@property (nonatomic, readwrite) BOOL timedOut;
@end

@implementation DUProcessResult
@end

@interface DUProcessHandle ()
@property (nonatomic, strong) NSTask *task;
@end

@implementation DUProcessHandle

- (void)cancel
{
    @synchronized (self) {
        if (_task != nil && _task.isRunning) {
            [_task terminate];
        }
    }
}

@end

@implementation DUProcessRunner

+ (NSString *)executablePathForName:(NSString *)name
{
    // Fixed search order instead of $PATH: a caller-controlled PATH must
    // never decide which binary performs a privileged storage operation.
    NSArray<NSString *> *directories = @[
        @"/usr/sbin",
        @"/sbin",
        @"/usr/bin",
        @"/bin",
        @"/usr/local/sbin",
        @"/usr/local/bin",
        @"/usr/pkg/sbin",
        @"/usr/pkg/bin",
    ];
    for (NSString *directory in directories) {
        NSString *candidate = [directory stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

+ (NSDictionary<NSString *, NSString *> *)launchEnvironmentWithOverrides:
        (NSDictionary<NSString *, NSString *> *)overrides
{
    // Tools are parsed with LC_ALL=C so their output stays locale-stable
    // regardless of the desktop session language.
    NSMutableDictionary<NSString *, NSString *> *environment =
        [NSMutableDictionary dictionaryWithDictionary:
                       [[NSProcessInfo processInfo] environment]];
    environment[@"LC_ALL"] = @"C";
    environment[@"LANG"] = @"C";
    for (NSString *key in overrides) {
        environment[key] = overrides[key];
    }
    return environment;
}

// Reads one stream to EOF on the calling thread. Each pipe gets its own
// thread so both drain concurrently; otherwise a chatty child could block
// on a filled pipe buffer while we wait on the other stream.

// GNUstep NSThread offers no join; poll isFinished at a coarse interval,
// which is sufficient because callers already tolerate 50 ms latencies.
+ (void)joinThread:(NSThread *)thread
{
    while (thread != nil && !thread.isFinished) {
        [NSThread sleepForTimeInterval:0.02];
    }
}

+ (NSData *)drainPipe:(NSPipe *)pipe
{
    NSMutableData *collected = [NSMutableData data];
    NSFileHandle *handle = pipe.fileHandleForReading;
    for (;;) {
        NSData *chunk = nil;
        @try {
            chunk = [handle readDataToEndOfFile];
        } @catch (NSException __attribute__((unused)) *exception) {
            break;
        }
        if (chunk.length == 0) {
            break;
        }
        [collected appendData:chunk];
    }
    return collected;
}

// Terminates, waits out the grace period, then kills if still alive.
+ (void)terminateTaskGracefully:(NSTask *)task
{
    if (!task.isRunning) {
        return;
    }
    [task terminate];
    NSDate *deadline =
        [NSDate dateWithTimeIntervalSinceNow:kTerminateGraceSeconds];
    while (task.isRunning && [deadline timeIntervalSinceNow] > 0) {
        [NSThread sleepForTimeInterval:0.05];
    }
    if (task.isRunning) {
        // Last resort when SIGTERM was ignored; storage tools occasionally
        // block on device I/O and never notice the polite signal.
        kill(task.processIdentifier, SIGKILL);
    }
}

+ (DUProcessResult *)runExecutable:(NSString *)path
                         arguments:(NSArray<NSString *> *)arguments
                             error:(NSError **)error
{
    return [self runExecutable:path
                     arguments:arguments
                   environment:nil
                       timeout:kDefaultTimeoutSeconds
                         error:error];
}

+ (DUProcessResult *)runExecutable:(NSString *)path
                         arguments:(NSArray<NSString *> *)arguments
                       environment:(NSDictionary<NSString *, NSString *> *)overrides
                           timeout:(NSTimeInterval)timeout
                             error:(NSError **)error
{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = path;
    task.arguments = arguments ?: @[];
    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;
    task.environment =
        [self launchEnvironmentWithOverrides:overrides ?: @{}];

    @try {
        [task launch];
    } @catch (NSException *exception) {
        if (error != NULL) {
            *error = DUErrorMake(
                DUErrorUnknown,
                [NSString stringWithFormat:@"Could not launch %@: %@",
                                           path,
                                           exception.reason]);
        }
        return nil;
    }

    __block NSData *stdoutData = nil;
    __block NSData *stderrData = nil;
    NSThread *stdoutThread = [[NSThread alloc]
        initWithBlock:^{
            stdoutData = [DUProcessRunner drainPipe:stdoutPipe];
        }];
    NSThread *stderrThread = [[NSThread alloc]
        initWithBlock:^{
            stderrData = [DUProcessRunner drainPipe:stderrPipe];
        }];
    [stdoutThread start];
    [stderrThread start];

    BOOL timedOut = NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([task isRunning]) {
        if ([deadline timeIntervalSinceNow] <= 0) {
            timedOut = YES;
            [self terminateTaskGracefully:task];
            break;
        }
        [NSThread sleepForTimeInterval:0.05];
    }
    [task waitUntilExit];
    [self joinThread:stdoutThread];
    [self joinThread:stderrThread];

    DUProcessResult *result = [[DUProcessResult alloc] init];
    result.terminationStatus = task.terminationStatus;
    result.exitedNormally =
        task.terminationReason == NSTaskTerminationReasonExit;
    result.timedOut = timedOut;
    result.standardOutput = stdoutData.length > 0
        ? [[NSString alloc] initWithData:stdoutData
                                encoding:NSUTF8StringEncoding]
              ?: [[NSString alloc] initWithData:stdoutData
                                       encoding:NSISOLatin1StringEncoding]
              ?: @""
        : @"";
    result.standardError = stderrData.length > 0
        ? [[NSString alloc] initWithData:stderrData
                                encoding:NSUTF8StringEncoding]
              ?: [[NSString alloc] initWithData:stderrData
                                       encoding:NSISOLatin1StringEncoding]
              ?: @""
        : @"";
    return result;
}

+ (DUProcessHandle *)streamExecutable:(NSString *)path
                            arguments:(NSArray<NSString *> *)arguments
                          environment:(NSDictionary<NSString *, NSString *> *)overrides
                        stdoutHandler:(void (^)(NSString *))stdoutHandler
                        finishHandler:(void (^)(DUProcessResult *))finishHandler
{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = path;
    task.arguments = arguments ?: @[];
    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;
    task.environment = [self launchEnvironmentWithOverrides:overrides ?: @{}];

    DUProcessHandle *handle = [[DUProcessHandle alloc] init];
    handle.task = task;

    @try {
        [task launch];
    } @catch (NSException *exception) {
        DUProcessResult *failed = [[DUProcessResult alloc] init];
        failed.exitedNormally = NO;
        failed.standardError =
            [NSString stringWithFormat:@"Could not launch %@: %@",
                                       path,
                                       exception.reason];
        if (finishHandler != nil) {
            finishHandler(failed);
        }
        return handle;
    }

    NSMutableString *accumulatedStderr = [NSMutableString string];
    NSLock *stderrLock = [[NSLock alloc] init];

    // Line-oriented stdout pump feeding progress callbacks.
    NSThread *stdoutThread = [[NSThread alloc]
        initWithBlock:^{
            NSFileHandle *fileHandle = stdoutPipe.fileHandleForReading;
            NSMutableData *pending = [NSMutableData data];
            for (;;) {
                NSData *chunk = nil;
                @try {
                    chunk = [fileHandle availableData];
                } @catch (NSException __attribute__((unused)) *e) {
                    break;
                }
                if (chunk.length == 0) {
                    break;
                }
                [pending appendData:chunk];
                NSRange newlineRange;
                while ((newlineRange = [pending
                            rangeOfData:[NSData dataWithBytes:"\n" length:1]
                                options:0
                                  range:NSMakeRange(0,
                                                     pending.length)]).location
                       != NSNotFound) {
                    NSUInteger newlineIndex = newlineRange.location;
                    NSData *lineData =
                        [pending subdataWithRange:NSMakeRange(0, newlineIndex)];
                    [pending replaceBytesInRange:NSMakeRange(0, newlineIndex + 1)
                                       withBytes:NULL
                                          length:0];
                    NSString *line = [[NSString alloc]
                        initWithData:lineData
                            encoding:NSUTF8StringEncoding]
                        ?: @"";
                    if (stdoutHandler != nil) {
                        stdoutHandler(line);
                    }
                }
            }
            if (pending.length > 0 && stdoutHandler != nil) {
                NSString *remainder = [[NSString alloc]
                    initWithData:pending encoding:NSUTF8StringEncoding]
                    ?: @"";
                stdoutHandler(remainder);
            }
        }];

    NSThread *stderrThread = [[NSThread alloc]
        initWithBlock:^{
            NSData *data = [DUProcessRunner drainPipe:stderrPipe];
            NSString *text = [[NSString alloc] initWithData:data
                                                   encoding:NSUTF8StringEncoding]
                ?: @"";
            [stderrLock lock];
            [accumulatedStderr appendString:text];
            [stderrLock unlock];
        }];

    // Completion watcher; keeps the handle alive until exit so cancel()
    // remains valid for the whole run.
    NSThread *watcher = [[NSThread alloc]
        initWithBlock:^{
            [DUProcessRunner joinThread:stdoutThread];
            [DUProcessRunner joinThread:stderrThread];
            [task waitUntilExit];

            DUProcessResult *result = [[DUProcessResult alloc] init];
            result.terminationStatus = task.terminationStatus;
            result.exitedNormally =
                task.terminationReason == NSTaskTerminationReasonExit;
            result.wasCancelled = !task.isRunning
                && task.terminationReason != NSTaskTerminationReasonExit;
            [stderrLock lock];
            result.standardError = [accumulatedStderr copy];
            [stderrLock unlock];
            result.standardOutput = @"";
            if (finishHandler != nil) {
                finishHandler(result);
            }
        }];
    [stdoutThread start];
    [stderrThread start];
    [watcher start];

    return handle;
}

+ (DUProcessHandle *)streamExecutableMergingErrorOutput:(NSString *)path
                                              arguments:(NSArray<NSString *> *)arguments
                                            environment:(NSDictionary<NSString *, NSString *> *)overrides
                                          stdoutHandler:(void (^)(NSString *))stdoutHandler
                                         finishHandler:(void (^)(DUProcessResult *))finishHandler
{
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = path;
    task.arguments = arguments ?: @[];
    NSPipe *mergedPipe = [NSPipe pipe];
    task.standardOutput = mergedPipe;
    // Same write end for both streams: their lines interleave in arrival
    // order on the single reader below.
    task.standardError = mergedPipe;
    task.environment = [self launchEnvironmentWithOverrides:overrides ?: @{}];

    DUProcessHandle *handle = [[DUProcessHandle alloc] init];
    handle.task = task;

    @try {
        [task launch];
    } @catch (NSException *exception) {
        DUProcessResult *failed = [[DUProcessResult alloc] init];
        failed.exitedNormally = NO;
        failed.standardError =
            [NSString stringWithFormat:@"Could not launch %@: %@",
                                       path,
                                       exception.reason];
        if (finishHandler != nil) {
            finishHandler(failed);
        }
        return handle;
    }

    NSMutableString *accumulated = [NSMutableString string];
    NSLock *textLock = [[NSLock alloc] init];
    void (^lineSink)(NSString *) = ^(NSString *line) {
        [textLock lock];
        [accumulated appendFormat:@"%@\n", line];
        [textLock unlock];
        if (stdoutHandler != nil) {
            stdoutHandler(line);
        }
    };

    NSThread *readerThread = [[NSThread alloc]
        initWithBlock:^{
            NSFileHandle *fileHandle = mergedPipe.fileHandleForReading;
            NSMutableData *pending = [NSMutableData data];
            NSData *newline = [NSData dataWithBytes:"\n" length:1];
            for (;;) {
                NSData *chunk = nil;
                @try {
                    chunk = [fileHandle availableData];
                } @catch (NSException __attribute__((unused)) *e) {
                    break;
                }
                if (chunk.length == 0) {
                    break;
                }
                [pending appendData:chunk];
                NSRange newlineRange;
                while ((newlineRange = [pending rangeOfData:newline
                                                    options:0
                                                      range:NSMakeRange(0, pending.length)]).location
                       != NSNotFound) {
                    NSUInteger newlineIndex = newlineRange.location;
                    NSData *lineData =
                        [pending subdataWithRange:NSMakeRange(0, newlineIndex)];
                    [pending replaceBytesInRange:NSMakeRange(0, newlineIndex + 1)
                                       withBytes:NULL
                                          length:0];
                    lineSink([[NSString alloc]
                        initWithData:lineData
                            encoding:NSUTF8StringEncoding] ?: @"");
                }
            }
            if (pending.length > 0) {
                lineSink([[NSString alloc]
                    initWithData:pending encoding:NSUTF8StringEncoding] ?: @"");
            }
        }];

    NSThread *watcher = [[NSThread alloc]
        initWithBlock:^{
            [DUProcessRunner joinThread:readerThread];
            [task waitUntilExit];

            DUProcessResult *result = [[DUProcessResult alloc] init];
            result.terminationStatus = task.terminationStatus;
            result.exitedNormally =
                task.terminationReason == NSTaskTerminationReasonExit;
            result.wasCancelled = !task.isRunning
                && task.terminationReason != NSTaskTerminationReasonExit;
            [textLock lock];
            result.standardOutput = [accumulated copy];
            [textLock unlock];
            if (finishHandler != nil) {
                finishHandler(result);
            }
        }];
    [readerThread start];
    [watcher start];

    return handle;
}

@end

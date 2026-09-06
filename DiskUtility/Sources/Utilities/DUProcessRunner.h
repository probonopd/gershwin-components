/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Outcome of a completed external process run.
@interface DUProcessResult : NSObject

// Raw wait status; interpret via WIFEXITED/WEXITSTATUS.
@property (nonatomic, readonly) int terminationStatus;

@property (nonatomic, readonly) NSString *standardOutput;
@property (nonatomic, readonly) NSString *standardError;
@property (nonatomic, readonly) BOOL exitedNormally;
@property (nonatomic, readonly) BOOL wasCancelled;
@property (nonatomic, readonly) BOOL timedOut;

@end

// Handle for cancelling an in-flight streaming run. Safe to call from any
// thread; cancel is idempotent.
@interface DUProcessHandle : NSObject

- (void)cancel;

@end

// Synchronous NSTask wrapper used by backends from background threads.
//
// Security contract (ARCHITECTURE.md section 26):
//  - the executable is launched directly, never through a shell
//  - arguments are passed as an array, so user input can never gain shell
//    semantics
//  - callers pass absolute paths discovered via +executablePathForName:
//
// Threading contract: all methods BLOCK the calling thread. Backends must
// invoke them on background threads only (ARCHITECTURE.md section 53).
@interface DUProcessRunner : NSObject

// Locates an executable in a fixed set of system directories (never $PATH)
// so a caller-controlled PATH cannot redirect privileged operations.
+ (NSString *)executablePathForName:(NSString *)name;

// Runs to completion capturing both output streams concurrently so a full
// pipe cannot deadlock either side. On timeout the process is terminated.
// Returns nil only when the task could not be launched at all.
+ (DUProcessResult *)runExecutable:(NSString *)path
                         arguments:(NSArray<NSString *> *)arguments
                             error:(NSError **)error;

+ (DUProcessResult *)runExecutable:(NSString *)path
                         arguments:(NSArray<NSString *> *)arguments
                       environment:(NSDictionary<NSString *, NSString *> *)overrides
                           timeout:(NSTimeInterval)timeout
                             error:(NSError **)error;

// Streaming variant: stdoutLine fires per complete line on a reader thread;
// finish fires once with the final result. The handle allows cancellation.
+ (DUProcessHandle *)streamExecutable:(NSString *)path
                            arguments:(NSArray<NSString *> *)arguments
                          environment:(NSDictionary<NSString *, NSString *> *)overrides
                        stdoutHandler:(void (^)(NSString *line))stdoutHandler
                         finishHandler:(void (^)(DUProcessResult *result))finishHandler;

// Like streamExecutable:, but the child's stderr is redirected into the
// same pipe as its stdout, so lineHandler receives BOTH streams' lines in
// arrival order. Storage tools (dd, mkfs, fsck) report progress on stderr,
// so progress plumbing needs the merged view; the final result carries the
// merged text in standardOutput and leaves standardError empty.
+ (DUProcessHandle *)streamExecutableMergingErrorOutput:(NSString *)path
                                              arguments:(NSArray<NSString *> *)arguments
                                            environment:(NSDictionary<NSString *, NSString *> *)overrides
                                          stdoutHandler:(void (^)(NSString *line))stdoutHandler
                                         finishHandler:(void (^)(DUProcessResult *result))finishHandler;

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class DUProcessHandle;
@class DUProcessResult;

// Privilege escalation helper (ARCHITECTURE.md section 27). When already
// root, commands run directly; otherwise they are prefixed with
// "sudo -A", which collects the password through the askpass helper named
// by $SUDO_ASKPASS - the only sudo mode that can work from a GUI process,
// which owns no terminal for a prompt (ARCHITECTURE.md section 27 bans an
// interactive sudo). All execution goes through DUProcessRunner: no shell,
// argument arrays only.
@interface DUAuthorizationManager : NSObject

+ (DUAuthorizationManager *)sharedManager;

// YES when running with effective uid 0.
+ (BOOL)elevated;

// Resolves how `toolPath` must be launched so it runs with elevated rights:
// unchanged as (*launchPathOut, *argumentsOut) when already root, or as
// (sudo, [-A, toolPath, toolArgs...]) otherwise. Returns NO and sets a
// PermissionDenied error when elevation is required but no escalation
// mechanism is installed.
- (BOOL)resolveLaunch:(NSString *)toolPath
        toolArguments:(NSArray<NSString *> *)toolArgs
       launchPathOut:(NSString **)launchPathOut
        argumentsOut:(NSArray<NSString *> **)argumentsOut
               error:(NSError **)error;

// Runs `path` with `args`, escalating via sudo when not root. Returns the
// process result; nil only when the tool could not be launched at all. A
// PermissionDenied error is surfaced when no escalation mechanism exists or
// sudo reports an authentication failure; other nonzero exits are left for
// the caller to interpret from the result.
- (DUProcessResult *)runPrivileged:(NSString *)path
                              args:(NSArray<NSString *> *)args
                           timeout:(NSTimeInterval)timeout
                             error:(NSError **)error;

// Streaming counterpart of runPrivileged:args:timeout:error: for long
// filesystem work whose progress comes line-by-line. The child's stderr is
// merged into stdout, so handlers receive both streams' lines (dd, mkfs and
// fsck report progress on stderr); the final DUProcessResult carries the
// merged transcript in standardOutput. Handlers mirror
// +[DUProcessRunner streamExecutableMergingErrorOutput:]. Returns nil
// without calling any handler only when the launch could not be resolved
// (`error` is set); the returned handle allows cancellation.
- (DUProcessHandle *)streamPrivileged:(NSString *)path
                                 args:(NSArray<NSString *> *)args
                        stdoutHandler:(void (^)(NSString *line))stdoutHandler
                        finishHandler:(void (^)(DUProcessResult *result))finishHandler
                                error:(NSError **)error;

@end

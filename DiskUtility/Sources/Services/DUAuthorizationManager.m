/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUAuthorizationManager.h"

#import <unistd.h>

#import "DUErrors.h"
#import "DUProcessRunner.h"

// sudo exits with this status when it could not obtain credentials.
static const int DUSudoCredentialFailure = 1;

@implementation DUAuthorizationManager

+ (DUAuthorizationManager *)sharedManager
{
    // No dispatch_once (banned); the lock is uncontended after first use.
    static DUAuthorizationManager *shared = nil;
    @synchronized(self) {
        if (shared == nil) {
            shared = [[DUAuthorizationManager alloc] init];
        }
        return shared;
    }
}

+ (BOOL)elevated
{
    return geteuid() == 0;
}

- (BOOL)looksLikeAuthenticationFailure:(DUProcessResult *)result
{
    if (!(result.exitedNormally && result.terminationStatus == DUSudoCredentialFailure)) {
        return NO;
    }
    NSString *output =
        [NSString stringWithFormat:@"%@ %@", result.standardError, result.standardOutput];
    // sudo phrases credential problems in a few known ways; matching on
    // them keeps genuine command failures from being misread as auth errors.
    // "askpass" covers a missing/broken SUDO_ASKPASS helper.
    return [output rangeOfString:@"password" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [output rangeOfString:@"not allowed" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [output rangeOfString:@"authentication" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [output rangeOfString:@"a terminal is required" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [output rangeOfString:@"askpass" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

- (BOOL)resolveLaunch:(NSString *)toolPath
        toolArguments:(NSArray<NSString *> *)toolArgs
       launchPathOut:(NSString **)launchPathOut
        argumentsOut:(NSArray<NSString *> **)argumentsOut
               error:(NSError **)error
{
    NSParameterAssert(toolPath.length > 0);
    NSParameterAssert([toolPath hasPrefix:@"/"]);

    if ([DUAuthorizationManager elevated]) {
        if (launchPathOut != nil) {
            *launchPathOut = toolPath;
        }
        if (argumentsOut != nil) {
            *argumentsOut = toolArgs ?: @[];
        }
        return YES;
    }

    NSString *sudo = [DUProcessRunner executablePathForName:@"sudo"];
    if (sudo == nil) {
        // Nothing to escalate with; say so instead of pretending to run.
        if (error != nil) {
            *error = DUErrorMake(
                DUErrorPermissionDenied,
                NSLocalizedString(@"No privilege escalation tool available", nil));
        }
        return NO;
    }

    NSMutableArray<NSString *> *arguments =
        [NSMutableArray arrayWithObjects:@"-A", toolPath, nil];
    [arguments addObjectsFromArray:toolArgs ?: @[]];

    if (launchPathOut != nil) {
        *launchPathOut = sudo;
    }
    if (argumentsOut != nil) {
        *argumentsOut = arguments;
    }
    return YES;
}

- (DUProcessResult *)runPrivileged:(NSString *)path
                              args:(NSArray<NSString *> *)args
                           timeout:(NSTimeInterval)timeout
                             error:(NSError **)error
{
    NSString *launchPath = nil;
    NSArray<NSString *> *arguments = nil;
    if (![self resolveLaunch:path
                   toolArguments:args
                  launchPathOut:&launchPath
                   argumentsOut:&arguments
                          error:error]) {
        return nil;
    }

    NSError *launchError = nil;
    DUProcessResult *result =
        [DUProcessRunner runExecutable:launchPath
                             arguments:arguments
                           environment:nil
                               timeout:timeout
                                 error:&launchError];
    if (result == nil) {
        if (error != nil) {
            *error = launchError ?:
                DUErrorMake(DUErrorPermissionDenied,
                            NSLocalizedString(@"sudo could not be launched", nil));
        }
        return nil;
    }
    if ([self looksLikeAuthenticationFailure:result]) {
        if (error != nil) {
            *error = DUErrorMake(
                DUErrorPermissionDenied,
                NSLocalizedString(@"Administrator authorization was refused", nil));
        }
        return result;
    }
    return result;
}

- (DUProcessHandle *)streamPrivileged:(NSString *)path
                                 args:(NSArray<NSString *> *)args
                        stdoutHandler:(void (^)(NSString *line))stdoutHandler
                        finishHandler:(void (^)(DUProcessResult *result))finishHandler
                                error:(NSError **)error
{
    NSString *launchPath = nil;
    NSArray<NSString *> *arguments = nil;
    if (![self resolveLaunch:path
                   toolArguments:args
                  launchPathOut:&launchPath
                   argumentsOut:&arguments
                          error:error]) {
        return nil;
    }
    return [DUProcessRunner streamExecutableMergingErrorOutput:launchPath
                                                    arguments:arguments
                                                  environment:nil
                                                stdoutHandler:stdoutHandler
                                                 finishHandler:finishHandler];
}

@end

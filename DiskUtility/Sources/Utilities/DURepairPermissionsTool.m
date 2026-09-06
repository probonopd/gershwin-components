/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "DURepairPermissionsTool.h"
#import "DUAuthorizationManager.h"
#import "DUProcessRunner.h"

// Repairs every local user's home directory so all files there belong to the
// owning user: chown -R <user> <home>, then chmod -R u=rwX,go= <home>. Enumerates
// real login users from /etc/passwd (uid >= 1000, a valid interactive shell, an
// absolute home that exists) so system and service accounts are never touched.
// Runs as one privileged /bin/sh -c script so the whole job is a single
// elevated invocation rather than N per-user escalations.
@implementation DURepairPermissionsTool

+ (NSString *)shellQuote:(NSString *)value
{
    NSString *escaped =
        [value stringByReplacingOccurrencesOfString:@"'"
                                          withString:@"'\\''"];
    return [@"'" stringByAppendingString:[escaped stringByAppendingString:@"'"]];
}

+ (NSArray<NSDictionary *> *)enumerateUserHomes
{
    NSString *passwd =
        [NSString stringWithContentsOfFile:@"/etc/passwd"
                                  encoding:NSUTF8StringEncoding
                                     error:NULL];
    if (passwd == nil) {
        return @[];
    }
    NSArray<NSString *> *blockedShells = @[
        @"/usr/sbin/nologin", @"/sbin/nologin",
        @"/bin/false", @"/usr/bin/false", @"/usr/bin/nologin"
    ];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSString *line in [passwd componentsSeparatedByString:@"\n"]) {
        if (line.length == 0 || [line hasPrefix:@"#"]) {
            continue;
        }
        NSArray<NSString *> *fields = [line componentsSeparatedByString:@":"];
        if (fields.count < 7) {
            continue;
        }
        long uid = [fields[2] longLongValue];
        if (uid < 1000) {
            continue;
        }
        NSString *shell = fields[6];
        if ([blockedShells containsObject:shell]) {
            continue;
        }
        NSString *home = fields[5];
        if (home.length == 0 || ![home hasPrefix:@"/"]) {
            continue;
        }
        [result addObject:@{ @"user" : fields[0], @"home" : home }];
    }
    return result;
}

+ (void)repairHomePermissionsWithProgress:(void (^)(double, NSString *))progress
                                completion:(void (^)(NSError *))completion
{
    NSArray<NSDictionary *> *users = [self enumerateUserHomes];
    if (users.count == 0) {
        if (progress != NULL) {
            progress(1.0, NSLocalizedString(
                         @"No user home directories to repair.", nil));
        }
        if (completion != NULL) {
            completion(nil);
        }
        return;
    }
    NSString *chownPath =
        [DUProcessRunner executablePathForName:@"chown"] ?: @"/bin/chown";
    NSString *chmodPath =
        [DUProcessRunner executablePathForName:@"chmod"] ?: @"/bin/chmod";
    NSMutableString *script = [NSMutableString string];
    for (NSDictionary *entry in users) {
        NSString *user = entry[@"user"];
        NSString *home = entry[@"home"];
        // One line per user: chown -R, then chmod -R, then a marker line the
        // log handler turns into a per-user "Repaired permissions for <home>"
        // entry. The marker is printed whether or not the two tools succeeded
        // (REPAIRED on success, FAILED on either failure) so every account
        // gets a line in the operation log.
        [script appendFormat:
            @"echo 'REPAIRING:%@'; %@ -R %@ %@ && %@ -R u=rwX,go= %@ && echo 'REPAIRED:%@' || echo 'FAILED:%@'\n",
            [self shellQuote:home], chownPath, [self shellQuote:user],
            [self shellQuote:home], chmodPath, [self shellQuote:home],
            [self shellQuote:home], [self shellQuote:home]];
    }
    if (progress != NULL) {
        progress(0.0, NSLocalizedString(
                     @"Repairing home directory permissions...", nil));
    }
    __block NSUInteger reported = 0;
    [[DUAuthorizationManager sharedManager]
        streamPrivileged:@"/bin/sh"
                    args:@[ @"-c", script ]
            stdoutHandler:^(NSString *line) {
                NSString *home = nil;
                BOOL failed = NO;
                BOOL starting = NO;
                if ([line hasPrefix:@"REPAIRING:"]) {
                    home = [line substringFromIndex:10];
                    starting = YES;
                } else if ([line hasPrefix:@"REPAIRED:"]) {
                    home = [line substringFromIndex:9];
                } else if ([line hasPrefix:@"FAILED:"]) {
                    home = [line substringFromIndex:7];
                    failed = YES;
                } else {
                    return;
                }
                // Home was single-quoted in the marker; strip the quotes.
                if (home.length >= 2 && [home hasPrefix:@"'"] &&
                    [home hasSuffix:@"'"]) {
                    home = [home substringWithRange:
                                NSMakeRange(1, home.length - 2)];
                }
                if (starting) {
                    if (progress != NULL) {
                        progress((double)reported / (double)users.count,
                                 [NSString stringWithFormat:
                                     NSLocalizedString(
                                         @"Repairing permissions for %@...",
                                         nil),
                                     home]);
                    }
                    return;
                }
                reported++;
                double fraction = (double)reported / (double)users.count;
                NSString *message;
                if (failed) {
                    message = [NSString stringWithFormat:
                        NSLocalizedString(
                            @"Could not repair permissions for %@.", nil),
                        home];
                } else {
                    message = [NSString stringWithFormat:
                        NSLocalizedString(
                            @"Repaired permissions for %@.", nil),
                        home];
                }
                if (progress != NULL) {
                    progress(fraction, message);
                }
            }
            finishHandler:^(DUProcessResult *result) {
                if (progress != NULL) {
                    progress(1.0, NSLocalizedString(
                                 @"Home directory permissions repaired.", nil));
                }
                if (completion != NULL) {
                    completion(nil);
                }
            }
                    error:NULL];
}

@end

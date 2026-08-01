/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SystemActions.h"

#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>
#import <sys/utsname.h>

/* Operating systems that carry the BSD shutdown(8) command syntax. */
static BOOL SystemActionsIsBSD(NSString *system)
{
    static NSSet *bsdSet = nil;
    if (bsdSet == nil) {
        bsdSet = [[NSSet alloc] initWithObjects:
            @"FreeBSD", @"OpenBSD", @"NetBSD", @"DragonFly", @"NextBSD", nil];
    }
    return [bsdSet containsObject:system];
}

/* Whether the running Linux was booted by systemd.  Linux without systemd
 * (e.g. Devuan with sysvinit/OpenRC) must use the traditional commands, even
 * though elogind may still provide loginctl. */
static BOOL SystemActionsIsSystemd(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:@"/run/systemd/system"]) {
        return YES;
    }
    return NO;
}

/* Returns the first existing executable among the given absolute paths. */
static NSString *SystemActionsExecutable(NSArray *paths)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

@implementation SystemActions

/* The system name as reported by uname(2), e.g. "Linux", "FreeBSD". */
+ (NSString *)unameSystemName
{
    struct utsname name;
    if (uname(&name) == 0) {
        return [NSString stringWithUTF8String:name.sysname];
    }
    return nil;
}

/* Shut down / power off.  systemd Linux uses systemctl poweroff (polkit grants
 * a logged-in user the right), traditional Linux uses poweroff which the
 * Gershwin login script makes setuid root so regular users may run it, and the
 * BSDs use shutdown -p now (requires root or the operator/_shutdown group). */
+ (NSArray *)shutdownCommand
{
    NSString *system = [self unameSystemName];
    if ([system isEqualToString:@"Linux"]) {
        if (SystemActionsIsSystemd()) {
            NSString *systemctl = SystemActionsExecutable(@[@"/bin/systemctl",
                                                            @"/usr/bin/systemctl"]);
            if (systemctl) return @[systemctl, @"poweroff"];
        }
        NSString *poweroff = SystemActionsExecutable(@[@"/sbin/poweroff",
                                                       @"/usr/sbin/poweroff"]);
        if (poweroff) return @[poweroff];
    } else if (SystemActionsIsBSD(system)) {
        NSString *shutdown = SystemActionsExecutable(@[@"/sbin/shutdown",
                                                       @"/usr/sbin/shutdown"]);
        if (shutdown) return @[shutdown, @"-p", @"now"];
    }
    return nil;
}

/* Restart / reboot.  See shutdownCommand for the per-OS reasoning. */
+ (NSArray *)restartCommand
{
    NSString *system = [self unameSystemName];
    if ([system isEqualToString:@"Linux"]) {
        if (SystemActionsIsSystemd()) {
            NSString *systemctl = SystemActionsExecutable(@[@"/bin/systemctl",
                                                            @"/usr/bin/systemctl"]);
            if (systemctl) return @[systemctl, @"reboot"];
        }
        NSString *reboot = SystemActionsExecutable(@[@"/sbin/reboot",
                                                     @"/usr/sbin/reboot"]);
        if (reboot) return @[reboot];
    } else if (SystemActionsIsBSD(system)) {
        NSString *shutdown = SystemActionsExecutable(@[@"/sbin/shutdown",
                                                       @"/usr/sbin/shutdown"]);
        if (shutdown) return @[shutdown, @"-r", @"now"];
    }
    return nil;
}

/* Log out.  The Workspace is the root process of the Gershwin session
 * (Gershwin.sh ends with "exec Workspace"), so terminating it makes the
 * display manager end the session and return to the login screen on every
 * supported operating system. */
+ (NSArray *)logoutCommand
{
    NSString *pkill = SystemActionsExecutable(@[@"/usr/bin/pkill", @"/bin/pkill"]);
    if (pkill) return @[pkill, @"-TERM", @"-x", @"Workspace"];
    return nil;
}

/* Runs the command on a background queue so the menu bar keeps responding,
 * and reports failure on the main thread if it could not be executed. */
+ (void)executeCommand:(NSArray *)command failureText:(NSString *)failureText
{
    NSLog(@"SystemActions: Executing command: %@", [command componentsJoinedByString:@" "]);
    if (!command) {
        NSLog(@"SystemActions: No command available for: %@", failureText);
        [self reportFailure:failureText];
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL ok = [self runCommand:command];
        if (!ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self reportFailure:failureText];
            });
        }
    });
}

/* Launches the task and waits briefly.  A command that is still running after
 * the timeout is treated as success because the system is going down. */
+ (BOOL)runCommand:(NSArray *)command
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:[command objectAtIndex:0]];
    if ([command count] > 1) {
        [task setArguments:[command subarrayWithRange:NSMakeRange(1, [command count] - 1)]];
    }
    @try {
        [task launch];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
        while ([task isRunning] && [deadline timeIntervalSinceNow] > 0) {
            [NSThread sleepForTimeInterval:0.1];
        }
        if ([task isRunning]) {
            return YES;
        }
        return ([task terminationStatus] == 0);
    } @catch (NSException *e) {
        return NO;
    }
}

+ (void)reportFailure:(NSString *)text
{
    if ([text length] == 0) return;
    NSRunAlertPanel(NSLocalizedString(@"error", nil), text,
                    NSLocalizedString(@"OK", nil), nil, nil);
}

+ (void)executeShutdown
{
    [self executeCommand:[self shutdownCommand]
            failureText:NSLocalizedString(@"Failed to shut down the computer.", nil)];
}

+ (void)executeRestart
{
    [self executeCommand:[self restartCommand]
            failureText:NSLocalizedString(@"Failed to restart the computer.", nil)];
}

+ (void)executeLogout
{
    [self executeCommand:[self logoutCommand]
            failureText:NSLocalizedString(@"Failed to log out.", nil)];
}

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SystemActions.h"

#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>
#import <signal.h>
#import <sys/utsname.h>
#import <X11/Xlib.h>
#import <X11/Xutil.h>
#import <X11/Xatom.h>

/* How long to wait for applications to terminate gracefully before offering
 * to kill them, matching the Workspace's logout countdown. */
#define POWER_APP_TERMINATE_TIMEOUT 30.0

/* Windows in _NET_CLIENT_LIST may already be gone; ignore the error instead
 * of letting the default handler terminate the process. */
static int SystemActionsXErrorHandler(Display *display, XErrorEvent *error)
{
    (void)display;
    (void)error;
    return 0;
}

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
    /* The Workspace is the root process of the Gershwin session, so killing it
       (SIGKILL, no delay) makes the display manager end the session and return
       to the login screen immediately on every supported operating system. */
    NSString *killall = SystemActionsExecutable(@[@"/usr/bin/killall", @"/bin/killall"]);
    if (killall) return @[killall, @"-9", @"Workspace"];
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
    [self beginPowerAction:@"shutdown"];
}

+ (void)executeRestart
{
    [self beginPowerAction:@"restart"];
}

+ (void)executeLogout
{
    [self beginPowerAction:@"logout"];
}

#pragma mark - Graceful application termination

/* Before running the actual system command we ask the running GNUstep
 * applications to terminate gracefully (over their Distributed Objects
 * connection), like the Workspace does, so that unsaved work is not lost
 * when the system goes down.  Only then is the single per-OS command run. */
+ (void)beginPowerAction:(NSString *)action
{
    NSArray *apps = [self runningGNUstepApplicationsForAction:action];
    if ([apps count] == 0) {
        [self executePowerCommandForAction:action];
        return;
    }

    NSLog(@"SystemActions: Gracefully terminating %lu application(s) before %@",
          (unsigned long)[apps count], action);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        /* Only GNUstep applications (those with a reachable DO service) are
           actually asked to quit and waited on; other window owners such as
           GTK/Electron apps are left to the OS shutdown. */
        NSMutableArray *requested = [NSMutableArray array];
        for (NSDictionary *app in apps) {
            if ([self requestGracefulTermination:app]) {
                [requested addObject:app];
            }
        }
        if ([requested count] == 0) {
            [self executePowerCommandForAction:action];
            return;
        }

        NSArray *remaining = [self waitForApplicationsToExit:requested
                                                     timeout:POWER_APP_TERMINATE_TIMEOUT];
        if ([remaining count] > 0) {
            /* If the user refuses to kill the stubborn applications, abort the
               whole power action - the shutdown/restart/logout must not happen
               while an application is still running. */
            __block BOOL proceed = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                proceed = [self askToKillApplications:remaining action:action];
            });
            if (proceed) {
                for (NSDictionary *app in remaining) {
                    [self killApplication:app];
                }
                [NSThread sleepForTimeInterval:2.0];
                [self executePowerCommandForAction:action];
            } else {
                NSLog(@"SystemActions: User cancelled %@ - applications still running, not executing", action);
            }
        } else {
            [self executePowerCommandForAction:action];
        }
    });
}

/* Discovers the running applications that own visible windows and returns
 * name/pid pairs.  The Menu itself and the Workspace (the session root, which
 * must stay alive until the OS command runs or is killed at logout) are
 * excluded. */
+ (NSArray *)runningGNUstepApplicationsForAction:(NSString *)action
{
    (void)action;
    NSMutableDictionary *apps = [NSMutableDictionary dictionary]; /* name -> pid */
    Display *display = XOpenDisplay(NULL);
    if (display == NULL) {
        return @[];
    }

    /* A stale window in the client list must not crash the process. */
    XErrorHandler previousHandler = XSetErrorHandler(SystemActionsXErrorHandler);

    Atom clientListAtom = XInternAtom(display, "_NET_CLIENT_LIST", False);
    Atom pidAtom = XInternAtom(display, "_NET_WM_PID", False);
    Atom wmClassAtom = XInternAtom(display, "WM_CLASS", False);
    Atom listType, propType, pidType;
    int listFormat, propFormat, pidFormat;
    unsigned long listNitems, propNitems, pidNitems;
    unsigned long listBytesAfter, propBytesAfter, pidBytesAfter;
    unsigned char *prop = NULL;

    if (XGetWindowProperty(display, DefaultRootWindow(display), clientListAtom,
                           0, 1024, False, XA_WINDOW,
                           &listType, &listFormat, &listNitems, &listBytesAfter,
                           &prop) == 0 && prop) {
        Window *wins = (Window *)prop;
        for (unsigned long i = 0; i < listNitems; i++) {
            /* WM_CLASS is two null-terminated strings; the class (used as the
               application's DO service name) is the second one. */
            unsigned char *classProp = NULL;
            if (XGetWindowProperty(display, wins[i], wmClassAtom, 0, 32, False,
                                   XA_STRING, &propType, &propFormat, &propNitems,
                                   &propBytesAfter, &classProp) == 0
                && classProp && propFormat == 8) {
                char *p = strchr((char *)classProp, '\0');
                if (p && p[1] != '\0') {
                    NSString *name = [NSString stringWithUTF8String:p + 1];
                    unsigned char *pidProp = NULL;
                    pid_t pid = 0;
                    if (XGetWindowProperty(display, wins[i], pidAtom, 0, 1, False,
                                           XA_CARDINAL, &pidType, &pidFormat,
                                           &pidNitems, &pidBytesAfter,
                                           &pidProp) == 0 && pidProp && pidFormat == 32) {
                        pid = (pid_t)((long *)pidProp)[0];
                        XFree(pidProp);
                    }
                    if (pid > 0) {
                        [apps setObject:[NSNumber numberWithInt:(int)pid] forKey:name];
                    }
                }
                XFree(classProp);
            }
        }
        XFree(prop);
    }
    XCloseDisplay(display);
    XSetErrorHandler(previousHandler);

    /* Never terminate ourselves. */
    [apps removeObjectForKey:[[NSProcessInfo processInfo] processName]];
    [apps removeObjectForKey:@"Menu"];

    /* The Workspace is the session root; it is killed at logout and handled
       by the OS during shutdown/restart, so it is not asked to quit here. */
    [apps removeObjectForKey:@"Workspace"];

    NSMutableArray *result = [NSMutableArray array];
    for (NSString *name in apps) {
        [result addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            name, @"name",
            [apps objectForKey:name], @"pid", nil]];
    }
    return result;
}

/* Asks a GNUstep application to quit gracefully by sending terminate: over
 * its Distributed Objects connection (the same mechanism the Workspace uses).
 * Returns YES if the application's DO service was reachable, i.e. it is a
 * GNUstep application that we actually asked to quit. */
+ (BOOL)requestGracefulTermination:(NSDictionary *)app
{
    NSString *name = [app objectForKey:@"name"];
    @try {
        id proxy = [NSConnection rootProxyForConnectionWithRegisteredName:name
                                                                      host:@""];
        if (proxy) {
            NSConnection *conn = [proxy connectionForProxy];
            [conn setRequestTimeout:3.0];
            NSLog(@"SystemActions: Asking %@ to quit gracefully", name);
            [proxy terminate:nil];
            return YES;
        }
    } @catch (NSException *e) {
        NSLog(@"SystemActions: Could not ask %@ to quit gracefully: %@", name, e);
    }
    return NO;
}

/* Polls the process ids until they have exited or the timeout has elapsed.
 * Returns the applications that are still running. */
+ (NSArray *)waitForApplicationsToExit:(NSArray *)apps timeout:(NSTimeInterval)timeout
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSMutableArray *remaining = [NSMutableArray arrayWithArray:apps];
    while ([remaining count] > 0 && [deadline timeIntervalSinceNow] > 0) {
        for (NSDictionary *app in [remaining copy]) {
            pid_t pid = (pid_t)[[app objectForKey:@"pid"] intValue];
            if (pid > 0 && kill(pid, 0) != 0) {
                [remaining removeObject:app];
            }
        }
        if ([remaining count] > 0) {
            [NSThread sleepForTimeInterval:0.5];
        }
    }
    return remaining;
}

/* Asks whether the applications that refuse to terminate should be killed,
 * mirroring the Workspace's dialog.  Runs on the main thread. */
+ (BOOL)askToKillApplications:(NSArray *)apps action:(NSString *)action
{
    NSMutableString *names = [NSMutableString string];
    for (NSDictionary *app in apps) {
        if ([names length] > 0) [names appendString:@", "];
        [names appendString:[app objectForKey:@"name"]];
    }

    NSString *title = NSLocalizedString(@"Log Out", nil);
    if ([action isEqualToString:@"restart"]) title = NSLocalizedString(@"Restart", nil);
    else if ([action isEqualToString:@"shutdown"]) title = NSLocalizedString(@"Shut Down", nil);

    NSString *msg = [NSString stringWithFormat:@"%@\n%@\n%@",
        NSLocalizedString(@"The following applications:", nil),
        names,
        NSLocalizedString(@"refuse to terminate.", nil)];

    return NSRunAlertPanel(title, msg,
                           NSLocalizedString(@"Kill applications", nil),
                           NSLocalizedString(@"Cancel", nil), nil);
}

+ (void)killApplication:(NSDictionary *)app
{
    pid_t pid = (pid_t)[[app objectForKey:@"pid"] intValue];
    if (pid > 0) {
        NSLog(@"SystemActions: Killing %@ (pid %d)", [app objectForKey:@"name"], (int)pid);
        kill(pid, SIGTERM);
    }
}

+ (void)executePowerCommandForAction:(NSString *)action
{
    if ([action isEqualToString:@"shutdown"]) {
        [self executeCommand:[self shutdownCommand]
                failureText:NSLocalizedString(@"Failed to shut down the computer.", nil)];
    } else if ([action isEqualToString:@"restart"]) {
        [self executeCommand:[self restartCommand]
                failureText:NSLocalizedString(@"Failed to restart the computer.", nil)];
    } else {
        [self executeCommand:[self logoutCommand]
                failureText:NSLocalizedString(@"Failed to log out.", nil)];
    }
}

@end

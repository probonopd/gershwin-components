/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
/*
 * gershwin-session: the supervisor of one Gershwin desktop session.
 *
 * Supervises the apps given as command line arguments (their names are
 * resolved through $PATH via /usr/bin/env), restarting any of them when
 * they exit unexpectedly, so each user's desktop is self-healing.  It
 * shuts all of them down cleanly when the session manager sends
 * SIGTERM/SIGINT (e.g. on logout).
 *
 * Usage:  gershwin-session AppName1 [AppName2 ...]
 * Example: gershwin-session Workspace Menu WindowManager
 *
 * The pid of this process is exported to every supervised app as the
 * GERSHWIN_SESSION_PID environment variable, so the desktop session (Menu,
 * Workspace) can signal its own supervisor - even when, as is the common
 * case, several users are logged in at the same time and each runs their
 * own copy of this process.
 *
 * For development, automatic restarting can be toggled while the session
 * supervisor is already running:
 *   kill -USR1 <gershwin-session pid>   disable auto restart
 *   kill -USR2 <gershwin-session pid>   enable auto restart
 */
#import <Foundation/Foundation.h>
#include <signal.h>
#include <unistd.h>
#include <string.h>

static volatile sig_atomic_t keepRunning = 1;
static volatile sig_atomic_t autoRestart = 1;

static void handleSignal(int signo)
{
  (void)signo;
  if (signo == SIGTERM || signo == SIGINT)
    {
      keepRunning = 0;
    }
  else if (signo == SIGUSR1)
    {
      autoRestart = 0;
    }
  else if (signo == SIGUSR2)
    {
      autoRestart = 1;
    }
}

static void installSignalHandlers(void)
{
  struct sigaction a;

  memset(&a, 0, sizeof(a));
  sigemptyset(&a.sa_mask);
  a.sa_handler = handleSignal;
  sigaction(SIGTERM, &a, NULL);
  sigaction(SIGINT, &a, NULL);
  sigaction(SIGUSR1, &a, NULL);
  sigaction(SIGUSR2, &a, NULL);
}

static NSTask *launchApp(NSString *name)
{
  NSTask *task = [[NSTask alloc] init];

  [task setLaunchPath: @"/usr/bin/env"];
  [task setArguments: [NSArray arrayWithObject: name]];
  NSLog(@"Starting %@...", name);
  @try
    {
      [task launch];
    }
  @catch (NSException *e)
    {
      NSLog(@"Failed to launch %@: %@", name, [e reason]);
      return nil;
    }
  return task;
}

/* Stop one supervised app, SIGKILLing it if SIGTERM was not enough so
 * we never leak a half-shut-down app into the next session.
 */
static void terminateApp(NSTask *task)
{
  if (task == nil || ![task isRunning]) return;
  [task terminate]; /* SIGTERM */
  for (int i = 0; i < 20 && [task isRunning]; i++)
    {
      [NSThread sleepForTimeInterval: 0.05]; /* up to ~1s */
    }
  if ([task isRunning])
    {
      pid_t pid = [task processIdentifier];
      NSLog(@"App did not exit after SIGTERM; SIGKILLing pid %d.",
	(int)pid);
      if (pid > 0) kill(pid, SIGKILL);
      for (int i = 0; i < 20 && [task isRunning]; i++)
        {
          [NSThread sleepForTimeInterval: 0.05];
        }
    }
}

int main(int argc, const char *argv[])
{
  NSMutableArray *apps = [NSMutableArray array];
  NSMutableDictionary *tasks = [NSMutableDictionary dictionary];
  NSString *sessionPid;
  int lastAutoRestart = -1;

  if (argc < 2)
    {
      fprintf(stderr,
	"Usage: %s AppName1 [AppName2 ...]\n"
	"Supervises the named apps, restarting any that exit.\n", argv[0]);
      return 1;
    }

  /* Collect the supervised app names from the command line.  They are
   * resolved through $PATH when launched, keeping the supervisor free of
   * hardcoded installation paths.
   */
  for (int i = 1; i < argc; i++)
    {
      [apps addObject: [NSString stringWithUTF8String: argv[i]]];
    }

  /* Make our own pid discoverable by the supervised apps so they can tell
   * their own session to log out, instead of acting on another user's
   * session that happens to run the same binary names.
   */
  sessionPid = [NSString stringWithFormat: @"%d", (int)getpid()];
  setenv("GERSHWIN_SESSION_PID", [sessionPid UTF8String], 1);

  installSignalHandlers();
  NSLog(@"Gershwin session supervisor started (pid %d, display %@)."
    @" Supervising: %@. Auto restart is on; send SIGUSR1 to disable,"
    @" SIGUSR2 to enable.",
    (int)getpid(),
    [[[NSProcessInfo processInfo] environment] objectForKey: @"DISPLAY"]
    ?: @"(none)", apps);

  while (keepRunning)
    {
      @autoreleasepool
	{
	  if (lastAutoRestart != autoRestart)
	    {
	      NSLog(@"%@",
		autoRestart ? @"Auto restart ENABLED."
			    : @"Auto restart DISABLED (dev mode).");
	      lastAutoRestart = (int)autoRestart;
	    }

	  /* (Re)start anything that exited.  Ignored for apps that died
	   * while auto restart was disabled, so a developer can keep a
	   * broken instance down for debugging.
	   */
	  for (NSString *name in apps)
	    {
	      NSTask *task = [tasks objectForKey: name];

	      if (task == nil || ![task isRunning])
		{
		  if (autoRestart == 0) continue;
		  task = launchApp(name);
		  if (task != nil)
		    [tasks setObject: task forKey: name];
		}
	    }

	  if (keepRunning)
	    [NSThread sleepForTimeInterval: 0.25];
	}
    }

  NSLog(@"Shutdown signal received; terminating supervised apps.");
  for (NSString *name in apps)
    terminateApp([tasks objectForKey: name]);

  NSLog(@"G session manager exiting.");
  return 0;
}
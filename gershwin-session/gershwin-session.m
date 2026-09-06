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
 * An app that burns more than 95% CPU for over ten seconds straight is
 * treated as runaway: the supervisor kills it and the normal restart
 * logic brings a fresh copy up, so one stuck app cannot pin a core and
 * freeze the whole desktop.
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
#include <stdio.h>
#include <time.h>

/* A supervised app counts as runaway when its CPU time grows faster than
 * CPU_RUNAWAY_RATE cores continuously for longer than CPU_RUNAWAY_SECONDS.
 */
#define CPU_RUNAWAY_RATE    0.95
#define CPU_RUNAWAY_SECONDS 10.0

/* Per-app watchdog state, one entry per supervised app (same order). */
typedef struct {
  double lastCpu;   /* cumulative CPU seconds at last sample, -1 = unknown */
  double lastAt;    /* monotonic time of that sample */
  double highSince; /* when the current >limit streak started, 0 = none */
} CpuWatch;

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

/* The environment every supervised app is launched with.  It is the
 * supervisor's own environment plus GERSHWIN_SESSION_PID, which tells each
 * supervised app the pid of its own session supervisor so it can signal it
 * (e.g. to log out).  We must pass this explicitly via -setEnvironment:
 * because GNUstep's NSTask snapshots the environment at process startup and
 * does not pick up variables added later with setenv(); without this, the
 * child would see an empty GERSHWIN_SESSION_PID and could not address its
 * supervisor. */
static NSDictionary *supervisedEnvironment(void)
{
  NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
  if (env == nil) env = [NSMutableDictionary dictionary];
  [env setObject: [NSString stringWithFormat: @"%d", (int)getpid()]
           forKey: @"GERSHWIN_SESSION_PID"];
  return env;
}

static NSTask *launchApp(NSString *name)
{
  NSTask *task = [[NSTask alloc] init];

  [task setLaunchPath: @"/usr/bin/env"];
  [task setArguments: [NSArray arrayWithObject: name]];
  [task setEnvironment: supervisedEnvironment()];
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
  pid_t pid = [task processIdentifier];
  if (pid <= 0) return;

  /* Regular kill (SIGTERM) first, so the app can shut down cleanly. */
  kill(pid, SIGTERM);
  for (int i = 0; i < 20 && [task isRunning]; i++)
    {
      [NSThread sleepForTimeInterval: 0.05]; /* up to ~1s */
    }

  /* If a plain kill did not do it, force it with SIGKILL (kill -9) so we
   * never leak a half-shut-down app into the next session. */
  if ([task isRunning])
    {
      NSLog(@"App did not exit after SIGTERM; SIGKILLing pid %d.",
	    (int)pid);
      kill(pid, SIGKILL);
      for (int i = 0; i < 20 && [task isRunning]; i++)
        {
          [NSThread sleepForTimeInterval: 0.05];
        }
    }
}

static double monotonicSeconds(void)
{
  struct timespec ts;

  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* Parse a ps TIME/cputime value.  The column layout differs between
 * Linux ("[[dd-]hh:]mm:ss") and the BSDs ("mmm:ss.hh"), so parse colon
 * separated fields from the right as seconds/minutes/hours and accept an
 * optional fractional part on the last field.
 */
static double parsePsTime(char *s)
{
  double mult[] = { 1.0, 60.0, 3600.0, 86400.0 };
  double fields[5] = { 0 };
  double days = 0.0;
  char *dash = strchr(s, '-');
  char *tok;
  int nf = 0;
  double secs = 0.0;
  int i;

  if (dash != NULL)
    {
      *dash = '\0';
      days = atof(s);
      s = dash + 1;
    }
  while ((tok = strsep(&s, ":")) != NULL && nf < 5)
    {
      fields[nf++] = atof(tok);
    }
  for (i = 0; i < nf; i++)
    {
      secs += fields[nf - 1 - i] * mult[i];
    }
  return days * 86400.0 + secs;
}

/* Cumulative CPU seconds used by pid, or -1 if it cannot be determined.
 * We go through ps rather than /proc so this works identically on Linux,
 * FreeBSD and OpenBSD.
 */
static double cpuSecondsForPid(pid_t pid)
{
  char cmd[64];
  char line[256];
  FILE *fp;
  double secs = -1.0;

  snprintf(cmd, sizeof(cmd), "ps -o cputime= -p %d", (int)pid);
  fp = popen(cmd, "r");
  if (fp == NULL) return -1.0;
  if (fgets(line, sizeof(line), fp) != NULL)
    {
      secs = parsePsTime(line);
    }
  pclose(fp);
  return secs;
}

/* Kill any supervised app that has been above the CPU limit for over
 * CPU_RUNAWAY_SECONDS straight; killing hands it to the normal restart
 * logic, which brings a fresh copy up.  Samples once per second: shorter
 * windows would fork ps four times as often for no better decision.
 */
static void watchForRunawayApps(NSArray *apps, NSMutableDictionary *tasks,
  CpuWatch *watches)
{
  static double nextSampleAt = 0;
  double now = monotonicSeconds();
  NSUInteger i;

  if (now < nextSampleAt) return;
  nextSampleAt = now + 1.0;

  for (i = 0; i < [apps count]; i++)
    {
      NSString *name = [apps objectAtIndex: i];
      NSTask *task = [tasks objectForKey: name];
      CpuWatch *w = &watches[i];
      pid_t pid;
      double cpu, dt, rate;

      if (task == nil || ![task isRunning])
        {
          w->lastCpu = -1.0;
          w->highSince = 0.0;
          continue;
        }

      pid = [task processIdentifier];
      cpu = cpuSecondsForPid(pid);
      if (cpu < 0.0 || w->lastCpu < 0.0)
        {
          w->lastCpu = cpu;
          w->lastAt = now;
          continue;
        }

      dt = now - w->lastAt;
      rate = dt > 0.0 ? (cpu - w->lastCpu) / dt : 0.0;
      w->lastCpu = cpu;
      w->lastAt = now;

      if (rate > CPU_RUNAWAY_RATE)
        {
          if (w->highSince == 0.0)
            {
              w->highSince = now;
            }
          else if (now - w->highSince >= CPU_RUNAWAY_SECONDS)
            {
              NSLog(@"%@ (pid %d) has been using more than %.0f%% CPU"
                @" for over %.0f seconds; restarting it.",
                name, (int)pid, CPU_RUNAWAY_RATE * 100,
                CPU_RUNAWAY_SECONDS);
              terminateApp(task);
              w->lastCpu = -1.0;
              w->highSince = 0.0;
            }
        }
      else
        {
          w->highSince = 0.0;
        }
    }
}

int main(int argc, const char *argv[])
{
  NSMutableArray *apps = [NSMutableArray array];
  NSMutableDictionary *tasks = [NSMutableDictionary dictionary];
  CpuWatch *watches;
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
  watches = calloc([apps count], sizeof(CpuWatch));
  if (watches == NULL)
    {
      fprintf(stderr, "%s: out of memory\n", argv[0]);
      return 1;
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

	  watchForRunawayApps(apps, tasks, watches);

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
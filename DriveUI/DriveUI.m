/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* DriveUI - a tiny, DO-free UI snapshot server bundled into every GNUstep app.
 *
 * The socket server exposes ONLY read-only UI information (the widget tree and
 * widget text values) as fast tab-separated lines over a per-PID Unix-domain
 * socket - no DO, no JSON.  Driving (clicks, key presses, typing) is NOT done
 * here: it is simulated at the X11 level by the drive_ui command-line tool,
 * which resolves the widget's on-screen position from this snapshot and sends
 * real pointer/key events.  This keeps the host app side purely observational,
 * so nothing in it can wedge a modal loop or mis-trigger a GNUstep action.
 *
 * Loading: GNUstep GUI reads the GSAppKitUserBundles user default at NSApp
 * init and instantiates the principal class of each listed bundle.  Pointing
 * that default at this bundle makes every GUI app host a DriveUI server
 * without any per-app code.  The socket lives at
 * /tmp/driveui.<pid>.sock so drive_ui can target one app.
 *
 * Protocol: the client connects and sends one command line (fields separated
 * by tabs):
 *
 *   full                      -> whole tree, one line per item
 *   get <object_id>           -> the text/title/string of one widget
 *
 * Snapshot fields (tab-separated): depth, class, text, tag, frame,
 * screen_frame, hidden, object_id.  `text` is the displayed (localized)
 * title/stringValue, so drive_ui can find widgets by their on-screen label and
 * then act on the id via X11 at the reported screen_frame.
 *
 * Robustness: the socket server runs on a dedicated background thread that
 * NEVER blocks on the main thread.  Each connection is packaged into a small
 * object and posted to the main thread (waitUntilDone:NO); the main thread
 * writes the reply and closes the connection itself.  Reads have a timeout,
 * every main-thread handler is wrapped in @try/@catch so a bad request can
 * never leave the app's main thread wedged, and SIGPIPE is ignored so writing
 * to a vanished client cannot kill the app.  A wedged, hanging, or crashing
 * client therefore never hangs or crashes the host application, and one slow
 * connection cannot stall the server thread (it keeps accepting new ones).
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/poll.h>
#import <signal.h>
#import <unistd.h>

#define DRIVEUI_READ_TIMEOUT_MS 5000

/* One pending client connection.  Posted to the main thread for servicing;
 * the main thread writes the reply and closes the fd. */
@interface DriveUIConnection : NSObject
{
  int _fd;
  NSArray *_args;
}
- (id)initWithFD:(int)fd args:(NSArray *)args;
- (int)fd;
- (NSArray *)args;
@end

@implementation DriveUIConnection

- (id)initWithFD:(int)fd args:(NSArray *)args
{
  self = [super init];
  if (self)
    {
      _fd = fd;
      _args = [args copy];
    }
  return self;
}

- (void)dealloc
{
  [_args release];
  [super dealloc];
}

- (int)fd { return _fd; }
- (NSArray *)args { return _args; }

@end

@interface DriveUI : NSObject
{
  NSArray *_snapshot;
}
- (void)serverLoop:(id)unused;
- (void)serviceConnection:(DriveUIConnection *)conn;
- (void)buildSnapshot:(id)unused;
- (NSString *)textOfObject:(NSString *)objID;
- (NSArray *)collectSnapshot;
- (void)addWindow:(NSWindow *)win depth:(int)depth into:(NSMutableArray *)items;
- (void)addView:(NSView *)view depth:(int)depth into:(NSMutableArray *)items;
- (NSString *)objectIDForObject:(id)obj;
- (id)objectForID:(NSString *)objID;
- (NSString *)snapshotLines;
@end

@implementation DriveUI

- (id)init
{
  self = [super init];
  if (self)
    {
      /* Writing to a socket whose client has gone away must not raise
       * SIGPIPE and kill the app. */
      signal(SIGPIPE, SIG_IGN);
      [NSThread detachNewThreadSelector: @selector(serverLoop:)
                               toTarget: self
                             withObject: nil];
    }
  return self;
}

- (void)dealloc
{
  [_snapshot release];
  [super dealloc];
}

/* ---- socket helpers ---- */

static void WriteAll(int fd, const char *bytes)
{
  size_t len = strlen(bytes);
  size_t off = 0;
  while (off < len)
    {
      ssize_t w = write(fd, bytes + off, len - off);
      if (w <= 0) break;
      off += (size_t)w;
    }
}

/* ---- socket server (background thread) ---- */

- (void)serverLoop:(id)unused
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  pid_t pid = [[NSProcessInfo processInfo] processIdentifier];
  NSString *sockPath = [NSString stringWithFormat: @"/tmp/driveui.%d.sock", pid];

  unlink([sockPath UTF8String]);

  int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (lfd < 0)
    {
      [pool release];
      return;
    }

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, [sockPath UTF8String], sizeof(addr.sun_path) - 1);

  if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0
      || listen(lfd, 8) < 0)
    {
      close(lfd);
      [pool release];
      return;
    }
  chmod([sockPath UTF8String], 0666);

  for (;;)
    {
      NSAutoreleasePool *cpool = [[NSAutoreleasePool alloc] init];

      int cfd = accept(lfd, NULL, NULL);
      if (cfd < 0)
        {
          [cpool release];
          continue;
        }

      /* Wait for the command line with a timeout, so a client that connects
       * and sends nothing cannot block this thread forever. */
      struct pollfd pfd;
      pfd.fd = cfd;
      pfd.events = POLLIN;
      int pr = poll(&pfd, 1, DRIVEUI_READ_TIMEOUT_MS);

      if (pr > 0)
        {
          char buf[16384];
          ssize_t n = read(cfd, buf, sizeof(buf) - 1);
          if (n > 0)
            {
              buf[n] = 0;
              NSString *line = [NSString stringWithUTF8String: buf];
              NSArray *lines = [line componentsSeparatedByString: @"\n"];
              NSString *cmdline = [lines count] > 0 ? [lines objectAtIndex: 0] : @"";
              NSArray *args = [cmdline componentsSeparatedByString: @"\t"];

              /* Package the connection and ask the main thread to service it.
               * waitUntilDone:NO means the server thread never blocks: the
               * main thread owns the fd from here on, writes the reply, and
               * closes it.  If the main thread is momentarily busy, the
               * client just waits - the server thread keeps accepting.
               *
               * Post in the modal + event-tracking modes as well as the
               * default one: a modal dialog (e.g. Go To Folder) runs the main
               * run loop in NSModalPanelRunLoopMode, and the default
               * performSelectorOnMainThread: only covers NSDefaultRunLoopMode
               * + NSConnectionReplyMode, so the connection would never be
               * serviced while a modal is up. */
              DriveUIConnection *conn =
                [[[DriveUIConnection alloc] initWithFD: cfd args: args] autorelease];
              [self performSelectorOnMainThread: @selector(serviceConnection:)
                                     withObject: conn
                                  waitUntilDone: NO
                                          modes: [NSArray arrayWithObjects:
                                                   NSDefaultRunLoopMode,
                                                   NSModalPanelRunLoopMode,
                                                   NSEventTrackingRunLoopMode,
                                                   nil]];
              [cpool release];
              continue;  /* main thread owns cfd from here on */
            }
        }

      close(cfd);
      [cpool release];
    }

  close(lfd);
  [pool release];
}

/* ---- connection servicing (main thread) ---- */

- (void)serviceConnection:(DriveUIConnection *)conn
{
  NSAutoreleasePool *cpool = [[NSAutoreleasePool alloc] init];

  int fd = [conn fd];
  NSArray *parts = [conn args];

  if (fd >= 0)
    {
      @try
        {
          NSString *cmd = ([parts count] > 0) ? [parts objectAtIndex: 0] : @"";

          if ([cmd isEqualToString: @"full"])
            {
              [self buildSnapshot: nil];
              NSString *lines = [self snapshotLines];
              if (lines) WriteAll(fd, [lines UTF8String]);
            }
          else if ([cmd isEqualToString: @"get"])
            {
              NSString *objID = ([parts count] > 1) ? [parts objectAtIndex: 1] : nil;
              NSString *text = [self textOfObject: objID];
              if (text == nil) text = @"error:no object";
              NSString *reply = [text stringByAppendingString: @"\n"];
              WriteAll(fd, [reply UTF8String]);
            }
          else
            {
              NSString *err = [NSString stringWithFormat: @"error:unknown command %@\n", cmd];
              WriteAll(fd, [err UTF8String]);
            }
        }
      @catch (NSException *e)
        {
          NSString *err = [NSString stringWithFormat: @"error:exception %@\n", e];
          WriteAll(fd, [err UTF8String]);
        }
      @finally
        {
          close(fd);
        }
    }

  [cpool release];
}

/* ---- text readout (main thread) ---- */

- (NSString *)textOfObject:(NSString *)objID
{
  id obj = [self objectForID: objID];
  if (obj == nil) return nil;

  @try {
    if ([obj isKindOfClass: [NSTextField class]]) {
      return [(NSTextField *)obj stringValue] ?: @"";
    }
    if ([obj isKindOfClass: [NSTextView class]]) {
      return [(NSTextView *)obj string] ?: @"";
    }
    if ([obj respondsToSelector: @selector(stringValue)]) {
      id s = [obj performSelector: @selector(stringValue)];
      if (s && [s isKindOfClass: [NSString class]]) return s;
    }
    if ([obj respondsToSelector: @selector(title)]) {
      id t = [obj performSelector: @selector(title)];
      if (t && [t isKindOfClass: [NSString class]]) return t;
    }
  } @catch (NSException *e) { }

  return @"";
}

/* ---- snapshot builder (main thread) ---- */

- (void)buildSnapshot:(id)unused
{
  NSArray *fresh = [self collectSnapshot];
  [_snapshot release];
  _snapshot = [fresh retain];
}

- (NSArray *)collectSnapshot
{
  NSMutableArray *items = [NSMutableArray array];

  @try
    {
      [items addObject: [self itemForApp]];

      for (NSWindow *win in [NSApp windows])
        {
          [self addWindow: win depth: 1 into: items];
        }
    }
  @catch (NSException *e)
    {
      /* Never let a bad view take down the snapshot. */
    }

  return items;
}

- (NSArray *)itemForApp
{
  return [NSArray arrayWithObjects:
            [NSNumber numberWithInt: 0],
            @"NSApplication",
            @"",
            @"",
            @"",
            @"",
            @"0",
            [self objectIDForObject: NSApp],
            nil];
}

- (void)addWindow:(NSWindow *)win depth:(int)depth into:(NSMutableArray *)items
{
  @try
    {
      [items addObject: [NSArray arrayWithObjects:
                          [NSNumber numberWithInt: depth],
                          NSStringFromClass([win class]),
                          [win title] ?: @"",
                          @"",
                          NSStringFromRect([win frame]),
                          @"",
                          [NSNumber numberWithInt: [win isVisible] ? 0 : 1],
                          [self objectIDForObject: win],
                          nil]];

      [self addView: [win contentView] depth: depth + 1 into: items];
    }
  @catch (NSException *e) { }
}

- (void)addView:(NSView *)view depth:(int)depth into:(NSMutableArray *)items
{
  if (view == nil) return;

  @try
    {
      NSString *text = @"";
      if ([view isKindOfClass: [NSTextField class]]) {
        text = [(NSTextField *)view stringValue] ?: @"";
      } else if ([view respondsToSelector: @selector(title)]) {
        id t = [view performSelector: @selector(title)];
        if (t && [t isKindOfClass: [NSString class]] && [t length] > 0) text = t;
      } else if ([view respondsToSelector: @selector(stringValue)]) {
        id s = [view performSelector: @selector(stringValue)];
        if (s && [s isKindOfClass: [NSString class]]) text = s;
      }

      NSString *screenFrame = @"";
      NSWindow *w = [view window];
      if (w) {
        NSRect sf = [w convertRectToScreen: [view convertRect: [view bounds] toView: nil]];
        screenFrame = NSStringFromRect(sf);
      }

      [items addObject: [NSArray arrayWithObjects:
                          [NSNumber numberWithInt: depth],
                          NSStringFromClass([view class]),
                          text,
                          [NSNumber numberWithInt: [view isKindOfClass: [NSControl class]]
                                               ? (int)[(NSControl *)view tag] : 0],
                          NSStringFromRect([view frame]),
                          screenFrame,
                          [NSNumber numberWithInt: [view isHidden] ? 1 : 0],
                          [self objectIDForObject: view],
                          nil]];

      for (NSView *sub in [view subviews])
        {
          [self addView: sub depth: depth + 1 into: items];
        }
    }
  @catch (NSException *e) { }
}

- (NSString *)objectIDForObject:(id)obj
{
  return obj ? [NSString stringWithFormat: @"objc:%p", obj] : @"-";
}

- (id)objectForID:(NSString *)objID
{
  if (objID == nil || ![objID hasPrefix: @"objc:"]) return nil;
  unsigned long long ptrVal;
  NSScanner *scanner = [NSScanner scannerWithString: [objID substringFromIndex: 5]];
  if ([scanner scanHexLongLong: &ptrVal])
    return (__bridge id)(void *)ptrVal;
  return nil;
}

- (NSString *)snapshotLines
{
  NSMutableString *out = [NSMutableString string];
  for (NSArray *row in _snapshot)
    {
      [out appendFormat: @"%d\t%@\t%@\t%@\t%@\t%@\t%@\t%@\n",
         [[row objectAtIndex: 0] intValue],
         [row objectAtIndex: 1],
         [row objectAtIndex: 2],
         [row objectAtIndex: 3],
         [row objectAtIndex: 4],
         [row objectAtIndex: 5],
         [row objectAtIndex: 6],
         [row objectAtIndex: 7]];
    }
  return out;
}

@end

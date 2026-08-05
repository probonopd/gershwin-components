/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* drive_ui - fast UI-tree inspection and driving CLI.
 *
 * Inspection comes from the DriveUI.bundle socket server (a per-PID
 * Unix-domain socket at /tmp/driveui.<pid>.sock): the widget tree is served
 * as one tab-separated line per item.  Driving (clicks, typing, pressing
 * Return) is done by simulating REAL X11 pointer and key events at the
 * widget's on-screen position - never by calling ObjC methods on the app - so
 * modal dialogs, key equivalents and text fields behave exactly as if a user
 * operated them, regardless of language.
 *
 *   drive_ui [--pid N] get_full_tree
 *   drive_ui [--pid N] find_widgets [--class C] [--text T] [--tag N] [--visible]
 *   drive_ui [--pid N] click <object_id> | --text <label> [--class C]
 *   drive_ui [--pid N] doubleclick <object_id> | --text <label> [--class C]
 *   drive_ui [--pid N] rightclick <object_id> | --text <label> [--class C]
 *   drive_ui [--pid N] type <object_id> <text> | --text <label> <text> [--class C]
 *   drive_ui [--pid N] sendkeys <text>          (type into the focused field)
 *   drive_ui [--pid N] clear <object_id> | --text <label> [--class C]
 *   drive_ui [--pid N] focus <object_id> | --text <label> [--class C]
 *   drive_ui [--pid N] get <object_id> | --text <label> [--class C]
 *   drive_ui [--pid N] app                     (read-only: app name)
 *   drive_ui [--pid N] props <object_id>        (read-only: enabled/state)
 *   drive_ui [--pid N] menu                    (read-only: main menu tree)
 *   drive_ui [--pid N] menu_invoke <i0> <i1>.. (perform menu action by index)
 *   drive_ui [--pid N] localize <english>       (translate to app language)
 *   drive_ui [--pid N] press                     (press Return)
 *   drive_ui [--pid N] chord <mods> <key>        (e.g. chord control c)
 *
 * Snapshot fields: depth  class  text  tag  frame  screen_frame  hidden  object_id
 *
 * Because `text` is the displayed (localized) title/stringValue, widgets can be
 * located by their on-screen label; the driving commands then act at that
 * widget's screen position, so they work on any language.  `menu` + `menu_invoke`
 * resolve and trigger menu items in-process on the app (fast, localization-safe);
 * `localize` maps an English string to the app's current language so script
 * titles can be written in English for any locale.
 */

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/poll.h>
#import <unistd.h>
#import "X11Support.h"

#define DRIVE_UI_TOOL_TIMEOUT_MS 10000

static int ConnectToPid(int pid)
{
  NSString *path = [NSString stringWithFormat: @"/tmp/driveui.%d.sock", pid];
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, [path UTF8String], sizeof(addr.sun_path) - 1);

  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
    {
      close(fd);
      return -1;
    }
  return fd;
}

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

static NSString *ReadAll(int fd)
{
  NSMutableData *data = [NSMutableData data];
  char buf[4096];
  for (;;)
    {
      struct pollfd pfd;
      pfd.fd = fd;
      pfd.events = POLLIN;
      int pr = poll(&pfd, 1, DRIVE_UI_TOOL_TIMEOUT_MS);
      if (pr <= 0) break;
      ssize_t n = read(fd, buf, sizeof(buf));
      if (n <= 0) break;
      [data appendBytes: buf length: (NSUInteger)n];
    }
  return [[[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding] autorelease];
}

/* Send a command line to the app and return the raw reply. */
static NSString *SendCommand(int pid, NSString *cmdline)
{
  int fd = ConnectToPid(pid);
  if (fd < 0)
    {
      fprintf(stderr, "drive_ui: no DriveUI socket for pid=%d (is DriveUI.bundle loaded?)\n", pid);
      return nil;
    }
  NSString *line = [cmdline stringByAppendingString: @"\n"];
  WriteAll(fd, [line UTF8String]);
  NSString *reply = ReadAll(fd);
  close(fd);
  return reply;
}

static NSString *FetchTree(int pid)
{
  return SendCommand(pid, @"full");
}

static NSArray *ParseTree(NSString *out)
{
  NSMutableArray *rows = [NSMutableArray array];
  if (!out) return rows;
  for (NSString *line in [out componentsSeparatedByString: @"\n"])
    {
      if ([line length] == 0) continue;
      [rows addObject: [line componentsSeparatedByString: @"\t"]];
    }
  return rows;
}

static void PrintRow(NSArray *f)
{
  NSMutableString *s = [NSMutableString string];
  for (NSUInteger i = 0; i < [f count]; i++)
    {
      if (i > 0) [s appendString: @"\t"];
      [s appendString: [f objectAtIndex: i]];
    }
  printf("%s\n", [s UTF8String]);
}

static void PrintMatching(NSString *out, NSString *wantClass, NSString *wantText,
                          NSNumber *wantTag, BOOL wantVisible)
{
  for (NSArray *f in ParseTree(out))
    {
      if ([f count] < 8) continue;
      NSString *cls = [f objectAtIndex: 1];
      NSString *text = [f objectAtIndex: 2];
      NSString *tagStr = [f objectAtIndex: 3];
      NSString *hiddenStr = [f objectAtIndex: 6];

      if (wantVisible && [hiddenStr isEqualToString: @"1"]) continue;
      if (wantClass && [cls rangeOfString: wantClass options: NSCaseInsensitiveSearch].location == NSNotFound) continue;
      if (wantText && [text rangeOfString: wantText options: NSCaseInsensitiveSearch].location == NSNotFound) continue;
      if (wantTag && [tagStr intValue] != [wantTag intValue]) continue;

      PrintRow(f);
    }
}

/* Resolve a widget to a row by (optionally class-scoped) localized text. */
static NSArray *ResolveRow(NSArray *rows, NSString *wantClass, NSString *wantText, BOOL wantVisible)
{
  if (!wantText) return nil;
  for (NSArray *f in rows)
    {
      if ([f count] < 8) continue;
      NSString *cls = [f objectAtIndex: 1];
      NSString *text = [f objectAtIndex: 2];
      NSString *hiddenStr = [f objectAtIndex: 6];
      if (wantVisible && [hiddenStr isEqualToString: @"1"]) continue;
      if (wantClass && [cls rangeOfString: wantClass options: NSCaseInsensitiveSearch].location == NSNotFound) continue;
      if ([text rangeOfString: wantText options: NSCaseInsensitiveSearch].location == NSNotFound) continue;
      return f;
    }
  return nil;
}

/* Resolve a widget row by object_id. */
static NSArray *ResolveRowByID(NSArray *rows, NSString *objID)
{
  if (!objID) return nil;
  for (NSArray *f in rows)
    {
      if ([f count] < 8) continue;
      if ([[f objectAtIndex: 7] isEqualToString: objID]) return f;
    }
  return nil;
}

/* Given a snapshot row, return the center of its screen_frame (used for
 * clicking/typing), or NSZeroPoint if unavailable. */
static NSPoint CenterOfRow(NSArray *f)
{
  if ([f count] < 6) return NSZeroPoint;
  NSString *sf = [f objectAtIndex: 5];
  if ([sf length] == 0) return NSZeroPoint;
  NSRect r = NSRectFromString(sf);
  if (r.size.width <= 0 || r.size.height <= 0) return NSZeroPoint;
  return NSMakePoint(NSMidX(r), NSMidY(r));
}

static void Usage(void)
{
  printf("Usage:\n");
  printf("  drive_ui [--pid N] get_full_tree\n");
  printf("  drive_ui [--pid N] find_widgets [--class C] [--text T] [--tag N] [--visible]\n");
  printf("  drive_ui [--pid N] click <object_id> | --text <label> [--class C]\n");
  printf("  drive_ui [--pid N] doubleclick <object_id> | --text <label> [--class C]\n");
  printf("  drive_ui [--pid N] rightclick <object_id> | --text <label> [--class C]\n");
  printf("  drive_ui [--pid N] type <object_id> <text> | --text <label> <text> [--class C]\n");
  printf("  drive_ui [--pid N] sendkeys <text>          (type into focused field)\n");
  printf("  drive_ui [--pid N] clear <object_id> | --text <label> [--class C]\n");
  printf("  drive_ui [--pid N] focus <object_id> | --text <label> [--class C]\n");
  printf("  drive_ui [--pid N] get <object_id> | --text <label> [--class C]\n");
  printf("  drive_ui [--pid N] app                       (read-only: app name)\n");
  printf("  drive_ui [--pid N] props <object_id>          (read-only: props)\n");
  printf("  drive_ui [--pid N] menu                       (read-only: main menu tree)\n");
  printf("  drive_ui [--pid N] menu_invoke <i0> <i1> ...  (perform menu action by index)\n");
  printf("  drive_ui [--pid N] localize <english>          (translate to app language)\n");
  printf("  drive_ui [--pid N] press                     (press Return)\n");
  printf("  drive_ui [--pid N] chord <mods> <key>        (e.g. chord control c)\n");
  printf("Snapshot: depth\\tclass\\ttext\\ttag\\tframe\\tscreen_frame\\thidden\\tobject_id\n");
  printf("Actions simulate real X11 pointer/key events at the widget position,\n");
  printf("so they work on localized UIs and in modal dialogs.\n");
}

int main(int argc, const char *argv[])
{
  setenv("GNUSTEP_SYSTEM_ROOT", "/System", 1);
  setenv("GNUSTEP_LOCAL_ROOT", "/Local", 1);
  setenv("GNUSTEP_NETWORK_ROOT", "/Network", 1);
  const char *ldpath = getenv("LD_LIBRARY_PATH");
  NSString *ldpathStr = ldpath ? [NSString stringWithUTF8String: ldpath] : @"";
  NSMutableArray *parts = [NSMutableArray arrayWithObjects: @"/System/Library/Libraries", @"/Local/Library/Libraries", nil];
  if ([ldpathStr length] > 0) [parts addObject: ldpathStr];
  setenv("LD_LIBRARY_PATH", [[parts componentsJoinedByString: @":"] UTF8String], 1);
  setbuf(stdout, NULL);

  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  int pid = 0;
  NSMutableArray *args = [NSMutableArray array];
  for (int i = 1; i < argc; i++)
    {
      NSString *arg = [NSString stringWithUTF8String: argv[i]];
      if ([arg isEqualToString: @"--pid"] && i + 1 < argc)
        pid = atoi(argv[++i]);
      else if ([arg hasPrefix: @"--pid="])
        pid = atoi([arg UTF8String] + 6);
      else
        [args addObject: arg];
    }

  if ([args count] == 0)
    {
      Usage();
      [pool release];
      return 1;
    }

  NSString *command = [args objectAtIndex: 0];

  NSString *wantClass = nil, *wantText = nil, *idArg = nil;
  NSNumber *wantTag = nil;
  BOOL wantVisible = NO;

  for (NSUInteger i = 1; i < [args count]; i++)
    {
      NSString *a = [args objectAtIndex: i];
      if ([a isEqualToString: @"--class"] && i + 1 < [args count]) wantClass = [args objectAtIndex: ++i];
      else if ([a isEqualToString: @"--text"] && i + 1 < [args count]) wantText = [args objectAtIndex: ++i];
      else if ([a isEqualToString: @"--tag"] && i + 1 < [args count]) wantTag = @(atoi([(NSString *)[args objectAtIndex: ++i] UTF8String]));
      else if ([a isEqualToString: @"--visible"]) wantVisible = YES;
      else if ([a hasPrefix: @"objc:"]) idArg = a;
    }

  if ([command isEqualToString: @"get_full_tree"])
    {
      NSString *tree = FetchTree(pid);
      if (tree) printf("%s", [tree UTF8String]);
    }
  else if ([command isEqualToString: @"find_widgets"])
    {
      if (!wantClass && !wantText && !wantTag && !wantVisible)
        {
          fprintf(stderr, "drive_ui: find_widgets needs --class, --text, --tag or --visible\n");
          [pool release];
          return 1;
        }
      NSString *tree = FetchTree(pid);
      PrintMatching(tree, wantClass, wantText, wantTag, wantVisible);
    }
  else if ([command isEqualToString: @"get"])
    {
      /* get is read-only: ask the bundle for the widget's current text. */
      NSString *target = idArg;
      if (target == nil)
        {
          if (wantText == nil)
            {
              fprintf(stderr, "drive_ui: get needs <object_id> or --text <label>\n");
              [pool release];
              return 1;
            }
          NSString *tree = FetchTree(pid);
          NSArray *row = ResolveRow(ParseTree(tree), wantClass, wantText, wantVisible);
          if (row == nil)
            {
              fprintf(stderr, "drive_ui: no widget matching text '%s'\n", [wantText UTF8String]);
              [pool release];
              return 1;
            }
          target = [row objectAtIndex: 7];
        }
      NSString *reply = SendCommand(pid, [NSString stringWithFormat: @"get\t%@", target]);
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"app"])
    {
      /* Read-only: return the app name the snapshot belongs to. */
      NSString *reply = SendCommand(pid, @"app");
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"props"])
    {
      /* Read-only: return enabled/state/hidden of an object. */
      if (idArg == nil)
        {
          fprintf(stderr, "drive_ui: props needs <object_id>\n");
          [pool release];
          return 1;
        }
      NSString *reply = SendCommand(pid, [NSString stringWithFormat: @"props\t%@", idArg]);
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"menu"])
    {
      /* Read-only: dump the app's main menu tree
       * (depth\tindex\ttitle\tenabled\thas_submenu). */
      NSString *reply = SendCommand(pid, @"menu");
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"menu_invoke"])
    {
      /* menu_invoke <i0> <i1> ... - perform the leaf menu item's action
       * in-process by index path; the bundle replies "ok" or "error:...". */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      if ([positionals count] == 0)
        {
          fprintf(stderr, "drive_ui: menu_invoke needs at least one index\n");
          [pool release];
          return 1;
        }
      NSMutableArray *tokens = [NSMutableArray arrayWithObject: @"menu_invoke"];
      [tokens addObjectsFromArray: positionals];
      NSString *reply = SendCommand(pid, [tokens componentsJoinedByString: @"\t"]);
      if (reply)
        {
          printf("%s", [reply UTF8String]);
          if ([reply hasPrefix: @"error:"])
            {
              [pool release];
              return 1;
            }
        }
    }
  else if ([command isEqualToString: @"localize"])
    {
      /* Read-only: translate an English string to the app's current language. */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      NSString *key = ([positionals count] > 0) ? [positionals objectAtIndex: 0] : nil;
      if (key == nil)
        {
          fprintf(stderr, "drive_ui: localize needs a string\n");
          [pool release];
          return 1;
        }
      NSString *reply = SendCommand(pid, [NSString stringWithFormat: @"localize\t%@", key]);
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"click"] || [command isEqualToString: @"focus"]
           || [command isEqualToString: @"doubleclick"] || [command isEqualToString: @"rightclick"])
    {
      /* Resolve the widget's screen position and click there with the real
       * X11 pointer - the app receives genuine mouse events, so this works in
       * modal dialogs and on any widget. */
      int button = ([command isEqualToString: @"rightclick"]) ? 3 : 1;
      int count = ([command isEqualToString: @"doubleclick"]) ? 2 : 1;

      NSArray *treeRows = ParseTree(FetchTree(pid));
      NSArray *row = nil;

      if (idArg)
        row = ResolveRowByID(treeRows, idArg);
      else if (wantText)
        row = ResolveRow(treeRows, wantClass, wantText, YES);

      if (row == nil)
        {
          fprintf(stderr, "drive_ui: %s: widget not found (object_id or --text)\n", [command UTF8String]);
          [pool release];
          return 1;
        }

      NSPoint c = CenterOfRow(row);
      if (c.x == 0 && c.y == 0)
        {
          fprintf(stderr, "drive_ui: %s: widget has no usable screen_frame\n", [command UTF8String]);
          [pool release];
          return 1;
        }

      [X11Support simulateMouseMoveTo: c];
      usleep(50000);  /* let the pointer motion settle */
      for (int i = 0; i < count; i++)
        {
          [X11Support simulateClick: button];
          if (count > 1) usleep(60000);  /* let a double-click register as such */
        }
    }
  else if ([command isEqualToString: @"press"])
    {
      /* Press Return via a real X11 key event. */
      [X11Support simulateChordWithModifiers: [NSArray array] key: @"Return"];
    }
  else if ([command isEqualToString: @"sendkeys"])
    {
      /* sendkeys <text> - type text into the currently focused field without
       * clicking first (used by drive_dsl `type "..."`, which types into the
       * focused editable control). */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      NSString *value = ([positionals count] > 0) ? [positionals objectAtIndex: 0] : nil;
      if (value == nil)
        {
          fprintf(stderr, "drive_ui: sendkeys needs <text>\n");
          [pool release];
          return 1;
        }
      for (NSUInteger i = 0; i < [value length]; i++)
        {
          NSString *ch = [value substringWithRange: NSMakeRange(i, 1)];
          [X11Support simulateKeyStroke: ch];
        }
    }
  else if ([command isEqualToString: @"clear"])
    {
      /* Click the field, select all, then delete - clears an editable area. */
      NSArray *treeRows = ParseTree(FetchTree(pid));
      NSArray *row = nil;
      if (idArg)
        row = ResolveRowByID(treeRows, idArg);
      else if (wantText)
        row = ResolveRow(treeRows, wantClass, wantText, YES);
      if (row == nil)
        {
          fprintf(stderr, "drive_ui: clear: widget not found\n");
          [pool release];
          return 1;
        }
      NSPoint c = CenterOfRow(row);
      if (c.x == 0 && c.y == 0)
        {
          fprintf(stderr, "drive_ui: clear: widget has no usable screen_frame\n");
          [pool release];
          return 1;
        }
      [X11Support simulateMouseMoveTo: c];
      usleep(50000);
      [X11Support simulateClick: 1];
      usleep(50000);
      /* Select all (GNUstep Command is Left Alt) then delete. */
      [X11Support simulateChordWithModifiers: [NSArray arrayWithObject: @"alt"] key: @"a"];
      usleep(50000);
      [X11Support simulateChordWithModifiers: [NSArray array] key: @"BackSpace"];
    }
  else if ([command isEqualToString: @"chord"])
    {
      /* chord <mods> <key>  e.g. "chord control c" or "chord shift Return" */
      NSMutableArray *mods = [NSMutableArray array];
      NSString *key = nil;
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if (i + 1 < [args count] && (i + 2 == [args count])) key = [args objectAtIndex: i + 1];
          else if (![a isEqualToString: command]) [mods addObject: a];
        }
      if (key == nil && [mods count] > 0) { key = [mods lastObject]; [mods removeLastObject]; }
      if (key == nil)
        {
          fprintf(stderr, "drive_ui: chord needs <mods> <key>\n");
          [pool release];
          return 1;
        }
      [X11Support simulateChordWithModifiers: mods key: key];
    }
  else if ([command isEqualToString: @"type"])
    {
      /* Click the target field (to focus it), then type the text as real key
       * events.  This is exactly what a user would do, so it works on any
       * text control (NSTextField, NSTextView, CompletionField, ...). */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      NSString *value = nil, *label = nil;
      NSString *target = nil;
      if ([positionals count] >= 2)
        {
          NSString *first = [positionals objectAtIndex: 0];
          if ([first hasPrefix: @"objc:"]) { target = first; }
          else { label = first; }
          value = [positionals objectAtIndex: [positionals count] - 1];
        }
      if (value == nil)
        {
          fprintf(stderr, "drive_ui: type needs <object_id> <text> or --text <label> <text>\n");
          [pool release];
          return 1;
        }

      NSArray *treeRows = ParseTree(FetchTree(pid));
      NSArray *row = nil;
      if (target)
        row = ResolveRowByID(treeRows, target);
      else
        {
          NSString *needle = label ? label : wantText;
          if (needle == nil)
            {
              fprintf(stderr, "drive_ui: type needs a target object_id or label\n");
              [pool release];
              return 1;
            }
          row = ResolveRow(treeRows, wantClass, needle, YES);
        }

      if (row == nil)
        {
          fprintf(stderr, "drive_ui: type: widget not found\n");
          [pool release];
          return 1;
        }

      NSPoint c = CenterOfRow(row);
      if (c.x == 0 && c.y == 0)
        {
          fprintf(stderr, "drive_ui: type: widget has no usable screen_frame\n");
          [pool release];
          return 1;
        }

      /* Focus the field with a real click, then type. */
      [X11Support simulateMouseMoveTo: c];
      usleep(50000);
      [X11Support simulateClick: 1];
      usleep(50000);

      for (NSUInteger i = 0; i < [value length]; i++)
        {
          NSString *ch = [value substringWithRange: NSMakeRange(i, 1)];
          [X11Support simulateKeyStroke: ch];
        }
    }
  else
    {
      fprintf(stderr, "drive_ui: unknown command '%s'\n", [command UTF8String]);
      Usage();
      [pool release];
      return 1;
    }

  [pool release];
  return 0;
}

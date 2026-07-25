/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * DragInject - Injected into a running GNUstep app via dlopen.
 * Uses ONLY libobjc + POSIX (no AppKit/Foundation symbols).
 * Swizzles NSView mouseDown:/mouseDragged:/mouseUp: to make
 * UI controls draggable. Reports pixel deltas to a text file.
 */

#include <objc/runtime.h>
#include <objc/message.h>
#include <objc/objc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <sys/types.h>
#include <sys/stat.h>

// ── Types ──────────────────────────────────────────────────────────
typedef struct { double x, y; } DTPoint;

// ── Global state (non-static for LLDB access) ──────────────────────
BOOL DT_enabled = NO;
static int  DT_fd = -1;
static char DT_path[256];

static SEL s_mouseDown, s_mouseDragged, s_mouseUp;
static SEL s_setFrameOrigin_, s_deltaX, s_deltaY;
static SEL s_title, s_stringValue, s_UTF8String;
static Class c_NSView = NULL;
static Ivar  ivar_frame = NULL;

// Original IMPs stored per-class
struct OrigIMPs { IMP mouseDown, mouseDragged, mouseUp; };
static Class *swizzledClasses = NULL;
static struct OrigIMPs *origIMPs = NULL;
static int swizzledCount = 0, swizzledCap = 0;

// Known offset of ._OBJC_CLASS_NSView in libgnustep-gui.so.0.32
// (from nm -D output: 0x533ec8)
#define NSVIEW_CLASS_OFFSET 0x533ec8

// ── Private helpers ────────────────────────────────────────────────

static struct OrigIMPs *getOrig(Class cls)
{
  for (int i = 0; i < swizzledCount; i++)
    if (swizzledClasses[i] == cls) return &origIMPs[i];
  return NULL;
}

static Class findNSViewViaMaps(void)
{
  // Read /proc/self/maps to find libgnustep-gui base address
  FILE *f = fopen("/proc/self/maps", "r");
  if (!f) { fprintf(stderr, "DT: cannot open /proc/self/maps\n"); return NULL; }
  fprintf(stderr, "DT: /proc/self/maps:\n");
  char line[4096];
  unsigned long guiBase = 0;
  while (fgets(line, sizeof(line), f)) {
    if (strstr(line, "libgnustep-gui"))
      fprintf(stderr, "DT:   >>> %s", line);
    else if (strstr(line, "DragInject"))
      fprintf(stderr, "DT:   >>> %s", line);
  }
  rewind(f);
  while (fgets(line, sizeof(line), f)) {
    if (strstr(line, "libgnustep-gui")) {
      char *dash = strchr(line, '-');
      if (dash) {
        *dash = '\0';
        guiBase = strtoul(line, NULL, 16);
        break;
      }
    }
  }
  fclose(f);
  if (!guiBase) {
    fprintf(stderr, "DT: libgnustep-gui not found in /proc/self/maps\n");
    return NULL;
  }

  // ._OBJC_CLASS_NSView is at a fixed offset from the library base.
  // The symbol value IS the class pointer.
  unsigned long nsviewAddr = guiBase + NSVIEW_CLASS_OFFSET;
  return (Class)(uintptr_t)nsviewAddr;
}

static double frameX(id view)
{
  if (ivar_frame)
    return *(double *)((char *)view + ivar_getOffset(ivar_frame));
  return 0;
}
static double frameY(id view)
{
  if (ivar_frame)
    return *(double *)((char *)view + ivar_getOffset(ivar_frame) + 8);
  return 0;
}

static void writeDelta(id view, double ox, double oy)
{
  if (DT_fd < 0) return;
  double cx = frameX(view), cy = frameY(view);
  double dx = cx - ox, dy = cy - oy;
  if (dx > -0.5 && dx < 0.5 && dy > -0.5 && dy < 0.5) return;

  const char *cn = object_getClassName(view) ?: "?";
  const char *tl = "";
  if (class_respondsToSelector(object_getClass(view), s_title)) {
    id t = ((id(*)(id, SEL))objc_msgSend)(view, s_title);
    if (t) tl = ((const char*(*)(id, SEL))objc_msgSend)(t, s_UTF8String) ?: "";
  } else if (class_respondsToSelector(object_getClass(view), s_stringValue)) {
    id t = ((id(*)(id, SEL))objc_msgSend)(view, s_stringValue);
    if (t) tl = ((const char*(*)(id, SEL))objc_msgSend)(t, s_UTF8String) ?: "";
  }

  char buf[512];
  int n = snprintf(buf, sizeof(buf),
    "move: %s \"%s\" dx=(%.0f) dy=(%.0f) object=%p\n",
    cn, tl, dx, dy, view);
  if (n > 0) write(DT_fd, buf, n);
}

// ── Swizzled implementations ───────────────────────────────────────

static void my_mouseDown(id self, SEL _c, id ev)
{
  struct OrigIMPs *o = getOrig(object_getClass(self));
  if (DT_enabled) {
    double *stor = malloc(2 * sizeof(double));
    stor[0] = frameX(self);
    stor[1] = frameY(self);
    objc_setAssociatedObject(self, "dt", (id)stor, OBJC_ASSOCIATION_RETAIN);
    return;
  }
  if (o && o->mouseDown) ((void(*)(id, SEL, id))o->mouseDown)(self, s_mouseDown, ev);
}

static void my_mouseDragged(id self, SEL _c, id ev)
{
  struct OrigIMPs *o = getOrig(object_getClass(self));
  if (DT_enabled) {
    double *stor = (double *)objc_getAssociatedObject(self, "dt");
    if (stor) {
      double dx = ((double(*)(id, SEL))objc_msgSend)(ev, s_deltaX);
      double dy = ((double(*)(id, SEL))objc_msgSend)(ev, s_deltaY);
      double cx = frameX(self), cy = frameY(self);
      DTPoint pt = { cx + dx, cy - dy };
      ((void(*)(id, SEL, DTPoint))objc_msgSend)(self, s_setFrameOrigin_, pt);
    }
    return;
  }
  if (o && o->mouseDragged) ((void(*)(id, SEL, id))o->mouseDragged)(self, s_mouseDragged, ev);
}

static void my_mouseUp(id self, SEL _c, id ev)
{
  struct OrigIMPs *o = getOrig(object_getClass(self));
  if (DT_enabled) {
    double *stor = (double *)objc_getAssociatedObject(self, "dt");
    if (stor) {
      writeDelta(self, stor[0], stor[1]);
      free(stor);
      objc_setAssociatedObject(self, "dt", NULL, OBJC_ASSOCIATION_RETAIN);
    }
    return;
  }
  if (o && o->mouseUp) ((void(*)(id, SEL, id))o->mouseUp)(self, s_mouseUp, ev);
}

// ── Swizzling ──────────────────────────────────────────────────────

static void saveOrig(Class cls)
{
  for (int i = 0; i < swizzledCount; i++)
    if (swizzledClasses[i] == cls) return;
  if (swizzledCount >= swizzledCap) {
    swizzledCap = swizzledCap ? swizzledCap * 2 : 64;
    swizzledClasses = realloc(swizzledClasses, swizzledCap * sizeof(Class));
    origIMPs = realloc(origIMPs, swizzledCap * sizeof(struct OrigIMPs));
  }
  int idx = swizzledCount++;
  swizzledClasses[idx] = cls;
  Method m;
  m = class_getInstanceMethod(cls, s_mouseDown);
  origIMPs[idx].mouseDown    = m ? method_getImplementation(m) : NULL;
  m = class_getInstanceMethod(cls, s_mouseDragged);
  origIMPs[idx].mouseDragged = m ? method_getImplementation(m) : NULL;
  m = class_getInstanceMethod(cls, s_mouseUp);
  origIMPs[idx].mouseUp      = m ? method_getImplementation(m) : NULL;
}

static void swizzle(Class cls)
{
  IMP newImps[3] = { (IMP)my_mouseDown, (IMP)my_mouseDragged, (IMP)my_mouseUp };
  SEL sels[3] = { s_mouseDown, s_mouseDragged, s_mouseUp };
  saveOrig(cls);
  for (int i = 0; i < 3; i++) {
    Method m = class_getInstanceMethod(cls, sels[i]);
    if (m) class_replaceMethod(cls, sels[i], newImps[i], method_getTypeEncoding(m));
  }
}

// ── Initialization ─────────────────────────────────────────────────

void DTInit(void)
{
  if (c_NSView) return;

  s_mouseDown       = sel_registerName("mouseDown:");
  s_mouseDragged    = sel_registerName("mouseDragged:");
  s_mouseUp         = sel_registerName("mouseUp:");
  s_setFrameOrigin_ = sel_registerName("setFrameOrigin:");
  s_deltaX          = sel_registerName("deltaX");
  s_deltaY          = sel_registerName("deltaY");
  s_title           = sel_registerName("title");
  s_stringValue     = sel_registerName("stringValue");
  s_UTF8String      = sel_registerName("UTF8String");

  // Find NSView by reading /proc/self/maps + known offset
  c_NSView = findNSViewViaMaps();
  if (!c_NSView) {
    fprintf(stderr, "DT: NSView not found\n");
    return;
  }

  ivar_frame = class_getInstanceVariable(c_NSView, "_frame");

  snprintf(DT_path, sizeof(DT_path), "/tmp/dragtool_deltas_%d.txt", getpid());

  // Swizzle all NSView subclasses
  int cnt = objc_getClassList(NULL, 0);
  Class *buf = malloc(sizeof(Class) * cnt);
  cnt = objc_getClassList(buf, cnt);
  for (int i = 0; i < cnt; i++) {
    for (Class s = buf[i]; s; s = class_getSuperclass(s)) {
      if (s == c_NSView) { swizzle(buf[i]); break; }
    }
  }
  swizzle(c_NSView);
  free(buf);
}

void DTOpenDump(void)
{
  if (DT_fd >= 0) close(DT_fd);
  DT_fd = open(DT_path, O_WRONLY|O_CREAT|O_TRUNC, 0644);
}

void DTCloseDump(void)
{
  if (DT_fd >= 0) { close(DT_fd); DT_fd = -1; }
}

__attribute__((constructor))
static void _DTConstruct(void)
{
  DTInit();
  DTOpenDump();
}

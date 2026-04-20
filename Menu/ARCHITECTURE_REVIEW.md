# Menu.app Architecture Review

## Executive Summary

Menu.app is a global menu bar server that displays the active application's menus
at the top of the screen. It supports three menu protocols: Canonical (dbusmenu),
GTK (org.gtk.Menus/Actions), and GNUstep-native IPC. While functionally correct,
the system suffers from excessive CPU usage caused by layered defensive mechanisms,
cascading timer storms, unnecessary work on hot paths, and disabled-but-present
infrastructure. This document identifies 10 critical architectural issues and
proposes a streamlined architecture.

## Current Architecture

```
                    ┌──────────────────┐
                    │  MenuApplication │ (NSApplication subclass)
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  MenuController  │ Coordinator, D-Bus fd monitoring,
                    │                  │ timers, window monitoring bridge
                    └───┬────┬────┬────┘
                        │    │    │
           ┌────────────┘    │    └────────────────┐
           │                 │                     │
  ┌────────▼────────┐ ┌─────▼──────┐   ┌──────────▼───────────┐
  │  AppMenuWidget  │ │ WindowMon. │   │ MenuProtocolManager   │
  │  (~2400 LOC)    │ │  (GCD X11) │   │                       │
  │  Anti-flicker   │ └────────────┘   │  ┌─ DBusMenuImporter  │
  │  Grace periods  │                  │  ├─ GTKMenuImporter   │
  │  Reconcile      │                  │  └─ GNUStepImporter   │
  │  Dialog detect  │                  └───────────────────────┘
  │  PID tracking   │
  │  Menu rebuild   │
  └─────────────────┘
```

## Critical Issues

### Issue 1: Timer/Poll Proliferation — Primary CPU Source

The system runs up to 8 concurrent timers that create continuous work:

| Timer                        | Interval    | Purpose                              |
|------------------------------|-------------|--------------------------------------|
| DBus fd NSFileHandle         | event-driven| Primary D-Bus message processing     |
| DBus polling timer           | 500ms       | Fallback D-Bus polling               |
| Window validation watchdog   | 2000ms      | Clear menus for closed windows       |
| Active window reconcile      | 60ms + 120ms| Verify focus state settled correctly |
| No-menu grace period         | 200ms (×10) | Wait for app to register menu        |
| Desktop menu startup retry   | 200ms (×50) | Wait for desktop app at startup      |
| DBus rearm backoff           | 100ms       | Cooldown after fd rapid-fire         |
| Cleanup timer                | 30s         | Stale entry cleanup in DBusImporter  |

Additionally there are single-shot timers for animation (16ms/60fps).

**Impact**: Each timer callback does non-trivial work — X11 queries, protocol
checks, PID lookups. The interaction between grace timers and reconcile timers
creates cascading update storms (see Issue 2).

### Issue 2: Cascading Update Storms

A single focus change triggers this cascade:

```
WindowMonitor detects _NET_ACTIVE_WINDOW change
  → posts notification to main thread
    → MenuController.activeWindowChangedNotification:
      ├─ Dedup check (X11 PID lookup, menu state comparison)
      ├─ appMenuWidget.updateForActiveWindowId:
      │   ├─ Dialog preservation check (X11 property read)
      │   ├─ Window validity check (XGetWindowAttributes)
      │   ├─ PID lookup (X11 _NET_WM_PID)
      │   ├─ Same-parent title-bar check (2× XQueryTree)
      │   ├─ App name lookup (multiple X11 properties)
      │   └─ displayMenuForWindow:
      │       ├─ PID lookup AGAIN
      │       ├─ hasMenuForWindow → protocol scan
      │       ├─ getMenuForWindow → D-Bus call + parse
      │       ├─ isPlaceholderMenu check
      │       └─ loadMenu → setupMenuViewWithMenu
      │           ├─ RECREATE NSMenuView
      │           ├─ REBUILD system submenu
      │           ├─ Build menu signature
      │           └─ Scan for GNUstep menu items
      ├─ Schedule reconcile timer (60ms)
      │   └─ performDelayedActiveWindowReconcile
      │       ├─ getActiveWindow (X11 read)
      │       ├─ PID comparison
      │       ├─ Dialog check
      │       └─ updateForActiveWindowId AGAIN (full cascade)
      │           └─ May schedule RETRY reconcile (120ms)
      └─ (If menu missing) schedule grace timer (200ms)
          └─ noMenuGracePeriodExpired
              └─ updateForActiveWindowId AGAIN
```

**Worst case**: A single window switch can trigger 3+ full update passes, each
doing 5-10 X11 round-trips. During rapid window switching (Alt-Tab), these pile
up and create sustained high CPU.

### Issue 3: Excessive Defensive Layers in AppMenuWidget

`updateForActiveWindowId:` (the hot path) has 12 defensive checks:

1. Protocol manager nil check
2. Window validity with preservation logic
3. Self-window detection (`[NSApp windowWithWindowNumber:]`)
4. Dialog preservation (`isDialogWindow:`)
5. Window==0 grace period (2-second window!)
6. Pending grace timer dedup
7. Same-window dedup (with modal recovery exception)
8. Modal recovery force-reload (with 350ms throttle)
9. Cross-app switch detection (PID comparison)
10. Title bar click detection (XQueryTree × 2)
11. Known-menuless PID fast path
12. Exception handling wrapper

Each check involves X11 or Foundation calls. Many are workarounds for bugs
introduced by other workarounds. The 2-second no-active-window grace period
(`NO_ACTIVE_WINDOW_GRACE_SECS`) is particularly expensive because it delays
menu clearing when the user clicks the desktop, holding stale state.

### Issue 4: Disabled Cache With Full Infrastructure

`MenuCacheManager` has 380 lines of code including:
- LRU eviction logic
- Age-based expiry
- Application complexity classification (hardcoded app list)
- Periodic maintenance timer
- Statistics tracking

**All of it is disabled**: `maxCacheSize = 0`, `maxCacheAge = 0`, every
`getCachedMenuForWindow:` returns nil, every `cacheMenu:` is a no-op. The class
is still instantiated via `[MenuCacheManager sharedManager]`, and its cleanup
timer logic remains.

### Issue 5: Repeated X11 Calls on Hot Path

During a single window switch, these X11 operations are called multiple times:

| Operation                      | Calls per switch |
|-------------------------------|-----------------|
| `getWindowPID:`               | 3-4×            |
| `XGetWindowAttributes`        | 2-3×            |
| `getApplicationNameForWindow:`| 1-2×            |
| `isDialogWindow:`             | 1-2×            |
| `isDesktopWindow:`            | 1-2×            |
| `getWindowMenuService/Path:`  | 1-2×            |

Each X11 call requires a synchronous round-trip to the X server. On a remote
display or under load, this adds real latency.

### Issue 6: NSMenuView Recreated on Every Menu Load

`setupMenuViewWithMenu:` destroys and recreates the menu view on every call:

```objc
// Remove observer, nil menu, remove from superview
[[NSNotificationCenter defaultCenter] removeObserver:self.menuView];
[self.menuView setMenu:nil];
[self.menuView removeFromSuperview];
self.menuView = nil;

// Recreate from scratch
AppMenuView *newMenuView = [[AppMenuView alloc] initWithFrame:menuViewFrame];
[newMenuView setHorizontal:YES];
[newMenuView setMenu:menu];
[self addSubview:newMenuView];
```

The comment says "recreate to guarantee a clean cell tree", but NSMenuView is
a heavyweight object. Creating it involves GNUstep internal cell layout, font
measurement, and notification registration. This is done even when switching
between windows of the same application (same menu content).

### Issue 7: Menu Comparison Via Full Tree Signature

`menusAreEquivalentForDisplay:` builds a complete string signature by recursively
walking every menu item and submenu:

```objc
[signature appendFormat:@"{%@|%d|%@|%lu", title, enabled, keyEquivalent, modifierMask];
if (submenu) {
    [self appendMenuSignatureForMenu:submenu intoString:signature]; // recursive
}
```

For applications like Firefox or LibreOffice with hundreds of menu items, this
is O(n) string concatenation work on every menu load, done after the heavy
`getMenuForWindow:` D-Bus call already completed.

### Issue 8: System Menu Filesystem Scan on Every Open

`menuNeedsUpdate:` for the ⌘ system submenu scans 8+ directories for .app bundles,
reads Info.plist from each, deduplicates by bundle ID, and sorts alphabetically.
This happens every time the user opens the system menu (throttled to 150ms minimum
interval, but still a full filesystem scan).

### Issue 9: DBus Fd Monitoring Rapid-Fire Detection

The `dbusFileDescriptorReady:` handler has a rapid-fire detection mechanism:

```objc
if (elapsed < DBUS_MIN_NOTIFICATION_INTERVAL) {  // 5ms
    _rapidDbusNotificationCount++;
    if (_rapidDbusNotificationCount > DBUS_RAPID_FIRE_THRESHOLD) {  // 100
        // Back off with delayed re-arm
    }
}
```

This suggests the fd monitoring hits a tight loop under certain conditions.
The back-off rearms with a 100ms timer, but the underlying D-Bus connection
state that causes rapid notifications is never addressed.

### Issue 10: Reconcile/Grace Timer Interaction

The reconcile timer and grace period timer interact to create sustained CPU:

1. Window changes → grace timer starts (200ms)
2. Reconcile timer fires (60ms) → calls updateForActiveWindowId
3. This may start a new grace timer (if menu not yet registered)
4. Previous grace timer fires → calls updateForActiveWindowId
5. This triggers another reconcile check
6. Loop continues for 2+ seconds

This is especially bad during the "known-menuless PID" path before the PID is
recorded, creating ~10 update cycles per window switch for applications that
don't export menus.

---

## Proposed Optimized Architecture

See ARCHITECTURE_PROPOSED.md for the detailed design.

### Key Principles

1. **Single canonical update path** — One function, one pass, no cascading
2. **Cache X11 state** — PID and window properties cached per window switch
3. **Eliminate timer storms** — Replace grace/reconcile timers with a single
   coalescing debounce mechanism
4. **Reuse menu views** — Only recreate NSMenuView when menu actually changes
5. **Remove dead code** — Delete MenuCacheManager and unused defensive layers
6. **Lazy system menu** — Cache app directory scan, invalidate on FSEvents

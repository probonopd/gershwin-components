# Menu.app Proposed Architecture

## Design Goals

1. **Minimal CPU usage** — No work unless a window actually changes
2. **Zero flicker** — Menu transitions are atomic (old menu visible until new is ready)
3. **Single update path** — One function handles all window switch logic
4. **Predictable timing** — At most one coalesced update per window switch event
5. **No cascading** — No timer fires that trigger another timer

## Architecture Overview

```
                    ┌──────────────────┐
                    │  MenuApplication │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  MenuController  │  Owns window, delegates
                    └───┬────┬────┬────┘
                        │    │    │
           ┌────────────┘    │    └────────────────┐
           │                 │                     │
  ┌────────▼────────┐ ┌─────▼──────┐   ┌──────────▼───────────┐
  │  AppMenuWidget  │ │ WindowMon. │   │ MenuProtocolManager   │
  │  (~800 LOC)     │ │  (GCD X11) │   │                       │
  │  Single update  │ └────────────┘   │  ┌─ DBusMenuImporter  │
  │  path with      │                  │  ├─ GTKMenuImporter   │
  │  coalescing     │                  │  └─ GNUStepImporter   │
  └─────────────────┘                  └───────────────────────┘
```

## Key Changes

### 1. Single Coalesced Update Path

Replace the current cascade of `updateForActiveWindowId:` → `displayMenuForWindow:`
→ grace timer → reconcile timer → retry with a single `handleWindowFocusChange:` that
uses a coalescing timer:

```
WindowMonitor notification arrives
  → cancelPendingCoalesceTimer
  → start coalesceTimer (30ms)
  → coalesceTimer fires
    → handleWindowFocusChange:(windowId)
      → gather all state in one pass (PID, app name, dialog check, etc.)
      → decide action: load menu | preserve existing | show system-only
      → execute action atomically
      → done (no further timers)
```

The 30ms coalescing window absorbs rapid window switches (Alt-Tab through
multiple windows) and transient window==0 states during WM operations.

If the menu is not yet registered after the coalesced update, we schedule a
single retry timer (200ms, max 5 retries = 1 second total). No cascading.

### 2. WindowSwitchContext — Cache X11 State Per Switch

Instead of calling `getWindowPID:`, `isDialogWindow:`, `getApplicationNameForWindow:`
repeatedly throughout the update path, gather everything once:

```objc
@interface WindowSwitchContext : NSObject
@property unsigned long windowId;
@property pid_t pid;
@property NSString *appName;
@property BOOL isDialog;
@property BOOL isDesktop;
@property BOOL isSelf;
@property BOOL hasRegisteredMenu;
@end
```

Built once at the start of `handleWindowFocusChange:`, passed through the entire
update path. No X11 call is made more than once per window switch.

### 3. Eliminate Timer Storm

**Remove**:
- Active window reconcile timer (60ms + 120ms retry)
- Grace period timers (200ms × up to 10)
- Window validation watchdog (2s)
- DBus polling timer (500ms) — not needed when fd monitoring works

**Replace with**:
- Coalesce timer (30ms, one-shot)
- Single retry timer for menu registration (200ms, max 5 retries)
- Watchdog timer (5s instead of 2s, only validates when app is idle — no
  menu tracking visible)

### 4. Reuse NSMenuView When Menu Unchanged

Before destroying and recreating the menu view, compare:
1. Is it the same window? → Skip entirely
2. Is it the same application (PID match)? → Check if top-level item
   titles changed. If not, keep existing view.
3. Different application? → Only then recreate.

The expensive full-tree signature comparison (`menusAreEquivalentForDisplay:`)
is replaced with a lightweight top-level-only title array comparison.

### 5. Remove MenuCacheManager

Delete [MenuCacheManager.h](MenuCacheManager.h) and [MenuCacheManager.m](MenuCacheManager.m) entirely. All references removed.
The class does no useful work (caching disabled) and adds dead code + maintenance
burden.

### 6. Lazy System Menu With Caching

Replace the filesystem-scan-on-every-open with:
- Cache the app bundle list in an NSArray
- Rebuild only when the menu is opened AND more than 30 seconds have passed
- This reduces a ~50 stat() syscall scan to a simple array iteration

### 7. Simplify AppMenuWidget

Reduce from ~2400 LOC to ~800 LOC by:
- Removing 8 of 12 defensive checks in the update path
- Combining `updateForActiveWindowId:` and `displayMenuForWindow:` into
  `handleWindowFocusChange:`
- Removing fallback menu infrastructure (`ENABLE_FALLBACK_MENUS` already off)
- Removing knownMenulessPIDs tracking (unnecessary with capped retry)
- Removing dialog preservation (handled by PID-awareness in the single path)
- Removing title-bar-click detection (handled by coalescing — consecutive
  events for the same PID are automatically absorbed)

### 8. DBus Processing: Fd-Only, No Polling

Keep the NSFileHandle-based fd monitoring. Remove the polling timer entirely.
If the fd monitoring rapid-fires, instead of a backoff timer, throttle using
a simple timestamp check (process at most once per 5ms).

## Implementation Plan

### Phase 1: Strip dead code
- Delete MenuCacheManager
- Remove ENABLE_FALLBACK_MENUS code (#if 0 already)
- Remove menu signature comparison
- Remove startup desktop menu retry loop

### Phase 2: Introduce WindowSwitchContext
- Create context object for caching per-switch X11 state
- Thread through update path

### Phase 3: Coalesced update path
- Replace timer cascade with single coalescing mechanism
- Single handleWindowFocusChange method
- Cap retries for unregistered menus

### Phase 4: Optimize menu view lifecycle
- Skip NSMenuView recreation when menu content is unchanged
- Use lightweight top-level comparison
- Cache system submenu app list

### Phase 5: Final cleanup
- Remove unused properties and methods
- Remove excess logging on hot paths
- Verify build and test with real applications

## Expected Outcome

| Metric              | Before              | After               |
|---------------------|---------------------|---------------------|
| Timers active       | 5-8                 | 1-2                 |
| X11 calls/switch    | 10-15               | 3-4                 |
| Update passes/switch| 2-4                 | 1                   |
| AppMenuWidget LOC   | ~2400               | ~800                |
| Menu view recreates | Every load          | Only on app switch  |
| CPU during Alt-Tab  | Sustained 30-60%    | Spike <5%           |

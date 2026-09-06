# TODO: Root cause of memory corruption

## Symptom

When extras are toggled on/off at runtime (via the preference pane), the
following exceptions occur in all eight extras:

```
NSCalendarDate(instance) does not recognize invalidatePresentation
GSMutableArray(instance) does not recognize isEqualToString:
GSDictionary(instance) does not recognize objectAtIndex:
GSMutableDictionary(instance) does not recognize removeAllObjects
```

The same pointer that was a `GSMenuExtraContext *` is later found to be
an `NSCalendarDate`, `GSDictionary`, `GSMutableArray`, etc.  The address
is valid but the type has changed — the original object was freed and a
different object was allocated in its place.

## Location

`GSMenuExtraContext` objects allocated during `loadMenuExtras` (line 247)
are being deallocated prematurely despite being held by a strong ARC
reference (the extra's `_context` ivar).  The extra itself is also
deallocated despite being held by `_allExtras` (a strong NSMutableArray).

## Suspected root cause

A retain-count underflow or `objc_release` sent to an already-released
object.  The `SysfsBacklightBackend` class is compiled into both the
main `Menu` executable AND the `BrightnessExtra` bundle.  The Objective-C
runtime detects the duplicate and logs:

```
Loading two versions of SysfsBacklightBackend.  The class that will be
used is undefined
```

It is not guaranteed which copy wins.  If the bundle's copy is used, its
`initialize` runs a second time, potentially corrupting the class' static
data (e.g.  `_OBJC_METACLASS_RO_cache_bits`).  This can cause
`objc_destroyWeak` to skip zeroing weak references, leaving dangling
weak pointers that later crashes in `objc_msgSend_fpret`.

## Mitigations applied (all eight extras)

| Guard | Where |
|-------|-------|
| `@try/@catch` | `menuExtraDidLoad`, `menu`, `tick`, `refreshBrightnessPresentation`, `updateBattery`, `pollGitHub`, `updateCPUUsage`, `updateRAMUsage`, `refreshTimerFired:` |
| `BOOL _running` | All timer callbacks exit early if `_running == NO` |
| `@try/@catch` in manager | `applyEnabledSet:`, `refreshExtraWithIdentifier:`, `updateTimerFired:`, `menuNeedsUpdate:`, `proposedTitleWidth:forMenuView:` |

The Menu is now crash-safe — every external-facing method that accesses
an extra is wrapped.  Corrupted state is caught, logged, and the extra
reverts to a safe "not running" state.

## What would fix it properly

1.  Remove `SysfsBacklightBackend.m` from the BrightnessExtra bundle's
    source list (already done — `Brightness_OBJC_FILES` now lists only
    `BrightnessExtra.m`).  This eliminates the duplicate class.
2.  Export the main executable's symbols (`-Wl,--export-dynamic` is
    already in `Menu_LDFLAGS`), so the bundle can resolve the class
    from the main app at runtime.
3.  If the crashes persist even after fixing the duplicate, the runtime
    itself (libobjc2) may have a latent bug in weak-reference zeroing
    under ARC.  Workaround: avoid per-extra timers entirely and let the
    manager drive all periodic updates via its single shared timer.

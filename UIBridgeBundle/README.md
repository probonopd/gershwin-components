# UIBridge.bundle

A standalone, autoloaded GNUstep **AppKit user bundle** that vends the UIBridge
introspection / UI-automation service over Distributed Objects (DO).

Because it loads into every app via the `GSAppKitUserBundles` default, it works
under **any** `GSTheme` — including the base theme — and **no application needs
modifying**. The service was originally embedded in the Eau theme; it was
extracted here so introspection is theme-independent and so a class of
object-lifetime / concurrency bugs could be fixed at the root.

## What it provides

A per-PID DO service named `org.gershwin.Gershwin.Theme.UIBridge.<pid>`,
registered on the **main run loop**, implementing `UIBridgeProtocol`:

- **Widget tree** — `rootObjects`, `detailsForObject:`, `fullTreeForObject:`
- **Action** — `invokeSelector:onObject:withArgs:`
- **Menus** — `listMenus`, `invokeMenuItem:`
- JSON-string variants of each (for clients that prefer strings over DO `bycopy`)

Objects are addressed by stable ids (`objc:<n>`) issued from a real id↔object
registry. The wire protocol (`UIBridgeProtocol.h`) and the per-PID name are
unchanged from the original in-theme service, so an existing `UIBridgeServer`
client talks to it unmodified.

## Status

- Service fully extracted into this bundle; builds **warning-free** (ARC).
- The **Eau theme no longer ships its own UIBridge** — it was removed entirely
  and the theme now assumes this bundle. (In the Eau fork that "strip" change is
  the first patch in the upstreaming order; the theme depends on the bundle being
  present for introspection.)
- **Validated in-harness** (the goldstep specimen harness) under both the base
  `GSTheme` and Eau: the bundle walks the live AppKit tree correctly (e.g. 24
  buttons in the `Buttons` specimen) and `get_details` round-trips resolve. Also
  exercised across the full specimen suite during the theme's upstreaming
  dry-run — introspection via the bundle was correct throughout.
- **Not yet validated on a production `/System` desktop install** (the
  `install.sh` path). On the dev harness the bundle is autoloaded per-sandbox via
  `GSAppKitUserBundles`.

## Hardening vs the original in-theme service

This is **not** a verbatim copy — four deliberate changes, all fixing real bugs
the embedded version had:

1. **id↔object registry, not pointer casting.** A weak `NSMapTable`
   (`objc:<n>` ↔ object). A weak value auto-nils when its object is deallocated,
   so looking up a stale id returns `nil` instead of dereferencing a freed
   pointer. **Fixes a use-after-free** (the original cast a raw hex pointer back
   to `id`).
2. **Type-correct argument marshalling.** `invokeSelector:` decodes each argument
   according to the method's *real* parameter type (`NSNumber`→primitive; struct
   / pointer / `SEL` args refused), instead of writing every argument as an `id`.
   **Fixes a type-confusion** — e.g. `setTag:[7]` now sets the integer `7`, where
   the original shoved an object pointer into the primitive slot.
3. **Single-threaded.** No `-enableMultipleThreads` and no connection delegate;
   the receive port is added to the **main run loop**, so DO requests are serviced
   on the main thread alongside AppKit and never race the app's drawing. This
   removes the cross-thread DO hazard that came from coupling an automation server
   to the drawing theme. (Note: a separate teardown stack-overflow once suspected
   to come from `enableMultipleThreads` was later traced to an unrelated base
   `NSAutoreleasePool` bug — this bundle does not claim to fix that.)
4. **Theme-independent menus.** Menu methods are reimplemented against
   `[NSApp mainMenu]` / each window's `-menu` and `performActionForItemAtIndex:`,
   dropping the theme's private window→menu cache. The service depends only on
   `NSApp`, never on the active theme.

## Requirements

- GNUstep (`-base` / Foundation + `-gui` / AppKit) with the GNUstep `make`
  system.
- libobjc2 (non-fragile ABI v2, ARC), clang.
- Portable across **Linux and FreeBSD** — no OS-specific code.

## Build & install

```sh
. /System/Library/Makefiles/GNUstep.sh
gmake
sudo -E gmake install        # installs UIBridge.bundle to $(GNUSTEP_LIBRARY)/Bundles
```

Or run `./install.sh`, which builds, installs, and enables autoload per-user.
For a debug build of the service: `gmake ADDITIONAL_OBJCFLAGS+=-DUIBRIDGE_DEBUG`.

## Enable (autoload)

AppKit instantiates the principal class of every bundle named in
`GSAppKitUserBundles`:

```sh
# per-user
defaults write NSGlobalDomain GSAppKitUserBundles '(UIBridge)'
```

System-wide (e.g. on Gershwin), add `UIBridge` to `GSAppKitUserBundles` in
`/System/Library/Preferences/GlobalDefaults/NSGlobalDomain.plist` so every app
picks it up. No application needs modifying.

> Tip: if a theme that *also* self-registers the same per-PID name runs alongside
> this bundle, the two collide. The theme must stand down when the bundle is
> present (the Eau theme removes its in-theme service entirely for exactly this
> reason).

## Layout

| File | Role |
|---|---|
| `UIBridgeLoader.{h,m}` | principal class: autoload hook + single-threaded per-PID DO registration on the main run loop |
| `UIBridgeService.{h,m}` | `UIBridgeProtocol` implementation: id registry, live-tree walk, typed `invokeSelector:`, menus |
| `UIBridgeProtocol.h` | DO wire contract |
| `GNUmakefile`, `install.sh` | bundle build + install/enable |
| `validate.py` | in-harness validation against the goldstep specimen suite |

## License

BSD-2-Clause.

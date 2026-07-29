# make_appimage — Technology

## Goal

Package a GNUstep application into a standalone Linux AppImage that runs
on any distribution (glibc or musl) without requiring any runtime to be
installed on the host.  Every shared library, bundle, theme, and helper
binary must resolve from inside the AppDir — no host filesystem access
at runtime.

## Architecture

```
main.m  (CLI entry point)
  └── AppImageBuilder            — orchestrator
        ├── LibraryResolver          — ELF discovery + ldd dependency resolution
        ├── LibraryDeployer          — copies libraries, resolves symlinks
        ├── InterpreterDeployer      — ld-linux deployment
        └── appimagetool             — external, produces final .AppImage
```

### Key files

| File | Role |
|------|------|
| `AppImageBuilder.h/.m` | Orchestrates all build steps |
| `LibraryResolver.h/.m` | Scans AppDir for ELFs, resolves `DT_NEEDED` |
| `LibraryDeployer.h/.m` | Copies libraries, resolves symlinks, exclusion list |
| `InterpreterDeployer.h/.m` | Deploys ld-linux, musl detection |
| `test-chroot.sh` | POSIX sh script: Alpine chroot test with X11 forwarding |
| `PLAN.md` | Original implementation plan |
| `TECHNOLOGY.md` | This document |

## Build Pipeline

### 1. Source detection

Accepts either a source directory with `GNUmakefile` (runs `make install
DESTDIR=<AppDir>`) or a pre-built `.app` bundle (copied directly).

If the path ends with `.app` and contains a `GNUmakefile`, it is treated
as source; otherwise as a pre-built bundle.

### 2. AppDir structure

```
AppDir/
  usr/
    bin/                  # .app bundle or additional executables
    lib/                  # all bundled shared libraries
    local/bin/            # gdnc, gpbs, make_services
    lib/GNUstep/          # GNUstep.conf (relative paths -> AppDir root)
  System/Library/
    Bundles/              # libgnustep-back-*.bundle only (no prefPanes)
    Themes/               # Eau.theme (and others)
  Local/Applications/     # installed .app (from make install)
```

### 3. GNUstep configuration

`usr/lib/GNUstep/GNUstep.conf` uses relative paths (`../../../`) that
GNUstep resolves relative to the config file location, pointing into the
AppDir.  `GNUSTEP_USER_DIR` points to the AppDir root to prevent host
`$HOME` from leaking into the bundled environment.

### 4. Theme deployment

At build time, `defaults read NSGlobalDomain GSTheme` detects the
current system theme (typically `Eau`).  All `.theme` bundles are copied
from `/System/Library/Themes` and `/Local/Library/Themes`.
`GNUSTEP_THEME=<detected-theme>` is hardcoded in the AppRun binary.

### 5. Backend deployment

Only `libgnustep-back-*.bundle` and `libgnustep-xlib-*.bundle` are
deployed — no prefPanes, finder modules, printers, or other unrelated
bundles.  A symlink `libgnustep-back.bundle` -> `libgnustep-back-VERSION.bundle`
is created for compatibility.

### 6. Library dependency resolution

**ELF discovery.**  The entire AppDir is walked; every regular file
whose first four bytes are `\x7fELF` is recorded.

**Resolution.**  `ldd` is run on each ELF.  Lines matching
`<libname> => <path>` are parsed.  Transitive dependencies are resolved
recursively (circular references are skipped via a seen-set).

**Library search paths.**  Built from:
- Standard paths: `/usr/lib`, `/lib`, `/usr/lib64`, `/lib64`
- Multi-arch: `/usr/lib/x86_64-linux-gnu`, `/lib/x86_64-linux-gnu`
- `/etc/ld.so.conf` (include directives expanded via glob)
- `$LD_LIBRARY_PATH` from the build environment
- RPATH from each ELF (via `patchelf --print-rpath`)

**Standalone mode (default).**  The exclusion list is entirely bypassed.
Every library including `libc.so.6`, `libm.so.6`, `libpthread.so.0`,
`libstdc++.so.6`, `libgcc_s.so.1` is deployed.  This guarantees the
AppImage never loads a library from the host.

### 7. Library deployment

Resolved libraries are copied into `usr/lib/`.  Symlinks are resolved
to their real files via `readlink -f` before copying, preventing
dangling symlinks in the AppDir.

### 8. ld-linux (dynamic linker)

Detected via `patchelf --print-interpreter` (fallback `readelf -l`).
Resolved through symlinks and copied into the AppDir (e.g.,
`lib64/ld-linux-x86-64.so.2`).  **Not binary-patched** — doing so
breaks `$ORIGIN` expansion in RPATH.

On musl systems (Alpine), `ld-musl-x86_64.so.1` is detected alongside
the glibc variants.

### 9. Relative interpreter

`patchelf --set-interpreter ./lib64/ld-linux-x86-64.so.2` is run on
**every deployed ELF** — not just the main binary.  This ensures that
helper processes (gdnc, gpbs, make_services, and all shared libraries)
also use the bundled ld-linux when executed from any directory.

### 10. RPATH patching

Every ELF's RPATH is modified to append a `$ORIGIN`-relative path to
`usr/lib/`.  Original `$ORIGIN`-relative RPATH entries (like
`$ORIGIN/Resources`) are preserved.  Absolute RPATH entries are
discarded.  Result: every binary and library can find all its
dependencies inside the AppDir without `LD_LIBRARY_PATH`.

### 11. AppRun (compiled C binary)

The AppRun is a **statically linked C binary**, not a shell script.
This eliminates the `/bin/sh` dependency and allows the AppImage to
run in minimal environments (chroot, containers) where no shell is
available.

The AppRun:
1. Unsets host env vars (`LD_LIBRARY_PATH`, `GNUSTEP_*`, `LD_PRELOAD`)
2. Determines its own location via `readlink("/proc/self/exe")`
   (with `argv[0]` fallback when `/proc` is unavailable)
3. Sets `GNUSTEP_CONFIG_FILE`, `GNUSTEP_THEME`, `GNUSTEP_ROOT`,
   `GNUSTEP_SYSTEM_ROOT`, `GNUSTEP_LOCAL_ROOT`, `GNUSTEP_USER_DIR`,
   `HOME`, `LD_LIBRARY_PATH`, `PATH` to absolute paths inside the AppDir
4. Does **not** use `realpath()` — avoids doubling the chroot path
5. Changes to the AppDir root
6. `execv()` the main binary

### 12. Verification

After building, the tool checks that every dependency discovered during
resolution exists as a file inside `usr/lib/` or the app's `Resources/`
directory.  This is a file-existence check, not an `ldd` invocation
(which would use the system's ld-linux and give false positives).

### 13. Packaging

If `appimagetool` (from AppImageKit) is found, the AppDir is packaged
into a self-mounting ELF + squashfs AppImage.

## Testing: Alpine Linux chroot

`test-chroot.sh` is a POSIX sh script that:

1. Downloads a minimal Alpine Linux minirootfs (musl libc)
2. Extracts it into a temporary chroot
3. Gives the chroot internet access (copies `/etc/resolv.conf`)
4. Binds the host's `/tmp/.X11-unix` for display forwarding
5. Configures `/etc/passwd` for GNUstep
6. Installs `fontconfig` + `ttf-dejavu` + `ttf-liberation` via `apk`
7. Extracts the AppImage into the chroot
8. Starts `gdnc` with `LD_LIBRARY_PATH` for the GNUstep notification system
9. Runs the AppRun inside the chroot with `DISPLAY=$DISPLAY`

If the AppImage runs in this environment (musl libc, no glibc, no host
GNUstep), every library dependency is truly self-contained.

## Key design decisions

### Why a compiled binary for AppRun instead of a shell script?

A shell script requires `/bin/sh`, which may not exist in minimal
chroots or containers.  A static C binary has zero dependencies.

### Why relative interpreter on ALL ELFs?

Helper processes (gdnc, gpbs, make_services) are started by the app at
runtime.  If they still have the system's absolute interpreter path
(e.g., `/lib64/ld-linux-x86-64.so.2`), they won't run inside a chroot
where that path doesn't exist.  Setting the relative interpreter on
every ELF ensures every binary in the AppDir can execute independently.

### Why not patch ld-linux?

go-appimage binary-patches ld-linux to replace `/lib` → `/XXX`,
`/usr` → `/xxx`, `/etc` → `/EEE` to prevent fallback to host paths.
This breaks `$ORIGIN` expansion because the patching is done on the
entire binary — it corrupts the machine code that handles RPATH
resolution.  Since we use RPATH exclusively and strip absolute host
paths, patching is unnecessary.

### Why bundle libc, libm, etc.?

In standalone mode (the default), ALL libraries including `libc.so.6`
and `ld-linux.so.2` are bundled.  This is what makes the AppImage truly
distribution-independent — it works on both glibc and musl systems
because the app never touches the host's libc.

### Why PATH-based tool lookup?

Hardcoding `/usr/bin/patchelf`, `/bin/chmod`, etc. breaks on systems
where these tools are installed in different locations (BSD, NixOS,
custom prefixes).  `_findTool:` searches `$PATH` at build time,
resolving each tool by name.

### Why no LD_LIBRARY_PATH in AppRun?

`LD_LIBRARY_PATH` is inherited by ALL child processes, including system
tools that the app may spawn.  This can cause symbol mismatches.
RPATH is baked into each ELF and only affects that binary.

### Why detect theme at build time and hardcode it?

Runtime detection would require `defaults read NSGlobalDomain GSTheme`
inside the AppRun, which depends on the host user's settings.  Build-time
detection captures the exact theme that was active when the AppImage
was created, making it reproducible.

### Why preserve `$ORIGIN/Resources` in RPATH?

`.app` bundles contain libraries in their `Resources/` directory
(e.g., `Weather.app/Resources/libWebServices.so.0.9`).  The original
RPATH `$ORIGIN/Resources` is needed to find these.  Our RPATH patching
preserves this entry and appends the path to `usr/lib/`.

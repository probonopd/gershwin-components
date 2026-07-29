# make_appimage — Technology

## Goal

Package a GNUstep application (source directory with `GNUmakefile` or
pre-built `.app` bundle) into a standalone, relocatable Linux AppImage
that runs on any Linux distribution without requiring GNUstep or any
other runtime to be installed on the host system.

The AppImage must be **fully self-contained**: every shared library,
GNUstep bundle, theme, font, and resource must be loaded from inside
the AppDir. No file from the host system (`/lib`, `/usr/lib`, etc.) may
be referenced at runtime.

---

## Architecture

```
main.m  (CLI entry point)
  └── AppImageBuilder       — orchestrator, drives the entire pipeline
        ├── LibraryResolver      — ELF discovery, ldd-based dependency resolution
        ├── LibraryDeployer      — copies libraries into AppDir, exclusion logic
        ├── InterpreterDeployer  — ld-linux deployment, binary patching (optional)
        └── appimagetool         — external tool, produces final .AppImage
```

### Files

| File | Role |
|------|------|
| `main.m` | CLI argument parsing, creates `AppImageBuilder` |
| `AppImageBuilder.h/.m` | Orchestrates all build steps |
| `LibraryResolver.h/.m` | Scans AppDir for ELFs, resolves `DT_NEEDED` via `ldd`, searches library paths |
| `LibraryDeployer.h/.m` | Copies libraries into `usr/lib/`, honours exclusion list |
| `InterpreterDeployer.h/.m` | Copies `ld-linux`, optional binary path patching |
| `GNUmakefile` | GNUstep tool build, installs to `$GNUSTEP_SYSTEM_TOOLS` |

---

## Build Pipeline

### 1. Source detection

The tool accepts either:

- A source directory containing a `GNUmakefile` — runs `make install
  DESTDIR=<AppDir>` to build and install
- A pre-built `.app` bundle — copied directly into `usr/bin/`

The depth of the AppDir structure mirrors a real GNUstep installation:

```
AppDir/
  usr/
    bin/              # the .app bundle or GNUstep tools
    lib/              # bundled shared libraries
    local/bin/        # gdnc, gpbs, make_services
    lib/GNUstep/      # GNUstep.conf
  System/
    Library/
      Bundles/        # libgnustep-back-*.bundle (only)
      Themes/         # Eau.theme (and others)
  Local/
    Applications/     # the installed .app bundle (from make install)
    Library/
      Tools/          # additional tools
```

### 2. GNUstep configuration

A `GNUstep.conf` is generated at `usr/lib/GNUstep/GNUstep.conf` with
paths relative to that file's location (`../../..` reaches the AppDir
root).  GNUstep resolves these at runtime.

The configuration sets:

- `GNUSTEP_SYSTEM_LIBRARY` → `AppDir/System/Library`
- `GNUSTEP_LOCAL_LIBRARY` → `AppDir/Local/Library`
- `GNUSTEP_USER_DIR_LIBRARY` → same as Local (avoids host `$HOME`)
- `GNUSTEP_USER_DEFAULTS_DIR`, `GNUSTEP_USER_CONFIG_FILE` — empty,
  preventing interference from the host user's GNUstep defaults

### 3. Theme deployment

At build time, `defaults read NSGlobalDomain GSTheme` is queried to
find the current system theme (typically `Eau`).  All `.theme` bundles
from `/System/Library/Themes` and `/Local/Library/Themes` are copied
into `System/Library/Themes/` inside the AppDir.

The AppRun sets `GNUSTEP_THEME=<detected-theme>` so the app uses the
same theme it would on the host.

### 4. Backend deployment

Only `libgnustep-back-*.bundle` and `libgnustep-xlib-*.bundle` are
copied from `/System/Library/Bundles` and `/Local/Library/Bundles`.
PrefPanes, finder modules, printers, media codecs, and other unrelated
bundles are NOT deployed — they are not needed by the target
application and would bloat the AppImage unnecessarily.

A symlink `libgnustep-back.bundle → libgnustep-back-VERSION.bundle` is
created for compatibility.

### 5. Library dependency resolution

**Discovery.**  The entire AppDir is walked.  Every regular file whose
first four bytes are `\x7fELF` is recorded as an ELF.

**Resolution.**  For each ELF, `ldd` is run.  Lines matching
`<libname> => <path>` are parsed.  Each resolved library path is added
to a result set unless it is on the exclusion list.

**Exclusion list.**  In standalone mode (the default), the exclusion
list is **not applied** — every library that `ldd` reports is deployed.
This includes `libc.so.6`, `libm.so.6`, `libpthread.so.0`,
`libstdc++.so.6`, `libgcc_s.so.1`, and other libraries that are
normally provided by the host system.  Skipping these is what ensures
the AppImage never loads a library from the host.

**Transitive dependencies.**  Each resolved library is itself passed
through `ldd`, so transitive dependencies are also discovered and
deployed.  Circular references are tracked via a `_seenDeps` set.

**Library search paths.**  The resolver builds a list of directories
where libraries may be found:

  - Standard paths: `/usr/lib`, `/lib`, `/usr/lib64`, `/lib64`
  - Multi-arch paths: `/usr/lib/x86_64-linux-gnu`, `/lib/x86_64-linux-gnu`
  - Parsed from `/etc/ld.so.conf` (including `include` directives)
  - `$LD_LIBRARY_PATH` from the build environment
  - RPATH entries from each ELF (via `patchelf --print-rpath`)

### 6. Library deployment

All resolved libraries are copied into `usr/lib/` inside the AppDir.
Libraries already present in the AppDir (e.g., inside the `.app`
bundle's `Resources/`) are not copied again.

### 7. ld-linux (dynamic linker)

The ELF interpreter is detected via `patchelf --print-interpreter` on a
binary in the AppDir (falling back to `readelf -l`).  The detected
interpreter (e.g., `/lib64/ld-linux-x86-64.so.2`) is:

1. Resolved through symlinks (using `readlink -f`)
2. Copied into the AppDir at the same path (e.g., `lib64/ld-linux-x86-64.so.2`)
3. Made executable

The interpreter is **not** binary-patched (changing `/lib` → `/XXX`
etc.), because doing so breaks `$ORIGIN` resolution in RPATH.  Instead,
all library resolution is handled through RPATH (see below).

### 8. Relative interpreter

`patchelf --set-interpreter <relative-path>` is run on the main
executable, prepending `.` to the interpreter path.  This makes the
executable find the bundled `ld-linux` relative to its own location
when the AppRun does `cd "$HERE"` before executing it.

Example: `Weather` binary's interpreter becomes
`./lib64/ld-linux-x86-64.so.2`.

### 9. RPATH patching

Every ELF in the AppDir (binaries, libraries in `usr/lib/`,
`usr/local/lib/`) has its RPATH modified by appending a
`$ORIGIN`-relative path that points to `usr/lib/`.

The original RPATH (typically `$ORIGIN/Resources` for `.app` bundles,
or empty for system libraries) is preserved — only absolute paths
(starting with `/`) are discarded, because they would point to host
system paths that don't exist inside the AppDir.

For a binary at `Local/Applications/Weather.app/Weather`, the RPATH
becomes:

```
$ORIGIN/Resources:$ORIGIN/../../../usr/lib/
```

- `$ORIGIN/Resources` — finds app-bundled libraries like
  `libWebServices.so.0.9`
- `$ORIGIN/../../../usr/lib/` — finds deployed system libraries

Since the AppRun does `cd "$HERE"`, the relative interpreter path
resolves to the bundled `ld-linux`, which then uses the combined RPATH
to find every library inside the AppDir.  No `LD_LIBRARY_PATH` is
needed (or set) in the AppRun.

### 10. AppRun

The AppRun script:

1. Unserts host environment variables that could interfere
   (`LD_LIBRARY_PATH`, `GNUSTEP_*`, `LD_PRELOAD`, etc.)
2. Sets `GNUSTEP_CONFIG_FILE` to the bundled `GNUstep.conf`
3. Sets `GNUSTEP_THEME` to the theme detected at build time
4. Sets `FONTCONFIG_FILE` and `FONTCONFIG_PATH`
5. Sets `HOME` and `GNUSTEP_USER_DIR` (not overridden — uses real `$HOME`)
6. Changes to `$HERE` (the AppDir mount point)
7. Runs the main executable via the relative interpreter path

### 11. Verification

After all libraries are deployed and RPATHs are patched, the tool
checks that every dependency discovered during resolution exists as a
file somewhere inside the AppDir.  If any are missing, they are listed.

This verification is purely a file-existence check — it does not run
`ldd` inside the AppDir (which would give false positives because `ldd`
uses the system's `ld-linux`, not the bundled one).

### 12. Packaging

If `appimagetool` (from AppImageKit) is found, the AppDir is packaged
into a self-mounting ELF + squashfs AppImage.  The resulting file is a
single executable that, when run, mounts itself via FUSE and executes
the bundled `AppRun`.

---

## Why not just use LD_LIBRARY_PATH?

`LD_LIBRARY_PATH` is the simplest approach, but it has a fundamental
problem: it applies to ALL processes in the execution tree, including
child processes that the app spawns.  If a child process is a
non-GNUstep system tool, it inherits the AppDir's lib paths, which can
cause symbol mismatches, crashes, or undefined behaviour.

RPATH avoids this because it is baked into each ELF binary at build
time.  Only the specific binary and its direct dependencies use it.
Child processes that are new ELF files (like `/bin/sh`, `gdnc`, etc.)
won't inherit the RPATH and will use the system's default library
search, which is the correct behaviour.

---

## Why not patch ld-linux?

Binary-patching `ld-linux` (changing `/lib` → `/XXX`, `/usr` → `/xxx`,
`/etc` → `/EEE`) is a technique used by go-appimage to prevent the
dynamic linker from falling back to host system paths.  However, this
patching also replaces occurrences of these strings inside the
machine code that handles `$ORIGIN` expansion, which can cause crashes
or incorrect path resolution.

Since our AppImages use RPATH exclusively (no LD_LIBRARY_PATH), and
absolute host RPATHs are stripped, the bundled `ld-linux` never
attempts to search host paths.  Patching is unnecessary.

---

## Portability

The tool uses `NSTask` to run external tools (`ldd`, `patchelf`,
`readelf`, `readlink`, `chmod`, `make`, `gnustep-config`, `uname`,
`appimagetool`, `defaults`).  Rather than hardcoding absolute paths
like `/usr/bin/patchelf`, each tool is located via `$PATH` at build
time.  This makes the tool work on any Linux distribution or BSD where
these tools exist, regardless of their installation path.

Similarly, all library search paths are multi-arch aware and parse
`/etc/ld.so.conf` for distribution-specific directories.

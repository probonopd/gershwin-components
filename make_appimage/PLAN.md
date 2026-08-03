# make_appimage — Implementation Plan

Port library dependency resolution, ld-linux handling, and glibc deployment
from go-appimage to Objective-C / GNUstep.

## Architecture

```
main.m
  └── BundleBuilder (main class)
        ├── LibraryResolver          — ELF dependency scanning via ldd/patchelf
        ├── InterpreterDeployer      — ld-linux detection, patching, deployment
        ├── LibraryDeployer          — libc handling, exclusion, copy to AppDir
        ├── AppImagePackager         — appimagetool invocation, desktop/icon
        └── AppRun (precompiled)     — AppRun binary used as entry point
```

## Files

| File | Responsibility |
|------|---------------|
| `main.m` | CLI entry point, argument parsing via NSProcessInfo |
| `BundleBuilder.h/.m` | Orchestrator: copy .app bundle → resolve deps → deploy → package |
| `AppImagePackager.h/.m` | appimagetool invocation and desktop/icon generation |
| `LibraryResolver.h/.m` | Find all ELFs, resolve DT_NEEDED via ldd, search library paths |
| `InterpreterDeployer.h/.m` | Detect ld-linux via patchelf, copy, binary-patch paths |
| `LibraryDeployer.h/.m` | Filter excluded libs, copy to AppDir, optional libc/ subdir |
| `GNUmakefile` | GNUstep tool build (builds the tools and AppRun helper) |

## Data Flow

1. `BundleBuilder -build`
   → copy the built `.app` bundle into AppDir (no source build)
   → scan AppDir for ELF binaries
   → resolve all DT_NEEDED dependencies
   → deploy ld-linux (patchelf + binary patch)
   → deploy required libraries (skip excluded list)
   → create AppRun + .desktop
   → run appimagetool

The input is always an already-built `.app` bundle; no GNUmakefile of the
application is ever invoked. The project's own `GNUmakefile` only builds the
`make_appimage`/`make_standalone` tools and the `AppRun` helper binary.

## Library Resolution (ported from go-appimage)

- Walk AppDir, find ELF files (check magic bytes `\x7fELF`)
- For each ELF, run `ldd` and parse "`lib => /path`" lines
- Search for each dependency in:
  - Standard paths: /usr/lib, /lib, /usr/lib64, /lib64
  - Platform paths: /usr/lib/x86_64-linux-gnu, /lib/x86_64-linux-gnu
  - `/etc/ld.so.conf` includes (recurse `include` directives)
  - `$LD_LIBRARY_PATH`
  - Existing rpaths from the ELF itself (via `patchelf --print-rpath`)
- Track seen deps to avoid circular resolution
- Also resolve deps for each discovered dependency (transitive)

## ld-linux Handling

- Detect via `patchelf --print-interpreter <main-binary>`
- Copy ld-linux to AppDir preserving full path (e.g., /lib64/ld-linux-x86-64.so.2)
- Binary-patch the copied ld-linux:
  - `/lib` → `/XXX`
  - `/usr` → `/xxx`
  - `/etc` → `/EEE`
- Set executable permissions

## glibc / Library Deployment

Excluded libraries (from go-appimage's ExcludedLibraries list):
ld-linux.so.2, ld-linux-x86-64.so.2, libanl.so.1, libBrokenLocale.so.1,
libcidn.so.1, libc.so.6, libdl.so.2, libm.so.6, libmvec.so.1,
libnss_*.so.*, libpthread.so.0, libresolv.so.2, librt.so.1,
libthread_db.so.1, libutil.so.1, libstdc++.so.6, libGL.so.1,
libEGL.so.1, libGLdispatch.so.0, libGLX.so.0, libdrm.so.2,
libglapi.so.0, libgbm.so.1, libxcb.so.1, libX11.so.6,
libgio-2.0.so.0, libasound.so.2, libgdk_pixbuf-2.0.so.0,
libfontconfig.so.1, libthai.so.0, libfreetype.so.6,
libharfbuzz.so.0, libcom_err.so.2, libexpat.so.1, libgcc_s.so.1,
libglib-2.0.so.0, libgpg-error.so.0, libICE.so.6,
libp11-kit.so.0, libSM.so.6, libusb-1.0.so.0, libuuid.so.1,
libz.so.1, libgobject-2.0.so.0, libpangoft2-1.0.so.0,
libpangocairo-1.0.so.0, libpango-1.0.so.0, libjack.so.0,
libxcb-dri3.so.0, libxcb-dri2.so.0, libfribidi.so.0, libgmp.so.10

Copied libraries go to `AppDir/usr/lib/`.
When using the libc subdirectory feature, libc-family libraries
(ld-*, libc-*, libm-*, libpthread-*, etc.) go to `AppDir/libc/`.

## Rpath Patching

- For each deployed ELF, use `patchelf --set-rpath` with `$ORIGIN/`-relative paths
- Skip rpath patching for ld-* and libc.* files
- Compute relative paths from each ELF's directory to `usr/lib` and `libc/`

## AppRun Script

Generate a shell script that:
- Sets `HERE` to AppDir root
- Exports GNUSTEP_CONFIG_FILE, LD_LIBRARY_PATH, PATH
- Finds ld-linux if bundled and runs main binary through it
- Falls back to direct execution if ld-linux is not found

## Build

```makefile
TOOL_NAME = make_appimage
make_appimage_OBJC_FILES = main.m AppImageBuilder.m LibraryResolver.m \
    InterpreterDeployer.m LibraryDeployer.m
make_appimage_TOOL_LIBS = -lgnustep-base -lobjc
```

Install to GNUSTEP_SYSTEM_TOOLS (/System/Library/Tools).

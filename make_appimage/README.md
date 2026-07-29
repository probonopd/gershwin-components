# make_appimage

Package a GNUstep application as a Linux AppImage.

## Usage

```sh
make_appimage [options] <app-name>
```

`<app-name>` is the name of a GNUstep app directory containing a `GNUmakefile`,
or a path to a built `.app` bundle.

### Options

| Flag | Description |
|------|-------------|
| `-o <file>` | Output filename (default: `<app>-<version>-<arch>-<os>.AppImage`) |
| `-d <dir>` | Working directory for the AppDir build (default: `/tmp/appimage-<app>`) |
| `-c <comment>` | Comment text for the `.desktop` file |
| `-C <cat>` | Desktop categories, e.g. `"Utility;"` |
| `-e <path>` | Main executable path relative to AppDir root (auto-detected if omitted) |
| `-t <tool>` | Path to `appimagetool` (default: `appimagetool` in `PATH`) |
| `-h` | Show help |

## Examples

```sh
# Basic usage — app name matching a subdirectory with GNUmakefile
make_appimage TextEdit

# Specify output file and working directory
make_appimage -o MyApp.AppImage -d /tmp/myapp Terminal

# Explicit main executable path
make_appimage -e /usr/bin/SystemPreferences SystemPreferences
```

## Requirements

- `appimagetool` — install from [AppImageKit](https://github.com/AppImage/AppImageKit)
- `patchelf` — for ELF interpreter detection and rpath patching
- `ldd` — for shared library dependency resolution
- GNUstep build tools (to compile the application into the AppDir)

## What it does

1. Builds the application into a temporary AppDir via `make install DESTDIR=...`
2. Scans the AppDir for ELF binaries and resolves all shared library dependencies
3. Deploys `ld-linux` (the dynamic linker) with embedded path patching
4. Copies required libraries into `usr/lib/`, skipping system libraries that are expected on the host
5. Generates an `AppRun` entry point and a `.desktop` file
6. Bundles GNUstep backends and tools into the AppDir
7. Runs `appimagetool` to produce the final self-contained AppImage

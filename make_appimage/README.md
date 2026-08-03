# make_appimage

Package a GNUstep application as a Linux AppImage. The input is an
already-built `.app` bundle; the tool deploys all GNUstep dependencies and
produces a self-contained AppImage.

## Usage

```sh
make_appimage [options] <app-name>
```

`<app-name>` is a path to a built `.app` bundle (or its bare name, resolved
against the standard application directories). Source trees with `GNUmakefile`
are not supported - build the app first, then package the resulting bundle.

### Options

| Flag | Description |
|------|-------------|
| `-o <file>` | Output filename (default: `<app>-<version>-<arch>-<os>.AppImage`) |
| `-d <dir>` | Working directory for the AppDir build (default: `/tmp/appimage-<app>`) |
| `-c <comment>` | Comment text for the `.desktop` file |
| `-C <cat>` | Desktop categories, e.g. `"Utility;"` |
| `-e <path>` | Main executable path relative to AppDir root (auto-detected if omitted) |
| `-t <tool>` | Path to `appimagetool` (default: `appimagetool` in `PATH`) |
| `--framework <name>` | Deploy framework (repeatable); auto-detected if unset |
| `--extra-bundle <name>` | Deploy additional bundle (repeatable); e.g. `ImageThumbnailer.thumb` |
| `-h` | Show help |

## Examples

```sh
# Package a built .app bundle
make_appimage /System/Library/CoreServices/Applications/Menu.app

# Specify output file and working directory
make_appimage -o MyApp.AppImage -d /tmp/myapp /System/Applications/Terminal.app

# Explicit main executable path
make_appimage -e /usr/bin/SystemPreferences /System/Applications/SystemPreferences.app

# Deploy additional bundles (thumbnailers, finder modules, inspectors)
make_appimage \
  --extra-bundle ImageThumbnailer.thumb \
  --extra-bundle FModuleName.finder \
  --extra-bundle FModuleKind.finder \
  --extra-bundle FModuleSize.finder \
  --extra-bundle FModuleOwner.finder \
  --extra-bundle FModuleCrDate.finder \
  --extra-bundle FModuleModDate.finder \
  --extra-bundle FModuleContents.finder \
  --extra-bundle FModuleAnnotations.finder \
  --extra-bundle AppViewer.inspector \
  --extra-bundle FolderViewer.inspector \
  --extra-bundle MDModuleAnnotations.mdm \
  /System/Library/CoreServices/Applications/Workspace.app
```

## Requirements

- `appimagetool` — download from [here](https://github.com/AppImage/appimagetool/releases), set the executable bit, and rename it to `/usr/local/bin/appimagetool`
- `patchelf` — for ELF interpreter detection and rpath patching
- `ldd` — for shared library dependency resolution
- An already-built `.app` bundle (no GNUstep build tools needed at packaging time)

## What it does

1. Copies the built `.app` bundle into a temporary AppDir
2. Scans the AppDir for ELF binaries and resolves all shared library dependencies
3. Deploys `ld-linux` (the dynamic linker) with embedded path patching
4. Copies required libraries into `usr/lib/`, skipping system libraries that are expected on the host
5. Generates an `AppRun` entry point and a `.desktop` file
6. Bundles GNUstep backends, frameworks, and extra bundles into the AppDir
7. Runs `appimagetool` to produce the final self-contained AppImage

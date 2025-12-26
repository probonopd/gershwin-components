# appwrap

`appwrap` is a CLI tool that creates GNUstep application bundles from freedesktop `.desktop` files. This allows you to wrap any desktop application into a GNUstep app bundle that can be launched from the system.

## Usage

```bash
appwrap [OPTIONS] /path/to/application.desktop [output_directory]
```

### Arguments

- `/path/to/application.desktop` - Path to a freedesktop .desktop file
- `[output_directory]` - (Optional) Directory where the app bundle will be created. 
  - If not specified for non-root users: `~/Applications` (created if it doesn't exist)
  - If not specified for root: `/Local/Applications` (created if it doesn't exist)

### Options

- `-f, --force` - Overwrite existing app bundle without asking for confirmation

## Examples

Create a Chromium app bundle in the default location (~Applications as non-root):
```bash
appwrap /usr/share/applications/chromium.desktop
```

Create a Firefox app bundle in a custom directory:
```bash
appwrap /usr/share/applications/firefox.desktop /opt/applications
```

Overwrite an existing app bundle without confirmation:
```bash
appwrap -f /usr/share/applications/chromium.desktop
appwrap --force /usr/share/applications/firefox.desktop /opt/applications
```

### Overwrite Behavior

- If an app bundle already exists at the destination, `appwrap` will prompt you for confirmation
- You can bypass this prompt by using the `-f` or `--force` flag
- When overwriting, the entire existing bundle is deleted and replaced with a fresh one

## What It Does

`appwrap` parses a freedesktop `.desktop` file and creates a GNUstep application bundle with the following structure:

```
ApplicationName.app/
├── ApplicationName           (launcher script)
└── Resources/
    ├── Info.plist           (GNUstep metadata)
    └── [AppName].[ext]      (icon file, if found)
```

### Features

- **Parses .desktop files** - Extracts Name, Exec, Icon, and Version information
- **Creates proper GNUstep bundles** - Generates valid Info.plist and executable structure
- **Icon support** - Automatically searches for and copies application icons from standard locations
- **Launcher script** - Creates a shell wrapper that executes the original application command
- **Works with any app** - Compatible with any application that has a .desktop file

## Building

```bash
cd appwrap
gmake
```

The compiled binary will be available at `obj/appwrap`.

### Installation

To install appwrap system-wide:

```bash
cd appwrap
sudo -E gmake install
```

The tool will be installed to `/Local/Library/Tools/appwrap`. Make sure this directory is in your PATH, or you can use the full path to invoke it.

## Icon Resolution

`appwrap` searches for application icons in the following locations:

- `/usr/share/icons/hicolor/256x256/apps`
- `/usr/share/icons/hicolor/128x128/apps`
- `/usr/share/icons/hicolor/96x96/apps`
- `/usr/share/icons/hicolor/64x64/apps`
- `/usr/share/icons/hicolor/48x48/apps`
- `/usr/share/pixmaps`
- `/usr/local/share/pixmaps`

Supported icon formats: `.png`, `.svg`, `.xpm`, or no extension.

If an icon cannot be found, the bundle is created without an icon and a warning is displayed.
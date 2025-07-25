# GlobalShortcuts Preference Pane

A GNUstep preference pane for configuring global keyboard shortcuts managed by the `globalshortcutsd` daemon.

## Features

- View all configured global shortcuts
- Add new keyboard shortcuts with commands
- Edit existing shortcuts
- Delete shortcuts
- Real-time status monitoring of `globalshortcutsd` daemon
- Automatic configuration management via GlobalShortcuts
- Automatic daemon configuration reload via SIGHUP signal

## Building

```sh
gmake
```

## Installing

```sh
sudo gmake install
```

This installs the preference pane to `/System/Library/Bundles/GlobalShortcuts.prefPane`.

## Testing

After building and installing, run SystemPreferences:

```sh
/System/Applications/SystemPreferences.app/SystemPreferences
```

The "Global Shortcuts" pane should appear in the preferences window.

## Usage

1. **Adding Shortcuts**: Click the "Add" button to create a new keyboard shortcut. Enter the key combination (e.g., "ctrl+shift+t") and the command to execute (e.g., "xterm").

2. **Editing Shortcuts**: Select a shortcut from the list and click "Edit" to modify the key combination or command.

3. **Deleting Shortcuts**: Select a shortcut and click "Delete" to remove it.

4. **Key Combination Format**: Use the same format as globalshortcutsd:
   - Modifiers: `ctrl`, `shift`, `alt`, `mod1-mod5`
   - Keys: `a-z`, `0-9`, `f1-f24`, `space`, `return`, `tab`, etc.
   - Multimedia keys: `volume_up`, `volume_down`, `volume_mute`, etc.
   - Examples: `ctrl+shift+t`, `alt+f2`, `volume_up`

5. **Configuration Storage**: All shortcuts are saved to GlobalShortcuts and applied automatically.

6. **Daemon Integration**: The preference pane automatically detects if globalshortcutsd is running and sends SIGHUP signals to reload configuration when changes are made.

## Requirements

- GNUstep development environment
- PreferencePanes framework
- globalshortcutsd daemon (for actual shortcut functionality)

## Configuration Storage

The preference pane manages shortcuts via the GlobalShortcuts domain. The format is a dictionary where keys are the key combinations and values are the commands:

```
GlobalShortcuts = {
    "ctrl+shift+t" = "Terminal";
    "volume_up" = "amixer set Master 5%+";
}
```

You can also set shortcuts manually using the defaults command:

```sh
# Set individual shortcuts
defaults write GlobalShortcuts ctrl+shift+t Terminal
```

Changes made through the preference pane are immediately written to GlobalShortcuts and the globalshortcutsd daemon is notified to reload its configuration.
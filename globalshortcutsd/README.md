# globalshortcutsd

A GNUstep-based global keyboard shortcuts daemon.

## Features

- Global keyboard shortcuts
- Multiple configuration methods (config file and GNUstep defaults)
- Simple key combination syntax with comprehensive key support
- Production-ready daemon with proper error handling
- Automatic PATH searching for executables
- Configuration reload via SIGHUP signal
- Automatic config file monitoring and reloading
- Process isolation and security features
- Comprehensive logging and verbose mode
- Lock file to prevent multiple instances

## Requirements

- GNUstep development environment
- X11 development libraries (libX11-dev)
- clang19 compiler
- FreeBSD or compatible Unix system

## Building

```sh
gmake
```

### Installing

```sh
sudo gmake install
```

This installs to `/usr/local/bin` by default. You can specify a different prefix:

```sh
sudo gmake install PREFIX=/usr
```

### Uninstalling

```sh
sudo gmake uninstall
```

## Configuration

Configure shortcuts using the GNUstep defaults system:

```sh
# Set up some basic shortcuts
defaults write GlobalShortcuts '{
    "ctrl+shift+t" = "Terminal";
}'
```

You can also add or update individual shortcuts:

```sh
# Add or update a single shortcut
defaults write GlobalShortcuts -dict-add "ctrl+alt+t" "Terminal"
```

### Key Combination Format

Key combinations use the format: `modifier+modifier+key`

**Modifiers:**
- `ctrl` or `control` - Control key
- `shift` - Shift key  
- `alt` or `mod1` - Alt key
- `mod2`, `mod3`, `mod4`, `mod5` - Additional modifier keys

**Keys:**
- Letters: `a-z`
- Numbers: `0-9`
- Function keys: `f1-f24`
- Special keys: `space`, `return`/`enter`, `tab`, `escape`/`esc`, `backspace`, `delete`, `home`, `end`, `page_up`, `page_down`, `up`, `down`, `left`, `right`
- Multimedia keys: `volume_up`, `volume_down`, `volume_mute`, `play_pause`, `stop`, `prev`, `next`, `rewind`, `forward`, `brightness_up`, `brightness_down`, `mail`, `www`, `homepage`, `search`, `calculator`, `sleep`, `wakeup`, `power`, `screensaver`, `standby`, `record`, `eject`
- Raw keycodes: `code:28` (where 28 is the keycode number)

## Usage

```sh
# Run the daemon
./obj/globalshortcutsd

# Run with verbose output
./obj/globalshortcutsd -v

# Show help
./obj/globalshortcutsd -h
```

## Signals

- **SIGTERM/SIGINT/SIGQUIT**: Graceful shutdown (supports Ctrl+C and Ctrl+D style termination)
- **SIGHUP**: Reload configuration from defaults

```sh
# Reload configuration
killall -HUP globalshortcutsd

# Graceful shutdown
killall -TERM globalshortcutsd
```

## Examples

```sh
# Terminal shortcut
defaults write GlobalShortcuts -dict-add "ctrl+alt+t" "Terminal"

# Application launcher
defaults write GlobalShortcuts -dict-add "alt+f2" "Launcher"

# Lock screen
defaults write GlobalShortcuts -dict-add "ctrl+alt+l" "ScreenLock"

# Volume control
defaults write GlobalShortcuts -dict-add "ctrl+shift+equal" "VolumeControl --increase"
defaults write GlobalShortcuts -dict-add "ctrl+shift+minus" "VolumeControl --decrease"

# Raw keycode example (useful for special keys)
defaults write GlobalShortcuts -dict-add "ctrl+shift+code:28" "echo Raw keycode 28 pressed"
```

## Multimedia Keys

globalshortcutsd includes comprehensive support for multimedia keys:

**Audio Controls:**
- `volume_up`, `volume_down`, `volume_mute`
- `play_pause`, `stop`, `prev`, `next`, `rewind`, `forward`
- `record`

**Display Controls:**
- `brightness_up`, `brightness_down`
- `screensaver`, `standby`

**Application Shortcuts:**
- `www` - Web browser
- `mail` - Email client  
- `homepage` - Home page
- `search` - Search application
- `calculator` - Calculator

**Power Management:**
- `sleep`, `wakeup`, `power`

**Hardware:**
- `eject` - Eject CD/DVD

Example multimedia configuration:
```sh
defaults write GlobalShortcuts '{
    "volume_up" = "VolumeControl --increase";
    "volume_down" = "VolumeControl --decrease";
    "volume_mute" = "VolumeControl --toggle";
    "brightness_up" = "DisplayManager --brightness-up";
    "brightness_down" = "DisplayManager --brightness-down";
    "www" = "Browser";
}'
```
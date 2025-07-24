# globalshortcutsd

A robust, production-ready GNUstep-based global keyboard shortcuts daemon for X11.

## Features

- Global keyboard shortcuts using X11
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

### Method 1: Configuration File (Recommended)

Create a configuration file at `~/.globalshortcutsrc`:

```
# Global shortcuts configuration
# Format: key_combination=command

# Terminal shortcuts
ctrl+shift+t=xterm
ctrl+alt+t=gnome-terminal

# Application launchers
ctrl+shift+f=firefox
alt+f2=dmenu_run
ctrl+alt+l=xscreensaver-command -lock

# Volume controls
ctrl+shift+equal=amixer set Master 5%+
ctrl+shift+minus=amixer set Master 5%-
ctrl+shift+0=amixer set Master toggle

# Multimedia keys
volume_up=amixer set Master 5%+
volume_down=amixer set Master 5%-
volume_mute=amixer set Master toggle
brightness_up=xbacklight -inc 10
brightness_down=xbacklight -dec 10
```

### Method 2: GNUstep Defaults (Fallback)

Configure shortcuts using the GNUstep defaults system:

```sh
# Set up some basic shortcuts
defaults write NSGlobalDomain GlobalShortcuts '{
    "ctrl+shift+t" = "xterm";
    "ctrl+shift+f" = "firefox";
    "ctrl+alt+l" = "xscreensaver-command -lock";
}'
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
defaults write NSGlobalDomain GlobalShortcuts -dict-add "ctrl+alt+t" "Terminal"

# Application launcher
defaults write NSGlobalDomain GlobalShortcuts -dict-add "alt+f2" "Launcher"

# Lock screen
defaults write NSGlobalDomain GlobalShortcuts -dict-add "ctrl+alt+l" "ScreenLock"

# Volume control
defaults write NSGlobalDomain GlobalShortcuts -dict-add "ctrl+shift+equal" "VolumeControl --increase"
defaults write NSGlobalDomain GlobalShortcuts -dict-add "ctrl+shift+minus" "VolumeControl --decrease"

# Raw keycode example (useful for special keys)
defaults write NSGlobalDomain GlobalShortcuts -dict-add "ctrl+shift+code:28" "echo Raw keycode 28 pressed"
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
defaults write NSGlobalDomain GlobalShortcuts '{
    "volume_up" = "VolumeControl --increase";
    "volume_down" = "VolumeControl --decrease";
    "volume_mute" = "VolumeControl --toggle";
    "brightness_up" = "DisplayManager --brightness-up";
    "brightness_down" = "DisplayManager --brightness-down";
    "www" = "Browser";
}'
```
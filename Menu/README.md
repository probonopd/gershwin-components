# Menu.app for GNUstep

A GNUstep port of the Menu global menu bar application with DBus app menu support.

## Overview

This application provides a global menu bar that displays application menus at the top of the screen. It uses DBus to communicate with applications that export their menus using the `com.canonical.AppMenu.Registrar` and `com.canonical.dbusmenu` specifications.

## Features

- Global menu bar displayed at the top of the screen
- DBus-based application menu import
- Real-time active window tracking
- GNUstep/Objective-C implementation
- No glib/gio dependencies (uses libdbus directly)

## Dependencies

### Required Libraries
- GNUstep Base (`gnustep-base-dev`)
- GNUstep GUI (`gnustep-gui-dev`) 
- libdbus-1 (`libdbus-1-dev`)
- X11 libraries (`libx11-dev`)

### Build Tools
- GNUstep Make (`gnustep-make`)
- clang19 compiler
- GNU Make (`gmake`)

## Building

```bash
# Make sure GNUstep environment is set up
. /usr/share/GNUstep/Makefiles/GNUstep.sh

# Build the application
gmake clean
gmake

# Install system-wide
sudo gmake install
```

## Installation

The application will be installed to `/usr/GNUstep/System/Applications/Menu.app`.

## Usage

### Starting the Menu Bar

```bash
# Start from command line
/usr/GNUstep/System/Applications/Menu.app/Menu

# Or launch using openapp
openapp Menu
```

### Application Integration

Applications can export their menus to the global menu bar by implementing the DBus menu specification:

1. Register with the `com.canonical.AppMenu.Registrar` service
2. Export menus using the `com.canonical.dbusmenu` interface
3. Set window properties to associate menus with windows

## Technical Details

### Architecture

- **MenuController**: Main application controller, manages the menu bar window
- **MenuBarView**: Custom view that renders the menu bar background
- **AppMenuWidget**: Widget that displays application menus as buttons
- **DBusMenuImporter**: Handles DBus communication for menu import
- **DBusConnection**: Low-level DBus wrapper (no glib dependencies)
- **MenuUtils**: X11 utilities for window management

### DBus Interfaces

The application implements these DBus interfaces:

- `com.canonical.AppMenu.Registrar` - For applications to register their menus
- `com.canonical.dbusmenu` - For accessing exported application menus

### Window Management

Uses X11 directly to:
- Track the active window
- Get window properties
- Monitor window focus changes

## Configuration

### Positioning

The menu bar is positioned at the top of the primary screen with:
- Height: 24 pixels
- Width: Full screen width
- Level: Above main menu (NSMainMenuWindowLevel + 1)

### Appearance

- Semi-transparent background with gradient
- System font at 13pt for menu items
- 4px spacing between menu buttons
- 16px padding inside buttons

## Troubleshooting

### DBus Connection Issues

If the application fails to connect to DBus:

```bash
# Check if DBus session is running
echo $DBUS_SESSION_BUS_ADDRESS

# Start DBus session if needed
eval `dbus-launch --auto-syntax`
```

### X11 Display Issues

If the application cannot access X11:

```bash
# Make sure DISPLAY is set
echo $DISPLAY

# Check X11 access
xauth list
```

### GNUstep Environment

Make sure GNUstep environment is properly configured:

```bash
# Source the GNUstep environment
. /usr/local/share/GNUstep/Makefiles/GNUstep.sh

# Check environment variables
echo $GNUSTEP_SYSTEM_ROOT
echo $GNUSTEP_LOCAL_ROOT
```

## Development

### Debugging

Enable debug logging by setting:

```bash
export NSDebugEnabled=YES
export GSDebugAllocation=YES
```

### Code Style

The code follows these conventions:
- Objective-C 2.0 syntax where possible
- Manual memory management (retain/release)
- Extensive NSLog debugging
- 24px spacing for UI elements (20px from top/bottom)
- KVO for property observation where appropriate

### Testing

Test with applications that support app menu export:
- GTK applications with `ubuntu-menuproxy`
- Qt applications with `-platformtheme gtk3`
- Applications using `libdbusmenu`

## Contributing

When contributing:
- Follow the existing code style
- Add extensive logging for debugging
- Test with real applications
- Ensure no glib dependencies are introduced
- Use manual memory management (no ARC)

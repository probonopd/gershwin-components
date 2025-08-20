# Menu.app for GNUstep

A GNUstep port of the Menu global menu bar application with DBus app menu support.

## Overview

This application provides a global menu bar that displays application menus at the top of the screen. It uses DBus to communicate with applications that export their menus using either:
* The Canonical protocol (`com.canonical.AppMenu.Registrar` and `com.canonical.dbusmenu`) (applications export their menus to Menu.app), or
* The GTK protocol (`org.gtk.Menus` and `org.gtk.Actions`) (Menu.app queries applications for their menus), or
* The native GNUstep protocol (still to be implemented)

## Features

- Global menu bar displayed at the top of the screen
- DBus-based application menu import supporting the Canonical and the GTK protocols
- GNUstep/Objective-C implementation
- No glib/gio dependencies (uses libdbus directly)

## Dependencies

### Required Libraries for Building
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
- 
## Troubleshooting

### DBus Connection Issues

If the application fails to connect to DBus:

```bash
# Check if DBus session is running
echo $DBUS_SESSION_BUS_ADDRESS

# Start DBus session if needed
eval `dbus-launch --auto-syntax`
```

## Development

### GNUstep Environment

Make sure GNUstep environment is properly configured:

```bash
# Source the GNUstep environment
. /usr/local/share/GNUstep/Makefiles/GNUstep.sh

# Check environment variables
echo $GNUSTEP_SYSTEM_ROOT
echo $GNUSTEP_LOCAL_ROOT
```

### Testing

- Qt application (qvlc) with `QT_QPA_PLATFORMTHEME=kde`
- GTK 2 application (leafpad) with appmenu-gtk-module
- GTK 2 application (gedit) with appmenu-gtk-module

## Contributing

When contributing:
- Follow the existing code style
- Add extensive logging for debugging
- Test with real applications
- Ensure no glib dependencies are introduced
- Use manual memory management (no ARC)

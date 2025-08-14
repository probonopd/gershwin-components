#!/bin/sh

# Start Menu.app for Gershwin
# This script sets up the environment and starts the global menu bar

export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/dbus-glheQdxg7x,guid=4e90d1edd45dc9a0c34ab11b689d7df9

# Make sure we have a DBus session
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    echo "Starting DBus session..."
    eval `dbus-launch --auto-syntax`
    export DBUS_SESSION_BUS_ADDRESS
fi

# Make sure we have GNUstep environment
if [ -z "$GNUSTEP_SYSTEM_ROOT" ]; then
    . /System/Library/Makefiles/GNUstep.sh
fi

# Make sure we have X11 display
if [ -z "$DISPLAY" ]; then
    export DISPLAY=:0
fi

# Export environment variables for application menu support
export UBUNTU_MENUPROXY=1
export APPMENU_DISPLAY_BOTH=0

# Set desktop environment to enable menu exporting in applications
export XDG_CURRENT_DESKTOP=Unity
export DESKTOP_SESSION=unity
export XDG_SESSION_DESKTOP=unity
export UNITY_HAS_3D_SUPPORT=true
export UNITY_DEFAULT_PROFILE=unity

echo "Starting Menu.app with DBus session: $DBUS_SESSION_BUS_ADDRESS"
echo "Using display: $DISPLAY"
echo "UBUNTU_MENUPROXY: $UBUNTU_MENUPROXY"

# Start the Menu application
exec ./Menu.app/Menu

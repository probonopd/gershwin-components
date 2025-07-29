#!/bin/sh

# Script to test dbus-send with MiniBus
echo "Testing dbus-send with MiniBus..."

# Check if socket exists
if [ ! -S /tmp/minibus-socket ]; then
    echo "MiniBus socket not found at /tmp/minibus-socket"
    exit 1
fi

echo "Socket found, testing Hello method..."

# Set environment and test
export DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/minibus-socket"

# Test the Hello method
timeout 10 dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.Hello

echo "Test completed."

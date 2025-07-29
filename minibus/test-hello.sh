#!/bin/bash
# Test script for D-Bus daemon Hello message compliance

echo "=== Starting D-Bus daemon test ==="

# Kill any existing daemon
pkill -f minibus
sleep 1

# Clean up socket
rm -f /tmp/dbus-session

# Start daemon in background
echo "Starting daemon..."
export DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/minibus-socket"
timeout 30 ./obj/minibus &
DAEMON_PID=$!
sleep 2

# Test with dbus-send
echo "Testing with dbus-send..."
timeout 10 dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.Hello 2>&1

# Clean up
echo "Cleaning up..."
kill $DAEMON_PID 2>/dev/null
wait $DAEMON_PID 2>/dev/null
rm -f /tmp/dbus-session

echo "=== Test complete ==="

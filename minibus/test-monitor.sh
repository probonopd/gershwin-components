#!/bin/bash
# Test with dbus-monitor

echo "=== Testing with dbus-monitor ==="

# Kill any existing daemon
pkill -f minibus
sleep 1

# Clean up socket
rm -f /tmp/minibus-socket

# Start daemon in background  
echo "Starting daemon..."
export DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/minibus-socket"
./obj/minibus &
DAEMON_PID=$!
sleep 2

# Start dbus-monitor in background
echo "Starting dbus-monitor..."
timeout 10 dbus-monitor --session &
MONITOR_PID=$!
sleep 1

# Try dbus-send
echo "Sending Hello with dbus-send..."
timeout 5 dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.Hello

# Wait a moment
sleep 1

# Clean up
echo "Cleaning up..."
kill $DAEMON_PID $MONITOR_PID 2>/dev/null
wait $DAEMON_PID $MONITOR_PID 2>/dev/null
rm -f /tmp/minibus-socket

echo "=== Test complete ==="

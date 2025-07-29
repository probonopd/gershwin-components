#!/bin/bash

echo "=== Testing Different D-Bus Tools ==="

echo "1. Testing with a real dbus-daemon for comparison..."

# Clean up
pkill -f "dbus-daemon.*session" || true
rm -f /tmp/real-test-socket

# Start real daemon
dbus-daemon --session --address="unix:path=/tmp/real-test-socket" --nofork &
REAL_PID=$!
sleep 2

echo "Real daemon started with PID $REAL_PID"

# Test with dbus-send
echo "Testing dbus-send with real daemon..."
timeout 5 dbus-send --address="unix:path=/tmp/real-test-socket" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames > real-test-output.log 2>&1

echo "Real daemon result:"
cat real-test-output.log

# Clean up real daemon
kill $REAL_PID 2>/dev/null || true
rm -f /tmp/real-test-socket

echo ""
echo "2. Testing with MiniBus..."

# Start our daemon  
rm -f /tmp/minibus-test-socket
./obj/minibus /tmp/minibus-test-socket > minibus-test-daemon.log 2>&1 &
MINIBUS_PID=$!
sleep 2

echo "MiniBus started with PID $MINIBUS_PID"

# Test with dbus-send
echo "Testing dbus-send with MiniBus..."
timeout 5 dbus-send --address="unix:path=/tmp/minibus-test-socket" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames > minibus-test-output.log 2>&1

echo "MiniBus result:"
cat minibus-test-output.log

echo ""
echo "MiniBus daemon log:"
cat minibus-test-daemon.log

# Clean up
kill $MINIBUS_PID 2>/dev/null || true
rm -f /tmp/minibus-test-socket

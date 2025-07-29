#!/bin/sh

# Test MiniBus compatibility with standard D-Bus tools
# This script tests dbus-send and dbus-monitor with MiniBus daemon

set -e

echo "=== MiniBus Standard Tools Compatibility Test ==="
echo

# Clean up any existing processes and sockets
cleanup() {
    echo "Cleaning up..."
    pkill -f "minibus" 2>/dev/null || true
    pkill -f "dbus-monitor" 2>/dev/null || true
    rm -f /tmp/minibus-socket* 2>/dev/null || true
    sleep 1
}

cleanup

echo "1. Starting MiniBus daemon..."
cd /home/User/gershwin-prefpanes/minibus
timeout 60s ./obj/minibus > standard-tools-test-daemon.log 2>&1 &
DAEMON_PID=$!

# Wait for daemon to start
sleep 2

# Check if socket was created
if [ ! -S "/tmp/minibus-socket" ]; then
    echo "ERROR: MiniBus socket not created"
    cleanup
    exit 1
fi

echo "   ✓ MiniBus daemon started (PID: $DAEMON_PID)"
echo "   ✓ Socket created at /tmp/minibus-socket"

echo
echo "2. Testing with dbus-monitor..."

# Start dbus-monitor in background
export DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/minibus-socket"
timeout 30s dbus-monitor --address="unix:path=/tmp/minibus-socket" > monitor-output.log 2>&1 &
MONITOR_PID=$!

# Give monitor time to connect
sleep 2

echo "   ✓ dbus-monitor started (PID: $MONITOR_PID)"

echo
echo "3. Testing dbus-send method calls..."

# Test 1: Simple method call (ListNames)
echo "   Testing ListNames method call..."
if timeout 10s dbus-send --bus="unix:path=/tmp/minibus-socket" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames > listnames-output.log 2>&1; then
    echo "   ✓ ListNames call succeeded"
    if grep -q "array" listnames-output.log; then
        echo "   ✓ Received array response"
    else
        echo "   ⚠ Response format may be incorrect"
    fi
else
    echo "   ✗ ListNames call failed"
    echo "   Error output:"
    cat listnames-output.log 2>/dev/null | head -5
fi

echo

# Test 2: GetNameOwner method call
echo "   Testing GetNameOwner method call..."
if timeout 10s dbus-send --bus="unix:path=/tmp/minibus-socket" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner string:org.freedesktop.DBus > getnameowner-output.log 2>&1; then
    echo "   ✓ GetNameOwner call succeeded"
    if grep -q "string" getnameowner-output.log; then
        echo "   ✓ Received string response"
    else
        echo "   ⚠ Response format may be incorrect"
    fi
else
    echo "   ✗ GetNameOwner call failed"
    echo "   Error output:"
    cat getnameowner-output.log 2>/dev/null | head -5
fi

echo

# Test 3: RequestName method call
echo "   Testing RequestName method call..."
if timeout 10s dbus-send --bus="unix:path=/tmp/minibus-socket" --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.RequestName string:com.example.TestService uint32:0 > requestname-output.log 2>&1; then
    echo "   ✓ RequestName call succeeded"
    if grep -q "uint32" requestname-output.log; then
        echo "   ✓ Received uint32 response"
    else
        echo "   ⚠ Response format may be incorrect"
    fi
else
    echo "   ✗ RequestName call failed"
    echo "   Error output:"
    cat requestname-output.log 2>/dev/null | head -5
fi

# Stop monitor
echo
echo "4. Stopping dbus-monitor..."
kill $MONITOR_PID 2>/dev/null || true
wait $MONITOR_PID 2>/dev/null || true

# Check monitor output
echo "5. Checking monitor output..."
if [ -f monitor-output.log ] && [ -s monitor-output.log ]; then
    echo "   ✓ dbus-monitor captured messages"
    echo "   Monitor log summary:"
    wc -l monitor-output.log || echo "   (Unable to count lines)"
    echo "   First few lines:"
    head -5 monitor-output.log 2>/dev/null || echo "   (Unable to read log)"
else
    echo "   ⚠ dbus-monitor output is empty or missing"
fi

echo
echo "6. Stopping MiniBus daemon..."
kill $DAEMON_PID 2>/dev/null || true
wait $DAEMON_PID 2>/dev/null || true

echo
echo "=== Test Results Summary ==="
echo

# Count successes
successes=0
total=3

if grep -q "ListNames call succeeded" /dev/stdout 2>/dev/null; then
    successes=$((successes + 1))
fi
if grep -q "GetNameOwner call succeeded" /dev/stdout 2>/dev/null; then
    successes=$((successes + 1))
fi
if grep -q "RequestName call succeeded" /dev/stdout 2>/dev/null; then
    successes=$((successes + 1))
fi

echo "Method calls: ${successes}/${total} succeeded"

if [ -s monitor-output.log ]; then
    echo "dbus-monitor: ✓ Captured traffic"
else
    echo "dbus-monitor: ⚠ No traffic captured"
fi

if [ -s standard-tools-test-daemon.log ]; then
    echo "Daemon log: ✓ Available"
else
    echo "Daemon log: ⚠ Empty or missing"
fi

echo
if [ $successes -eq $total ] && [ -s monitor-output.log ]; then
    echo "🎉 MiniBus is fully compatible with standard D-Bus tools!"
    exit 0
else
    echo "⚠ Some issues detected. Check individual test outputs for details."
    exit 1
fi

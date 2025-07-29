#!/bin/bash
# Compare dbus-send behavior with real daemon vs our daemon

echo "=== Comparing D-Bus implementations ==="

# Create a simple test to start real dbus-daemon temporarily
echo "Starting real D-Bus daemon..."
dbus-daemon --session --fork --print-address > /tmp/real-dbus-address 2>/dev/null

if [ $? -eq 0 ] && [ -s /tmp/real-dbus-address ]; then
    REAL_ADDRESS=$(cat /tmp/real-dbus-address)
    echo "Real D-Bus daemon started at: $REAL_ADDRESS"
    
    echo ""
    echo "=== Testing with REAL D-Bus daemon ==="
    export DBUS_SESSION_BUS_ADDRESS="$REAL_ADDRESS"
    
    echo "Testing dbus-send..."
    timeout 5 dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.Hello 2>&1
    
    echo ""
    echo "Testing dbus-monitor (background) with real daemon..."
    timeout 5 dbus-monitor --session &
    MONITOR_PID=$!
    sleep 1
    
    echo "Sending Hello again with monitor running..."
    timeout 3 dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.Hello 2>&1
    
    # Stop monitor
    kill $MONITOR_PID 2>/dev/null
    
    # Kill real daemon
    REAL_PID=$(ps aux | grep "dbus-daemon.*$REAL_ADDRESS" | grep -v grep | awk '{print $2}')
    if [ -n "$REAL_PID" ]; then
        kill $REAL_PID 2>/dev/null
    fi
    
    echo ""
    echo "=== Now testing with OUR daemon ==="
    
    # Clean up
    rm -f /tmp/real-dbus-address /tmp/minibus-socket
    
    # Start our daemon
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/minibus-socket"
    ./obj/minibus &
    OUR_PID=$!
    sleep 2
    
    echo "Testing dbus-send with our daemon..."
    timeout 5 dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.Hello 2>&1
    
    echo ""
    echo "Testing dbus-monitor with our daemon..."
    timeout 5 dbus-monitor --session &
    MONITOR_PID=$!
    sleep 1
    
    echo "Sending Hello again with monitor running..."
    timeout 3 dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.Hello 2>&1
    
    # Clean up
    kill $MONITOR_PID $OUR_PID 2>/dev/null
    rm -f /tmp/minibus-socket
    
else
    echo "Could not start real D-Bus daemon for comparison"
    echo "Testing just our daemon..."
    
    # Test with our daemon only
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/minibus-socket"
    ./obj/minibus &
    OUR_PID=$!
    sleep 2
    
    echo "Testing dbus-send with our daemon..."
    timeout 5 dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.Hello 2>&1
    
    # Clean up
    kill $OUR_PID 2>/dev/null
    rm -f /tmp/minibus-socket
fi

rm -f /tmp/real-dbus-address

echo "=== Comparison complete ==="

#!/bin/sh

# Test simple Hello interaction with both daemons
echo "=== Hello Interaction Test ==="

test_daemon() {
    local daemon_name="$1"
    local socket_path="$2"
    local start_cmd="$3"
    
    echo "Testing $daemon_name..."
    
    # Clean up
    pkill -f "$daemon_name" 2>/dev/null
    rm -f "$socket_path" "${daemon_name}.log"
    
    # Start daemon
    echo "Starting $daemon_name..."
    eval "$start_cmd" > "${daemon_name}.log" 2>&1 &
    local daemon_pid=$!
    sleep 2
    
    if [ ! -S "$socket_path" ]; then
        echo "ERROR: $daemon_name socket not created"
        kill $daemon_pid 2>/dev/null
        return 1
    fi
    
    # Test with dbus-send
    echo "Testing dbus-send with $daemon_name..."
    timeout 5 dbus-send --bus="unix:path=$socket_path" \
        --dest=org.freedesktop.DBus \
        --type=method_call \
        /org/freedesktop/DBus \
        org.freedesktop.DBus.ListNames 2>&1 | head -5
    
    # Stop daemon
    kill $daemon_pid 2>/dev/null
    wait $daemon_pid 2>/dev/null
    
    echo "--- $daemon_name Log ---"
    tail -10 "${daemon_name}.log"
    echo ""
}

# Test both daemons
test_daemon "minibus" "/tmp/minibus-socket" "timeout 30 ./obj/minibus"
test_daemon "dbus-daemon" "/tmp/real-dbus-socket" "timeout 30 dbus-daemon --nofork --session --address=unix:path=/tmp/real-dbus-socket"

echo "=== Test complete ==="

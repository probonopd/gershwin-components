#!/bin/sh

# Debug the Hello sequence with dbus-send
echo "=== Debugging Hello Sequence ==="

# Clean up
pkill -f minibus 2>/dev/null
rm -f /tmp/minibus-socket daemon.log

echo "1. Starting MiniBus daemon..."
timeout 30 ./obj/minibus > daemon.log 2>&1 &
DAEMON_PID=$!
sleep 1

if [ ! -S /tmp/minibus-socket ]; then
    echo "ERROR: Socket not created"
    exit 1
fi

echo "2. Testing with socat to capture raw traffic..."
timeout 10 socat -v UNIX-CONNECT:/tmp/minibus-socket STDOUT 2>socat.log <<EOF &
AUTH EXTERNAL 31303031
NEGOTIATE_UNIX_FD
BEGIN
EOF
SOCAT_PID=$!
sleep 2

echo "3. Stopping socat and daemon..."
kill $SOCAT_PID 2>/dev/null
kill $DAEMON_PID 2>/dev/null
wait

echo "4. Checking daemon log for Hello sequence..."
echo "--- Daemon Log ---"
grep -E "(Hello|NameAcquired|NameOwner|Broken pipe)" daemon.log

echo "5. Checking socat capture..."
echo "--- Socat Log ---"
cat socat.log

echo "=== Analysis complete ==="

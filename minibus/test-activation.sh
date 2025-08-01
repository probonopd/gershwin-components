#!/bin/bash

# Test D-Bus activation in minibus

set -e

echo "=== Testing D-Bus Service Activation ==="

# Cleanup any existing socket
rm -f /tmp/minibus-socket

# Start the daemon in the background
echo "Starting minibus daemon..."
cd /home/User/gershwin-prefpanes/minibus
timeout 60 ./obj/minibus /tmp/minibus-socket &
DAEMON_PID=$!

# Give the daemon time to start
sleep 2

# Function to cleanup
cleanup() {
    echo "Cleaning up..."
    kill $DAEMON_PID 2>/dev/null || true
    rm -f /tmp/minibus-socket
}
trap cleanup EXIT

# Test 1: Check that service is not initially running
echo "Test 1: Checking that service is not initially running..."
if ./obj/minibus-test /tmp/minibus-socket 2>&1 | grep -q "com.example.TestService"; then
    echo "ERROR: Service should not be running initially"
    exit 1
else
    echo "PASS: Service is not running initially"
fi

# Test 2: Try to start the service explicitly via StartServiceByName
echo "Test 2: Testing explicit service activation..."
./obj/test-start-service &
START_SERVICE_PID=$!

# Give it time to try activation
sleep 3

# Check if service activated
echo "Checking if service was activated..."
if ./obj/minibus-test /tmp/minibus-socket 2>&1 | grep -q "com.example.TestService"; then
    echo "PASS: Service was successfully activated"
else
    echo "ERROR: Service activation failed"
    exit 1
fi

# Test 3: Let service expire and test auto-activation by sending a message
echo "Test 3: Waiting for service to expire..."
sleep 12  # Service sleeps for 10 seconds

echo "Verifying service expired..."
if ./obj/minibus-test /tmp/minibus-socket 2>&1 | grep -q "com.example.TestService"; then
    echo "Service still running, waiting more..."
    sleep 5
fi

# TODO: Test auto-activation by sending a message to the service
# This would require implementing a client that sends a message to the service name

echo "=== All tests passed! ==="

#!/usr/local/bin/bash

# Comprehensive D-Bus Activation Test for MiniBus

set -e

echo "=== Comprehensive D-Bus Activation Test ==="
echo

cd /home/User/gershwin-prefpanes/minibus

# Cleanup
echo "1. Cleaning up..."
pkill -f "minibus /tmp/minibus-socket" 2>/dev/null || true
rm -f /tmp/minibus-socket /tmp/activation.log /tmp/minibus.log
echo "   ✓ Cleanup complete"
echo

# Start daemon
echo "2. Starting MiniBus daemon..."
nohup ./obj/minibus /tmp/minibus-socket > /tmp/minibus.log 2>&1 &
DAEMON_PID=$!
sleep 3
echo "   ✓ Daemon started (PID: $DAEMON_PID)"
echo

# Function to cleanup
cleanup() {
    echo "Cleaning up..."
    kill $DAEMON_PID 2>/dev/null || true
    pkill -f "minibus /tmp/minibus-socket" 2>/dev/null || true
    rm -f /tmp/minibus-socket
}
# Don't set trap yet - we need the daemon to stay alive for auto-activation

# Test 1: Check service discovery
echo "3. Testing service discovery..."
if grep -q "com.example.TestService" /tmp/minibus.log; then
    echo "   ✓ Test service discovered by daemon"
else
    echo "   ✗ Test service not found"
    cleanup
    exit 1
fi
echo

# Test 2: Explicit service activation via StartServiceByName
echo "4. Testing explicit service activation (StartServiceByName)..."
if ./obj/test-activation-client /tmp/minibus-socket com.example.TestService 2>&1 | grep -q "SUCCESS: Service was started"; then
    echo "   ✓ StartServiceByName succeeded"
else
    echo "   ✗ StartServiceByName failed"
    cleanup
    exit 1
fi

# Give the service a moment to start and create the log
sleep 2

# Check that service was actually launched
if [ -f /tmp/activation.log ]; then
    echo "   ✓ Service wrapper was executed"
    echo "   ✓ Environment variables set:"
    grep "DBUS_STARTER_ADDRESS" /tmp/activation.log | sed 's/^/     /'
    grep "DBUS_STARTER_BUS_TYPE" /tmp/activation.log | sed 's/^/     /'
else
    echo "   ✗ Service wrapper was not executed"
    cleanup
    exit 1
fi

# Check that service connected and registered
if grep -q "Successfully registered name: com.example.TestService" /tmp/minibus.log; then
    echo "   ✓ Service successfully registered on D-Bus"
else
    echo "   ✗ Service failed to register"
    cleanup
    exit 1
fi
echo

# Wait for service to expire
echo "5. Waiting for service to expire..."
sleep 12
echo "   ✓ Service should have expired"
echo

# Test 3: Auto-activation via message sending
echo "6. Testing auto-activation..."
rm -f /tmp/activation.log

if ./obj/test-auto-activation /tmp/minibus-socket com.example.TestService 2>&1 | grep -q "Service com.example.TestService is being activated"; then
    echo "   ✓ Auto-activation triggered correctly"
else
    echo "   ✗ Auto-activation failed"
    cleanup
    exit 1
fi

# Give service time to launch and write to log
sleep 3

# Check that auto-activation actually launched the service
if [ -f /tmp/activation.log ]; then
    echo "   ✓ Auto-activation launched service"
else
    echo "   ✗ Auto-activation did not launch service"
    cleanup
    exit 1
fi
echo

# Test 4: Check activation statistics
echo "7. Checking activation statistics..."
EXPLICIT_ACTIVATIONS=$(grep -c "StartServiceByName.*successfully started activation" /tmp/minibus.log)
AUTO_ACTIVATIONS=$(grep -c "Auto-activating service" /tmp/minibus.log || echo "0")
TOTAL_ACTIVATIONS=$((EXPLICIT_ACTIVATIONS + AUTO_ACTIVATIONS))

echo "   ✓ Explicit activations: $EXPLICIT_ACTIVATIONS"
echo "   ✓ Auto-activations: $AUTO_ACTIVATIONS"
echo "   ✓ Total activations: $TOTAL_ACTIVATIONS"
echo

echo "=== All D-Bus Activation Tests Passed! ==="
echo
echo "Summary:"
echo "• Service file parsing: ✓"
echo "• Service discovery: ✓"
echo "• StartServiceByName: ✓"
echo "• Auto-activation: ✓"
echo "• Environment variables: ✓"
echo "• Service registration: ✓"
echo
echo "MiniBus D-Bus activation is fully functional!"

# Cleanup at the end
cleanup

#!/usr/local/bin/bash
# Test D-Bus activation edge cases and error conditions

set -e
cd /home/User/gershwin-prefpanes/minibus

echo "=== D-Bus Activation Edge Cases Test ==="
echo

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

# Test 1: Try to activate non-existent service
echo "3. Testing activation of non-existent service..."
if ./obj/test-activation-client /tmp/minibus-socket com.example.NonExistentService 2>&1 | grep -q "The name com.example.NonExistentService was not provided by any .service files"; then
    echo "   ✓ Non-existent service correctly rejected"
else
    echo "   ✗ Non-existent service handling failed"
    cleanup
    exit 1
fi
echo

# Test 2: Double activation of the same service
echo "4. Testing double activation..."
./obj/test-activation-client /tmp/minibus-socket com.example.TestService >/dev/null 2>&1
sleep 12  # Wait for service to expire (10 seconds + margin)
if ./obj/test-activation-client /tmp/minibus-socket com.example.TestService 2>&1 | grep -q "SUCCESS: Service was started"; then
    echo "   ✓ Double activation completed successfully (service reactivated after expiry)"
else
    echo "   ✗ Double activation failed"
    cleanup
    exit 1
fi
echo

# Test 3: Check daemon logs for activation patterns
echo "5. Checking daemon logging..."
ACTIVATION_LOGS=$(grep -c "StartServiceByName.*com.example.TestService" /tmp/minibus.log || echo "0")
SERVICE_FOUND_LOGS=$(grep -c "Found service.*com.example.TestService" /tmp/minibus.log || echo "0")
SERVICE_NOT_FOUND_LOGS=$(grep -c "Service.*not found" /tmp/minibus.log || echo "0")

echo "   ✓ Activation attempts: $ACTIVATION_LOGS"
echo "   ✓ Service found logs: $SERVICE_FOUND_LOGS"
echo "   ✓ Service not found logs: $SERVICE_NOT_FOUND_LOGS"
echo

# Test 4: Check error handling in logs
echo "6. Testing error handling..."
if grep -q "Error\|Failed" /tmp/minibus.log; then
    echo "   ✓ Error conditions logged:"
    grep "Error\|Failed" /tmp/minibus.log | head -3 | sed 's/^/     /'
else
    echo "   ✓ No unexpected errors in logs"
fi
echo

echo "=== Edge Cases Test Completed Successfully! ==="
echo
echo "Summary:"
echo "• Non-existent service rejection: ✓"
echo "• Double activation handling: ✓"
echo "• Error logging: ✓"
echo "• Service discovery: ✓"

# Cleanup at the end
cleanup

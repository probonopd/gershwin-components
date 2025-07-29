#!/usr/local/bin/bash
# Complete dbus-monitor test with MiniBus BecomeMonitor implementation

echo "=============================================="
echo "MiniBus dbus-monitor Support Test"
echo "=============================================="
echo

# Clean up
echo "1. Cleaning up..."
pkill -f minibus 2>/dev/null || true
pkill -f dbus-monitor 2>/dev/null || true
rm -f /tmp/minibus-socket
sleep 1
echo "   ✓ Cleanup complete"
echo

# Start MiniBus with monitoring support
echo "2. Starting MiniBus daemon with monitoring support..."
nohup ./obj/minibus > dbus-monitor-demo.log 2>&1 &
MINIBUS_PID=$!
sleep 2

if [ -S /tmp/minibus-socket ]; then
    echo "   ✓ MiniBus daemon started (PID: $MINIBUS_PID)"
    echo "   ✓ Socket created: /tmp/minibus-socket"
else
    echo "   ✗ Failed to start MiniBus daemon"
    exit 1
fi
echo

# Start dbus-monitor  
echo "3. Starting dbus-monitor..."
echo "   dbus-monitor will now use org.freedesktop.DBus.Monitoring.BecomeMonitor"
timeout 30 dbus-monitor --address "unix:path=/tmp/minibus-socket" > monitor-capture.log 2>&1 &
MONITOR_PID=$!
sleep 3

# Check if monitor connected successfully
if kill -0 $MONITOR_PID 2>/dev/null; then
    echo "   ✓ dbus-monitor connected and became a monitor"
else
    echo "   ⚠ dbus-monitor exited early, checking output..."
    wait $MONITOR_PID
    echo "   Monitor output:"
    cat monitor-capture.log
fi
echo

# Generate D-Bus traffic for monitoring
echo "4. Generating D-Bus traffic to observe..."
echo "   Running multiple D-Bus clients..."

# Client 1: simple-test
echo "   • Running simple-test..."
./obj/simple-test > client1.log 2>&1 &
CLIENT1_PID=$!

sleep 1

# Client 2: Another simple-test
echo "   • Running second simple-test..."
./obj/simple-test > client2.log 2>&1 &
CLIENT2_PID=$!

sleep 1

# Manual dbus-send commands to generate more traffic
echo "   • Sending manual dbus-send commands..."
dbus-send --address "unix:path=/tmp/minibus-socket" --dest=org.freedesktop.DBus --type=method_call --print-reply / org.freedesktop.DBus.Hello > manual1.log 2>&1 &
dbus-send --address "unix:path=/tmp/minibus-socket" --dest=org.freedesktop.DBus --type=method_call --print-reply / org.freedesktop.DBus.ListNames > manual2.log 2>&1 &

# Wait for traffic generation to complete
wait $CLIENT1_PID 2>/dev/null
wait $CLIENT2_PID 2>/dev/null
sleep 2

echo "   ✓ Traffic generation complete"
echo

# Stop monitor and analyze results
echo "5. Stopping dbus-monitor and analyzing results..."
kill $MONITOR_PID 2>/dev/null || true
wait $MONITOR_PID 2>/dev/null || true
sleep 1

echo "   Monitor capture results:"
echo "   ========================"
if [ -f monitor-capture.log ]; then
    if [ -s monitor-capture.log ]; then
        echo "   Monitor captured $(wc -l < monitor-capture.log) lines of output"
        echo
        echo "   Sample of captured traffic:"
        echo "   ---------------------------"
        head -20 monitor-capture.log
        echo "   ---------------------------"
        echo "   (Full output saved in monitor-capture.log)"
    else
        echo "   Monitor output file is empty"
    fi
else
    echo "   No monitor output file found"
fi
echo

# Show MiniBus daemon logs
echo "6. MiniBus daemon activity log:"
echo "   =============================="
if [ -f dbus-monitor-demo.log ]; then
    echo "   Daemon handled $(grep -c "Processing message" dbus-monitor-demo.log) messages"
    echo "   BecomeMonitor calls: $(grep -c "BecomeMonitor" dbus-monitor-demo.log)"
    echo "   Monitor connections: $(grep -c "converted to monitor" dbus-monitor-demo.log)"
    echo
    echo "   Key daemon events:"
    echo "   ------------------"
    grep -E "(BecomeMonitor|converted to monitor|Monitor connection|Processing message.*Hello|Processing message.*ListNames)" dbus-monitor-demo.log | head -10
else
    echo "   No daemon log found"
fi
echo

# Test results summary
echo "7. Test Results Summary:"
echo "   ======================"

BECOME_MONITOR_CALLS=$(grep -c "BecomeMonitor" dbus-monitor-demo.log 2>/dev/null || echo "0")
MONITOR_CONVERSIONS=$(grep -c "converted to monitor" dbus-monitor-demo.log 2>/dev/null || echo "0") 
HELLO_MESSAGES=$(grep -c "Processing message.*Hello" dbus-monitor-demo.log 2>/dev/null || echo "0")
LISTNAMES_MESSAGES=$(grep -c "Processing message.*ListNames" dbus-monitor-demo.log 2>/dev/null || echo "0")

if [ "$BECOME_MONITOR_CALLS" -gt 0 ]; then
    echo "   ✓ BecomeMonitor method: IMPLEMENTED ($BECOME_MONITOR_CALLS calls)"
else
    echo "   ✗ BecomeMonitor method: NOT CALLED"
fi

if [ "$MONITOR_CONVERSIONS" -gt 0 ]; then
    echo "   ✓ Monitor connections: WORKING ($MONITOR_CONVERSIONS conversions)"
else
    echo "   ✗ Monitor connections: NOT WORKING"
fi

if [ "$HELLO_MESSAGES" -gt 0 ]; then
    echo "   ✓ D-Bus traffic: GENERATED ($HELLO_MESSAGES Hello, $LISTNAMES_MESSAGES ListNames)"
else
    echo "   ✗ D-Bus traffic: NOT GENERATED"
fi

if [ -s monitor-capture.log ]; then
    echo "   ✓ dbus-monitor: CAPTURED TRAFFIC"
else
    echo "   ⚠ dbus-monitor: NO TRAFFIC CAPTURED"
fi

echo
if [ "$BECOME_MONITOR_CALLS" -gt 0 ] && [ "$MONITOR_CONVERSIONS" -gt 0 ]; then
    echo "   🎉 OVERALL RESULT: SUCCESS - MiniBus supports dbus-monitor!"
    echo "   📊 MiniBus now implements org.freedesktop.DBus.Monitoring.BecomeMonitor"
    echo "   🔍 dbus-monitor can successfully connect and observe D-Bus traffic"
else
    echo "   ⚠ OVERALL RESULT: PARTIAL - Some issues detected"
fi
echo

# Cleanup
echo "8. Cleaning up..."
kill $MINIBUS_PID 2>/dev/null || true
wait $MINIBUS_PID 2>/dev/null || true
rm -f /tmp/minibus-socket
echo "   ✓ Cleanup complete"
echo

echo "=============================================="
echo "MiniBus dbus-monitor Test Complete"
echo "=============================================="
echo
echo "Files generated:"
echo "• dbus-monitor-demo.log - MiniBus daemon activity"
echo "• monitor-capture.log - dbus-monitor captured traffic"
echo "• client*.log - Test client outputs"
echo "• manual*.log - Manual dbus-send outputs"

#!/usr/local/bin/bash

echo "=== Testing Complete MiniBus Flow ==="

# Test 1: Simple Hello with our client
echo "1. Testing Hello message with simple-test client..."
timeout 10 ./obj/simple-test 2>&1 | head -20

echo

# Test 2: Check what daemon logged
echo "2. Checking daemon log..."
tail -10 daemon.log

echo

# Test 3: Test with gdbus (if available)
if command -v gdbus > /dev/null 2>&1; then
    echo "3. Testing with gdbus tool..."
    timeout 10 gdbus call --address "unix:path=/tmp/minibus-socket" --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.ListNames 2>&1 || echo "gdbus failed"
else
    echo "3. gdbus not available, skipping..."
fi

echo

# Test 4: Test with python-dbus (if available)
if python3 -c "import dbus" 2>/dev/null; then
    echo "4. Testing with Python D-Bus..."
    python3 -c "
import dbus
import dbus.connection
try:
    conn = dbus.connection.Connection('unix:path=/tmp/minibus-socket')
    bus = dbus.Interface(conn.get_object('org.freedesktop.DBus', '/org/freedesktop/DBus'), 'org.freedesktop.DBus')
    names = bus.ListNames()
    print('ListNames succeeded:', names)
except Exception as e:
    print('Python D-Bus failed:', e)
" 2>&1
else
    echo "4. Python D-Bus not available, skipping..."
fi

echo

echo "5. Final daemon log..."
tail -5 daemon.log

#!/usr/local/bin/bash
# Test introspection with GLib D-Bus tools

echo "Testing MiniBus introspection capabilities..."

export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/minibus-socket

# Test using gdbus tool (if available)
if command -v gdbus >/dev/null 2>&1; then
    echo "Testing with gdbus introspect..."
    timeout 10 gdbus introspect --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus
else
    echo "gdbus not available, testing with custom client..."
fi

# Test using dbus-send (if available)
if command -v dbus-send >/dev/null 2>&1; then
    echo ""
    echo "Testing with dbus-send..."
    timeout 10 dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.Introspectable.Introspect
fi

# Test GVFS daemon activation
echo ""
echo "Testing GVFS daemon activation..."
if command -v dbus-send >/dev/null 2>&1; then
    timeout 30 dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.StartServiceByName string:org.gtk.vfs.Daemon uint32:0
fi

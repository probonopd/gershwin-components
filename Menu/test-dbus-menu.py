#!/usr/bin/env python3

import os
import sys
import time
import subprocess
from Xlib import X, display
from Xlib.protocol import request

# Simple test to register a DBus menu without using PyQt or other dependencies
def test_dbus_menu_registration():
    """Test registering a menu with the AppMenu.Registrar service"""
    print("Testing DBus menu registration...")
    
    # Get current X11 display
    d = display.Display()
    root = d.screen().root
    
    # Create a simple test window
    window = root.create_window(
        100, 100, 300, 200, 1,
        X.CopyFromParent, X.InputOutput,
        X.CopyFromParent,
        event_mask=X.ExposureMask | X.KeyPressMask
    )
    
    window.set_wm_name("Test Menu App")
    window.set_wm_class("test-menu", "TestMenu")
    window.map()
    d.sync()
    
    window_id = window.id
    print(f"Created test window with ID: {window_id}")
    
    # Register with AppMenu.Registrar via dbus-send
    try:
        cmd = [
            "dbus-send", "--session", "--print-reply",
            "--dest=com.canonical.AppMenu.Registrar",
            "/com/canonical/AppMenu/Registrar",
            "com.canonical.AppMenu.Registrar.RegisterWindow",
            f"uint32:{window_id}",
            "objpath:/test/menu/object"
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            print(f"Successfully registered window {window_id}")
            print("Output:", result.stdout)
        else:
            print(f"Failed to register window: {result.stderr}")
            
    except Exception as e:
        print(f"Error registering window: {e}")
    
    # Keep window open for a bit to test
    print("Window will stay open for 10 seconds...")
    time.sleep(10)
    
    # Clean up
    window.destroy()
    d.close()

if __name__ == "__main__":
    # Set environment variables for Unity desktop
    os.environ["XDG_CURRENT_DESKTOP"] = "Unity"
    os.environ["DESKTOP_SESSION"] = "unity"
    os.environ["UBUNTU_MENUPROXY"] = "1"
    
    test_dbus_menu_registration()

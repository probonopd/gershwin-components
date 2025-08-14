#!/usr/bin/env python3
"""
Test application that registers a DBus menu to verify Menu.app functionality
"""

import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib, Gtk, Gdk
import sys
import time

class TestMenuApp:
    def __init__(self):
        # Set up DBus
        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        self.session_bus = dbus.SessionBus()
        
        # Create window
        self.window = Gtk.Window()
        self.window.set_title("Test Menu App")
        self.window.set_default_size(400, 300)
        self.window.connect("destroy", Gtk.main_quit)
        
        label = Gtk.Label("Test application for DBus menu registration")
        self.window.add(label)
        
        # Show window first to get window ID
        self.window.show_all()
        
        # Get window ID
        self.window_id = self.window.get_window().get_xid()
        print(f"Window ID: {self.window_id}")
        
        # Register menu
        self.register_menu()
    
    def register_menu(self):
        try:
            # Get the AppMenu.Registrar service
            registrar = self.session_bus.get_object('com.canonical.AppMenu.Registrar', 
                                                  '/com/canonical/AppMenu/Registrar')
            
            # Register our window with a menu
            registrar.RegisterWindow(self.window_id, 
                                   '/com/example/TestApp/MenuBar',
                                   dbus_interface='com.canonical.AppMenu.Registrar')
            
            print(f"Successfully registered menu for window {self.window_id}")
            
        except Exception as e:
            print(f"Failed to register menu: {e}")
    
    def run(self):
        Gtk.main()

if __name__ == "__main__":
    app = TestMenuApp()
    app.run()

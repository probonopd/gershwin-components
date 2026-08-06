#!/usr/bin/env drive_script
# Chrome's menu shortcuts must keep working after switching to another app and
# back.  The shortcuts live in Menu.app's global menu (Chrome is a GTK/DBus
# app); pressing Alt+N (Command+N in GNUstep terms, where Command = Alt) opens
# a NEW Chrome window.  The whole-X-display xwindow scan counts real
# application windows (ICCCM/EWMH-filtered), so the test compares against a
# baseline captured at runtime and is robust to Chrome restoring windows.
#
# The second press happens after switching away to the desktop and back, which
# releases and must re-register Chrome's global shortcuts.
#
# Run with: drive_script examples/chrome_shortcuts.dsl
# (Chrome must already be running - launch it with the .app wrapper first.)
activate application "Menu"
wait until xwindow "Google Chrome"

# Activate Chrome so its menu is shown and its shortcuts are registered.
activate xwindow "Google Chrome"
wait 500ms

# First trigger: Alt+N must open a new Chrome window.
setcount BASE = count xwindow "Google Chrome"
press "Alt+N"
wait until xwindow "Google Chrome" count > ${BASE}

# Switch to another app (the desktop carries no app menu) - this releases
# Chrome's global shortcuts.
activate xwindow "Desktop"
wait 500ms

# Switch back to Chrome - its shortcuts must be registered again.
activate xwindow "Google Chrome"
wait 500ms

# Second trigger after switching back: must again open a new Chrome window.
setcount BASE = count xwindow "Google Chrome"
press "Alt+N"
wait until xwindow "Google Chrome" count > ${BASE}

log "chrome shortcuts work after switch-back"

#!/usr/bin/env drive_script
# The global menu bar must always show the menu of the FRONTMOST app, and must
# switch within ~100ms of an app change.  xterm has no own menu, so it must not
# show any app's menu (system-only).  The desktop (a Workspace window, no
# viewer open) shows the Workspace menu; Processes shows the Processes menu.
#
# Run with: drive_script examples/menu_follows_app.dsl
# (Menu.app and the target apps must be running.)
activate application "Menu"

# xterm - has no own menu: must not show any app menu.
activate xwindow "xterm"
wait until not menu bar "Workspace" timeout 150ms
wait until not menu bar "Processes" timeout 150ms
wait until not menu bar "Ablage" timeout 150ms

# Desktop (Workspace window) - shows the Workspace menu.
activate xwindow "Desktop"
wait until menu bar "Workspace" timeout 200ms

# Processes - shows the Processes menu.
activate xwindow "Processes"
wait until menu bar "Processes" timeout 200ms

# Back to a Workspace window - the Workspace menu again.
activate xwindow "Desktop"
wait until menu bar "Workspace" timeout 200ms

log "global menu follows the frontmost app"

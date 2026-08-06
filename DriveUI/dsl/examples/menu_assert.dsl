#!/usr/bin/env drive_script
# Menu-item assertions: existence, checkmark state and key equivalents
# (shortcuts) read from the app's main-menu dump.
#
# Run with: drive_script examples/menu_assert.dsl
launch application "Processes"
activate application "Processes"

assert menu item "Processes/About Processes" exists
assert menu item "Processes/Hide Processes" shortcut "Cmd+H"
assert menu item "Processes/Quit Processes" shortcut "Cmd+Q"
assert menu item "Window/Minimize" shortcut "Cmd+M"
assert not exists menu item "Processes/DoesNotExist"
if menu item "Processes/About Processes" enabled
  log "About Processes is enabled"
end

log "menu assertions pass"

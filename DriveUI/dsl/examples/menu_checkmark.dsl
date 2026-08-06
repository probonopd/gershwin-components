#!/usr/bin/env drive_script
# Checkmark (state) assertions on a menu item that carries one.
#
# Run with: drive_script examples/menu_checkmark.dsl
activate application "Workspace"

assert menu item "Ansicht/Seitenleiste zeigen" checked
assert menu item "Ansicht/Seitenleiste zeigen" not disabled

if menu item "Ansicht/Seitenleiste zeigen" checked
  log "sidebar menu item is checked"
end

log "menu checkmark assertions pass"

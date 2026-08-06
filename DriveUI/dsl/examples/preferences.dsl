#!/usr/bin/env drive_script
# Preferences: the Workspace preferences window must open from the app menu and
# close again.  The window title starts with the app name, so "Workspace"
# matches it in both languages.
#
# Leaves the computer as it was found: the preferences window is closed at the
# end, and no setting is changed.
#
# Run with: drive_script examples/preferences.dsl
activate application "Workspace"

select menu "Workspace/Preferences..."
wait until window "Workspace"
assert window "Workspace"
close window "Workspace"
wait until not exists window "Workspace"

log "preferences stable"

#!/usr/bin/env drive_script
# Search: the File > Find command must open the search window ("Dateisuche" on
# a German Workspace, matched through the localized "Suche") and close it
# again.
#
# Leaves the computer as it was found: the search window is closed at the end.
#
# Run with: drive_script examples/find.dsl
activate application "Workspace"

select menu "File/Find"
wait until window "Search"
assert window "Search"
close window "Search"
wait until not exists window "Search"

log "find stable"

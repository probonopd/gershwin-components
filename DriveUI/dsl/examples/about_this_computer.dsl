#!/usr/bin/env drive_script
# Opens the "About This Computer" panel and checks that the Processor and
# Memory fields are shown.
#
# The queries use the English title; the DSL engine localizes it via the app
# itself, so the script runs on both an English and a German Workspace.
#
# Leaves the computer as it was found: the panel is closed again at the end.
#
# Run with: drive_script examples/about_this_computer.dsl
activate application "Workspace"
select menu "Workspace/About This Computer"
wait until window "About This Computer"
assert window "About This Computer"
assert text contains "Processor"
assert text contains "Memory"
capture screenshot "/tmp/about_computer.png"
close window "About This Computer"
wait until not exists window "About This Computer"
log "About panel shown"
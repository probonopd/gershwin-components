#!/usr/bin/env drive_script
# About-box stability across app relaunches: launch Processes, open its About
# box, check the text, then quit and relaunch.  The whole cycle must work a
# second time too (the relaunch must not wedge the DriveUI connection or leave
# stale state behind).
#
# Leaves the computer as it was found: the app is left running at the end.
#
# Run with: drive_script examples/processes_about.dsl
launch application "Processes"

repeat 2
  activate application "Processes"
  select menu "Processes/About Processes"
  wait until window "Information"
  assert text contains "Process monitor"
  assert text contains "Release:"

  select menu "Processes/Quit Processes"
  # Let the old instance fully exit before relaunching so the relaunch does
  # not race a dying DriveUI socket.
  wait 1s
  launch application "Processes"
end

log "about box stable across relaunches"

#!/usr/bin/env drive_script
# About-box stability across app relaunches, exercised through Menu.app's GLOBAL
# menu bar: launch Processes, select Processes -> About Processes from the
# global menu, check the About-box text, then quit and relaunch and repeat.
# The global-menu ACTION must reach the live app instance both times (a stale
# menu bound to the previous instance's dead service would silently do
# nothing).
#
# Leaves the computer as it was found: the app is left running at the end.
#
# Run with: drive_script examples/processes_about.dsl
launch application "Processes"

repeat 2
  activate application "Processes"
  select global menu "Processes/About Processes"
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

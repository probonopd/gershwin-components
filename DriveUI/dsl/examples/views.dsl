#!/usr/bin/env drive_script
# View switching: exercises the View menu on a browsing viewer - view modes,
# icon size and the sidebar.  The sidebar exists only in browsing viewers, so
# the script switches the default viewer type to Browsing, verifies, then
# restores it to Spatial.  Both switches pop a confirmation alert, which the
# script dismisses explicitly with `invoke default button`.
#
# Leaves the computer as it was found: the default viewer type is restored,
# the sidebar is toggled off and back on, and the window is closed.  Runs on
# the root disk so no user folder's persisted view settings are touched.
#
# Run with: drive_script examples/views.dsl
activate application "Workspace"

# Switch the default viewer type to Browsing so the folder opens with a
# sidebar; dismiss the confirmation alert.
select menu "View/View Behavior/Set Browsing as Default"
wait until modal
invoke default button
wait until not modal

select menu "Go/Computer"
wait until window "System Disk"
assert window "System Disk" frame constant

# A browsing window carries a sidebar; make sure it is showing before we test
# toggling it (a previous run may have left it hidden).
if not sidebar
  select menu "View/Show Sidebar"
  wait until sidebar
end
assert sidebar
assert window "System Disk"

# View modes must not lose the window.
select menu "View/as Icons"
assert window "System Disk"
select menu "View/as List"
assert window "System Disk"
select menu "View/as Columns"
assert window "System Disk"

select menu "View/Icon Size/24"
select menu "View/Icon Size/64"
select menu "View/Icon Size/24"
assert window "System Disk"

# Sidebar: hide then show; the pane must actually vanish and return and the
# window must survive both toggles.
select menu "View/Show Sidebar"
wait until not sidebar
assert window "System Disk"
select menu "View/Show Sidebar"
wait until sidebar
assert window "System Disk"

# The toolbar is not implemented yet: the menu item raises a "not implemented"
# alert, which we dismiss explicitly.
select menu "View/Hide Toolbar"
wait until modal
invoke button "OK"
wait until not modal
assert window "System Disk"

# Restore the default viewer type, then close the window.
select menu "View/View Behavior/Set Spatial as Default"
wait until modal
invoke default button
wait until not modal

close window "System Disk"
wait until not exists window "System Disk"

log "view switching stable"

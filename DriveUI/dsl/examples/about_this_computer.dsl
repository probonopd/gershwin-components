# Opens the "About This Computer" panel, both for an English and a
# German-running Workspace.  The queries use the English title; the DSL engine
# localizes it via the app itself, so the script works regardless of locale.
activate application "Workspace"
select menu "Workspace/About This Computer"
wait until window "About This Computer"
assert window "About This Computer"
assert text contains "Processor"
assert text contains "Memory"
capture screenshot "/tmp/about_computer.png"
log "About panel shown"
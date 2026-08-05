# Das "Über diesen Computer"-Fenster öffnen - funktioniert bei englisch-
# wie auch deutschsprachigem Workspace, da die DSL beides matchen kann.
activate application "Workspace"
select menu "Workspace/Über diesen Computer"
wait until window "Über diesen Computer"
assert window "Über diesen Computer"
assert text contains "Prozessor"
assert text contains "Arbeitsspeicher"
capture screenshot "/tmp/about_computer_de.png"
log "Über-Fenster angezeigt"
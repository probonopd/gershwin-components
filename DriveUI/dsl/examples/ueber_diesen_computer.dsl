# Öffnet das "Über diesen Computer"-Fenster und prüft, dass die Felder
# Prozessor und Arbeitsspeicher angezeigt werden.
#
# Funktioniert bei englisch- wie auch deutschsprachigem Workspace, da die DSL
# das Fenster über seinen deutschen Titel findet.
#
# Lässt den Computer im Ausgangszustand zurück: das Fenster wird am Ende
# geschlossen.
#
# Aufruf: drive_script examples/ueber_diesen_computer.dsl
activate application "Workspace"
select menu "Workspace/Über diesen Computer"
wait until window "Über diesen Computer"
assert window "Über diesen Computer"
assert text contains "Prozessor"
assert text contains "Arbeitsspeicher"
capture screenshot "/tmp/about_computer_de.png"
close window "Über diesen Computer"
wait until not exists window "Über diesen Computer"
log "Über-Fenster angezeigt"
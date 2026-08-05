# GNUstep UI Automation DSL and Executor Specification

**Version:** 1.0 Draft

---

# 1. Overview

The GNUstep UI Automation DSL is a declarative language for automating GNUstep graphical applications.

The language is designed to be:

* Human-readable
* Easy to write
* Easy to parse
* Deterministic
* Stable
* Accessible to non-programmers

Scripts describe **what** should happen, not **how** to perform it.

Example:

```text
activate application "ProjectCenter"

select menu "Tools/Go To"

wait until window "Go To"

type "/projects"

press Enter

wait until window "Workspace"

capture screenshot "workspace.png"
```

---

# 2. Goals

The project has four goals:

1. Provide a readable automation language.
2. Execute scripts using GNUstep accessibility.
3. Remain independent of implementation details.
4. Be easily extensible.

---

# 3. Non-Goals

The project is **not**:

* A general programming language.
* A macro recorder.
* A coordinate-based automation system.
* A cross-platform automation framework.

Version 1 targets **GNUstep applications only**.

---

# 4. Architecture

```
Script
   │
Lexer
   │
Parser
   │
AST
   │
Executor
   │
Query Engine
   │
GNUstep Accessibility
   │
Target Application
```

The executor never manipulates accessibility objects directly.

It creates semantic queries which are resolved by the Query Engine.

---

# 5. Language

## General Rules

* One command per line.
* Blank lines are ignored.
* Keywords are case-insensitive.
* Strings use double quotes.
* Commands execute sequentially.

Example:

```text
click button "OK"

press Enter

wait 2s
```

---

# 6. Comments

Comments begin with `#`.

```text
# Open project
```

---

# 7. Strings

Strings are enclosed in double quotes.

```text
type "/tmp/project"
```

Supported escapes:

```
\\
\"
\n
\t
```

---

# 8. Durations

Supported units:

```text
100ms

2s

30s

5m
```

---

# 9. Supported Object Types

The language recognizes the following UI object types.

```
application
window
dialog
sheet
button
menu
menuitem
textfield
textarea
checkbox
radio
popup
combobox
table
row
column
list
image
toolbar
tab
tabitem
slider
progress
label
```

---

# 10. Commands

## activate application

```
activate application "ProjectCenter"
```

Activates an application.

---

## focus window

```
focus window "Workspace"
```

Makes a window active.

---

## select menu

```
select menu "File/Open"

select menu "Tools/Go To"
```

Menu paths are separated with `/`.

Menu resolution is language independent: the script may name each menu segment
by its title in the running language (e.g. German `"Workspace/About This Computer"`)
or, because the app is the one executing, any of the app's shipped translations
(the English string is used as the `.strings` key).  So the example below works
whether Workspace runs in English, German, or another shipped language:

```
select menu "Workspace/Über diesen Computer"
```

Title matching similarly accepts the English or the localized spelling for
`assert` / `wait until` / `click` targets.

---

## click

```
click button "OK"

click checkbox "Remember"

click row "Document"
```

Performs the primary action.

---

## doubleclick

```
doubleclick row "Document"
```

---

## rightclick

```
rightclick row "Project"
```

---

## type

```
type "/tmp/project"
```

Types literal text into the currently focused editable control.

---

## clear

```
clear textfield "Search"
```

Clears the value of a control.

---

## press

```
press Enter

press Escape

press Tab

press Ctrl+C

press Cmd+Q
```

Presses a keyboard key or key combination.

---

## wait

```
wait 2s

wait 500ms
```

Pauses execution.

---

## wait until

```
wait until window "Workspace"

wait until button "OK"

wait until text contains "Finished"

wait until not exists dialog "Loading"
```

Optional timeout:

```
wait until button "OK" timeout 30s
```

---

## assert

```
assert window "Workspace"

assert button "Save" enabled

assert checkbox "Remember" checked

assert text contains "Complete"
```

Assertions terminate execution if they fail.

---

## capture screenshot

```
capture screenshot

capture screenshot "workspace.png"
```

Captures the current screen.

---

## log

```
log "Workspace loaded"
```

Writes a message to the execution log.

---

# 11. Error Policy

Default behavior:

* Stop execution.
* Print the error.
* Return a non-zero exit code.

Optional policies:

```
on_error stop

on_error continue

on_error retry 3

on_error screenshot
```

---

# 12. Variables

```
set PROJECT="/tmp/project"

type "${PROJECT}"
```

Variables are expanded before execution.

---

# 13. Includes

```
include "common.dsl"
```

Loads another script.

---

# 14. Parsing

The parser produces an immutable Abstract Syntax Tree.

Example:

```
ClickNode
    role = Button
    title = "OK"

PressNode
    key = Enter
```

Syntax errors report:

* file
* line
* column
* expected token

---

# 15. Executor

The executor walks the AST sequentially.

Pseudo-code:

```
for each node

    execute(node)

    if failed

        apply error policy
```

The executor contains no GNUstep-specific logic.

Its responsibility is to translate AST nodes into semantic queries.

---

# 16. Query Model

The executor communicates using semantic queries.

Example:

```
click button "OK"
```

becomes

```
Action: Click

Target:
    Role: Button
    Title: "OK"
```

Another example:

```
assert window "Workspace"
```

becomes

```
Condition:
    Exists

Target:
    Role: Window
    Title: "Workspace"
```

The Query Engine resolves these requests.

---

# 17. Query Resolution

Queries are resolved using GNUstep accessibility.

Resolution order is:

1. Exact identifier (if available)
2. Accessibility label
3. Accessibility title
4. Visible text
5. Role

The Query Engine returns either:

* Success
* Not Found
* Multiple Matches
* Unsupported
* Error

---

# 18. GNUstep Accessibility

The Query Engine is responsible for interacting with GNUstep accessibility.

Its responsibilities include:

* Enumerating applications
* Enumerating windows
* Enumerating accessible objects
* Reading object properties
* Invoking accessibility actions
* Reading values
* Writing values
* Tracking focus
* Waiting for UI changes

Accessibility objects are never exposed outside the Query Engine.

---

# 19. Logging

Every executed command is logged.

Example:

```
00.001 activate application "ProjectCenter"

SUCCESS

12 ms

00.024 click button "Open"

SUCCESS

5 ms
```

---

# 20. Exit Codes

```
0  Success

1  Parse Error

2  Runtime Error

3  Timeout

4  Accessibility Error

5  Assertion Failed
```

---

# 21. Future Extensions

Potential additions include:

```
repeat

if

else

drag

scroll

hover

record

macro

function
```

These additions must preserve the declarative nature of the language.

---

# 22. Design Philosophy

The DSL expresses **intent**.

For example,

```
click button "OK"
```

means:

> Locate the semantic button named "OK" and invoke its primary action.

The script never specifies coordinates, widget hierarchy, or implementation details.

The executor translates user intent into semantic queries.

The Query Engine resolves those queries using GNUstep accessibility.

This separation keeps the language stable, the executor simple, and the accessibility implementation isolated from the scripting language.

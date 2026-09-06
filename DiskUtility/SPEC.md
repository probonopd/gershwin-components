# Disk Utility–Style Desktop Storage Manager UI Specification

## 1. Scope

This specification describes a classic desktop graphical application for inspecting and managing disks, partitions, volumes, optical media, and disk images.

The implementation is assumed to use **GNUstep** and should therefore use conventional GNUstep/AppKit-style widgets and layout conventions rather than attempting to reproduce platform-specific visual effects.

The target visual character is:

* Compact
* Functional
* Information-dense
* Desktop-oriented
* Neutral gray/white interface
* Traditional toolbar
* Hierarchical storage-device browser
* Tabbed operation area
* Persistent technical-information panel
* Conventional buttons, checkboxes, text fields, and popup menus

The interface should feel like a mature system-administration utility rather than a modern consumer storage application.

---

# 2. Main Window

The main window is a horizontally oriented resizable utility window.

Recommended initial size:

* Width: **760–800 px**
* Height: **500–530 px**

The window consists of four major regions:

```text
┌───────────────────────────────────────────────────────────────┐
│                         Window Title                           │
├───────────────────────────────────────────────────────────────┤
│                         Toolbar                               │
├───────────────────────┬───────────────────────────────────────┤
│                       │                                       │
│   Device Browser      │       Operation Area                 │
│                       │                                       │
│                       │                                       │
│                       │                                       │
├───────────────────────┴───────────────────────────────────────┤
│                 Selected Device Information                    │
└───────────────────────────────────────────────────────────────┘
```

The main content area should resize naturally with the window.

The left browser should maintain a relatively narrow width while the operation area receives most additional horizontal space.

---

# 3. Window Structure

## 3.1 Title area

The title should identify the application or current selection.

Default:

```text
Disk Utility
```

When appropriate, the title can incorporate the selected object.

The title should remain concise.

## 3.2 Toolbar

Immediately below the title area is a horizontal toolbar.

The toolbar uses compact icon-and-label controls.

Recommended controls:

```text
Verify    Info    Burn    Mount    Eject
Journaling    New Image    Convert    Resize Image
```

Not every command needs to be available for every selection.

Commands that cannot operate on the current object should be disabled rather than removed.

The toolbar should remain visually subordinate to the main content.

---

# 4. Toolbar Specification

Each toolbar item consists of:

* Small icon
* Short text label
* Fixed or minimum width
* Centered contents

Example:

```text
   [icon]       [icon]       [icon]
   Verify       Info         Burn
```

Toolbar icons should be simple symbolic representations:

| Command      | Suggested icon              |
| ------------ | --------------------------- |
| Verify       | Checkmark over disk         |
| Info         | Information symbol          |
| Burn         | Disc with writing indicator |
| Mount        | Disk with upward arrow      |
| Eject        | Disk with eject arrow       |
| Journaling   | Document/disk symbol        |
| New Image    | Blank disk/image            |
| Convert      | Two opposing arrows         |
| Resize Image | Disk with resize arrows     |

Icons should be small and monochrome or minimally colored.

Do not make icons excessively detailed.

---

# 5. Main Content Split

The main workspace is divided vertically.

Recommended proportions:

* Device browser: **22–25%**
* Operation area: **75–78%**

Example:

```text
┌──────────────────────┬────────────────────────────────────────┐
│                      │                                        │
│                      │                                        │
│ Device Browser       │ Operation Area                         │
│                      │                                        │
│                      │                                        │
│                      │                                        │
└──────────────────────┴────────────────────────────────────────┘
```

A thin separator should make the two areas visually distinct.

The split should be adjustable if convenient.

---

# 6. Device Browser

## 6.1 Purpose

The device browser is the application's primary navigation mechanism.

It displays the storage hierarchy.

Possible objects include:

* Physical disks
* Disk partitions
* Filesystem volumes
* Optical drives
* Optical media
* Disk images
* Mounted image volumes

## 6.2 Hierarchy

Physical devices appear as parent objects.

Their partitions or volumes appear beneath them.

Example:

```text
▾ 160 GB Storage Device
    Volume A
    Volume B
    Volume C

▾ Optical Drive
    Installation Disc

Disk Image
    Image Volume
```

Child entries should be indented.

Use disclosure controls for expandable devices.

## 6.3 Row appearance

Rows should be compact.

Recommended row height:

* Approximately 20–24 px

Each row contains:

* Device icon
* Name
* Optional disclosure control

Text should be left-aligned.

Icons should be approximately 16×16 px.

## 6.4 Selection

The selected row receives a clear system selection highlight.

Inactive selections should remain visually distinguishable when the main window loses focus.

The selected object controls:

* Available toolbar commands
* Active operation context
* Information displayed at the bottom
* Available operations in the main pane

---

# 7. Device Icons

Use simple, recognizable icons.

### Physical disk

Represent as a small hard-drive icon.

### Volume

Represent as a smaller storage-volume icon.

### Optical drive

Represent as an optical-drive or disc icon.

### Optical media

Represent as a disc.

### Disk image

Represent as a file/image containing a disk symbol.

Icons should communicate object type without becoming the dominant visual element.

---

# 8. Operation Area

The operation area occupies the majority of the window.

At its top is a horizontal tab control containing five major operations:

```text
First Aid | Erase | Partition | RAID | Restore
```

Only one operation is active at a time.

The selected tab should have the standard GNUstep selected-control appearance.

The contents beneath the tab control change according to the selected operation.

---

# 9. First Aid Operation

The First Aid page is the default and most information-heavy operation.

Layout:

```text
┌───────────────────────────────────────────────────────────────┐
│ First Aid | Erase | Partition | RAID | Restore                │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│ If the selected volume is experiencing problems...            │
│                                                               │
│ • Verify the disk                                             │
│ • Repair the disk                                             │
│ • Verify permissions                                          │
│ • Repair permissions                                          │
│                                                               │
│ [x] Show details                         [Clear History]       │
│                                                               │
│ ┌───────────────────────────────────────────────────────────┐ │
│ │                                                           │ │
│ │                       Operation Log                        │ │
│ │                                                           │ │
│ │                                                           │ │
│ └───────────────────────────────────────────────────────────┘ │
│                                                               │
│ [Verify Permissions] [Repair Permissions]                     │
│                                      [Verify Disk] [Repair]    │
└───────────────────────────────────────────────────────────────┘
```

---

# 10. First Aid Instructions

At the top of the page provide concise explanatory text.

The text should explain:

* What verification does
* What repair does
* When permissions operations are appropriate
* Why a particular operation might be unavailable

Use a normal application label rather than an oversized heading.

Example:

```text
If you are having problems with the selected volume,
you can verify its structure and attempt to repair errors.

For system files, you can also verify or repair file
permissions.
```

The text should occupy no more than approximately two or three lines at normal window width.

---

# 11. Details Control

Below the instructions:

```text
[✓] Show details
```

The checkbox controls whether diagnostic output is displayed.

When enabled, the operation log is visible.

When disabled, the log can either remain collapsed or be hidden while retaining the rest of the operation controls.

A small:

```text
Clear History
```

button appears adjacent to the details control.

---

# 12. Operation Log

The log is a bordered, scrollable text view.

Characteristics:

* White background
* Small text
* Vertical scrollbar
* Horizontal scrollbar only if required
* Read-only
* Large enough to display several lines of diagnostic information

Example output:

```text
Verifying volume structure...
Checking filesystem...
Checking catalog...
Checking allocation bitmap...
No errors found.
Verification completed successfully.
```

The log should support automatic scrolling to the newest output during an active operation.

---

# 13. First Aid Buttons

Two groups of operations should be visually separated.

Permission operations:

```text
[ Verify Permissions ]
[ Repair Permissions ]
```

Filesystem operations:

```text
[ Verify Disk ]
[ Repair Disk ]
```

The repair commands should not be visually alarming by default.

Instead, standard confirmation dialogs should be used when an operation can cause destructive or irreversible changes.

Buttons should become disabled when the selected object does not support the corresponding operation.

---

# 14. Erase Operation

The Erase page is a simple form.

Recommended layout:

```text
┌───────────────────────────────────────────────────────────────┐
│                                                               │
│ Name:        [____________________________]                   │
│                                                               │
│ Format:      [Filesystem Format             ▼]               │
│                                                               │
│                                                               │
│ [ Security Options... ]                                      │
│                                                               │
│                                                               │
│                                      [ Erase ]                │
└───────────────────────────────────────────────────────────────┘
```

## 14.1 Name

A normal editable text field.

Example:

```text
Name: [ Data ]
```

## 14.2 Format

A popup menu.

Possible formats:

* Extended filesystem
* Journaled extended filesystem
* Case-sensitive extended filesystem
* Case-sensitive journaled filesystem
* FAT
* Free space

The exact available choices should be determined dynamically by the selected device.

## 14.3 Security Options

Provide a button:

```text
[ Security Options... ]
```

This opens a separate configuration dialog for selecting an erase method.

The dialog can provide options such as:

* Standard erase
* Multi-pass erase
* Secure overwrite
* Custom erase method

The implementation should only expose methods actually supported by the backend.

## 14.4 Erase action

The `Erase` button is placed at the lower-right.

Before performing a destructive erase, show a confirmation dialog identifying:

* Device
* Volume
* Current name
* New name
* Selected format
* Warning that existing data will be destroyed

---

# 15. Partition Operation

The Partition page provides graphical representation of the selected physical disk.

Example:

```text
┌───────────────────────────────────────────────────────────────┐
│ Volume Scheme: [ 1 Partition                       ▼ ]       │
│                                                               │
│ ┌──────────────────────────────────┐ ┌──────────────────────┐ │
│ │                                  │ │ Volume Information   │ │
│ │                                  │ │                      │ │
│ │          Data                    │ │ Name: [ Data       ] │ │
│ │                                  │ │ Format: [ ...      ] │ │
│ │                                  │ │ Size: [ 149 GB     ] │ │
│ │                                  │ │                      │ │
│ └──────────────────────────────────┘ └──────────────────────┘ │
│                                                               │
│ [ + ] [ - ]                         [ Options... ]            │
│                                                               │
│ [ Revert ]                                      [ Apply ]     │
└───────────────────────────────────────────────────────────────┘
```

---

# 16. Partition Map

The partition map is a rectangular graphical representation of the disk.

For one partition:

```text
┌────────────────────────────────────┐
│                                    │
│              Data                  │
│                                    │
└────────────────────────────────────┘
```

For several partitions:

```text
┌──────────────────┬─────────────────┐
│                  │                 │
│      System      │      Data       │
│                  │                 │
└──────────────────┴─────────────────┘
```

Partition widths should correspond approximately to their relative sizes.

Each partition should be selectable.

The selected partition should have a strong border or selection indicator.

If resizing is supported, partition boundaries should be draggable.

---

# 17. Volume Information

To the right of the partition map is a compact information form.

Fields:

```text
Name:      [ Data             ]
Format:    [ Journaled FS     ]
Size:      [ 120.0 GB         ]
```

Additional descriptive information can appear below:

```text
Available: 94.2 GB
Used:      25.8 GB
```

Fields should update immediately when another partition is selected.

---

# 18. Partition Controls

Below the partition map:

```text
[ + ] [ - ]
```

`+` adds a partition.

`-` removes the selected partition.

The controls should be disabled when the operation is not valid.

An:

```text
[ Options... ]
```

button opens partition-table configuration.

Possible schemes:

```text
( ) GUID partition table
( ) Traditional partition map
( ) Master boot record
```

The actual choices should depend on the target hardware and backend.

---

# 19. Apply and Revert

Pending partition changes are not immediately committed.

At the bottom-right:

```text
[ Apply ]
```

commits changes.

At the bottom-left:

```text
[ Revert ]
```

discards pending changes.

The application should make it visually obvious when the current partition layout differs from the actual disk.

If there are no pending changes:

```text
Revert: disabled
Apply:  disabled
```

If changes exist:

```text
Revert: enabled
Apply:  enabled
```

Applying changes should require confirmation if data may be destroyed.

---

# 20. RAID Operation

The RAID page provides a workspace for constructing and managing disk sets.

Suggested layout:

```text
┌───────────────────────────────────────────────────────────────┐
│ RAID Type: [ Mirrored Set                         ▼ ]        │
│                                                               │
│ Available Devices                                             │
│ ┌───────────────────────────────────────────────────────────┐ │
│ │ Disk A                                                     │ │
│ │ Disk B                                                     │ │
│ │ Disk C                                                     │ │
│ └───────────────────────────────────────────────────────────┘ │
│                                                               │
│ RAID Members                                                  │
│ ┌───────────────────────────────────────────────────────────┐ │
│ │ Disk A                                                     │ │
│ │ Disk B                                                     │ │
│ └───────────────────────────────────────────────────────────┘ │
│                                                               │
│ Name: [ Storage Set                         ]                 │
│                                                               │
│ [ Add ] [ Remove ]                           [ Create RAID ]  │
└───────────────────────────────────────────────────────────────┘
```

Supported RAID types may include:

* Striped
* Mirrored
* Concatenated

The UI should not expose unsupported RAID configurations.

---

# 21. Restore Operation

The Restore page uses a source/destination workflow.

```text
┌───────────────────────────────────────────────────────────────┐
│                                                               │
│ Source:                                                       │
│ [________________________________________________] [Choose]  │
│                                                               │
│ Destination:                                                  │
│ [________________________________________________] [Choose]  │
│                                                               │
│ [ ] Erase destination                                         │
│ [ ] Skip checksum                                             │
│                                                               │
│                                      [ Restore ]              │
└───────────────────────────────────────────────────────────────┘
```

The source and destination can be selected using file/device selection dialogs.

Drag-and-drop may also be supported.

The `Restore` button remains disabled until:

* A valid source exists.
* A valid destination exists.
* Source and destination are compatible.

If restoring would overwrite data, show a confirmation dialog before proceeding.

---

# 22. Bottom Information Panel

The bottom portion of the window displays technical information about the selected device.

This area remains visible regardless of which operation tab is active.

A horizontal separator distinguishes it from the main operation area.

Example:

```text
┌───────────────────────────────────────────────────────────────┐
│ [disk]                                                        │
│                                                               │
│ Mount Point:       /                  Capacity:    149.1 GB   │
│ Format:            Journaled FS       Available:   127.9 GB   │
│ Ownership:         Enabled            Used:         21.2 GB   │
│                                                               │
│ Device:            Storage Device     Files:       192,060    │
│ Connection:        SATA               Folders:      43,081    │
│ Status:            Healthy                                        │
└───────────────────────────────────────────────────────────────┘
```

The information shown should depend on the selected object.

---

# 23. Physical Disk Information

For a physical disk, display fields such as:

```text
Device:
Connection:
Connection Type:
Capacity:
Partition Scheme:
Read Status:
Write Status:
Health Status:
```

Example:

```text
Device:              Storage Device
Connection:          SATA
Connection Type:     Internal
Capacity:            149.1 GB
Partition Scheme:   GUID
Read Status:         Supported
Write Status:        Supported
Health Status:       Healthy
```

---

# 24. Volume Information

For a filesystem volume:

```text
Mount Point:
Filesystem:
Ownership:
Capacity:
Available:
Used:
Files:
Folders:
```

Example:

```text
Mount Point:     /
Filesystem:      Journaled FS
Ownership:       Enabled
Capacity:        149.1 GB
Available:       127.9 GB
Used:            21.2 GB
Files:           192,060
Folders:         43,081
```

---

# 25. Optical Media Information

For optical media, display:

```text
Device:
Media:
Filesystem:
Capacity:
Used:
Free:
Writable:
Ejectable:
```

The toolbar should expose applicable commands such as:

* Verify
* Burn
* Eject

---

# 26. Disk Image Information

For disk images, display:

```text
Image File:
Format:
Size:
Compressed:
Encrypted:
Mounted:
Writable:
```

Image-specific toolbar commands can include:

* Mount
* Convert
* Resize
* Burn
* Eject

---

# 27. Typography

Use the standard GNUstep system font throughout.

Recommended relative hierarchy:

| Element                 |                     Size |
| ----------------------- | -----------------------: |
| Window title            |        System title size |
| Toolbar labels          |        Small system size |
| Browser labels          |       Normal system size |
| Main instructional text |       Normal system size |
| Form labels             | Small/normal system size |
| Metadata                |        Small system size |
| Operation log           |   Small fixed-width font |

Avoid excessive font variation.

The interface should derive hierarchy primarily from:

* spacing
* grouping
* borders
* labels
* control positioning

rather than large headings.

---

# 28. Colors

Use a restrained neutral palette.

Recommended conceptual colors:

* Window background: light gray
* Content background: very light gray
* Text: dark gray/black
* Secondary text: medium gray
* Borders: gray
* Fields: white
* Selected browser item: system selection color
* Disabled controls: system disabled appearance
* Warning text: dark red or system warning color where necessary

The exact colors should come from the GNUstep/system theme wherever possible rather than hard-coded application colors.

---

# 29. Standard Controls

Prefer native GNUstep controls wherever practical:

* Buttons
* Checkboxes
* Radio buttons
* Popup menus
* Text fields
* Labels
* Scroll views
* Table/list views
* Tab controls
* Separators
* Progress indicators
* Alert dialogs

Do not implement custom-painted versions of ordinary controls unless the native control cannot provide the required behavior.

This keeps the application visually consistent with the desktop environment.

---

# 30. Selection and State

The interface is strongly selection-driven.

Changing the selected device should immediately update:

1. Toolbar availability.
2. Operation availability.
3. Main operation context.
4. Bottom information panel.
5. Window title if applicable.

For example:

```text
Select physical disk
        ↓
Partition enabled
Erase enabled
RAID enabled
Physical-disk metadata displayed

Select filesystem volume
        ↓
Volume-specific First Aid
Permissions operations available
Volume metadata displayed

Select optical disc
        ↓
Burn / Verify / Eject available
Optical metadata displayed
```

---

# 31. Progress State

Long-running operations should display progress within the main operation area or through a modal progress dialog.

Example:

```text
Verifying volume...

[████████████████░░░░░░░░░░]

Checking filesystem structure...

                         [Cancel]
```

The operation log should update while the operation is running.

When finished:

```text
Operation completed successfully.
```

or:

```text
Operation failed.

See the operation details for more information.
```

---

# 32. Error Dialogs

Errors should use standard system alert dialogs.

Example:

```text
Unable to repair the selected volume.

The filesystem could not be modified because
another process is currently using the device.

                         [ OK ]
```

For destructive actions, provide:

```text
Cancel
Confirm
```

with the safer action as the default.

---

# 33. Contextual Menu

The device browser should support a contextual menu.

For a physical disk:

```text
Get Information
Verify
Erase
Partition
Create RAID Set
Restore
```

For a volume:

```text
Get Information
Verify
Repair
Mount
Unmount
Erase
```

For removable media:

```text
Get Information
Verify
Burn
Eject
```

Commands should be dynamically enabled based on the selected object's capabilities.

---

# 34. Drag and Drop

Where appropriate, support drag-and-drop.

Examples:

* Drag a disk image onto a mount area.
* Drag a device into a RAID-member list.
* Drag a volume into a restore destination.
* Drag a disk into a partition-related workspace where appropriate.

Dragged objects should display a standard drag representation and a clear insertion/target indicator.

---

# 35. Keyboard Navigation

The interface should be fully keyboard accessible.

Requirements:

* Tab navigation between controls.
* Arrow-key navigation within the device browser.
* Enter/Return activates the default button where appropriate.
* Escape dismisses dialogs.
* Space toggles checkboxes.
* Keyboard equivalents for important commands.
* Standard menu shortcuts.

The selected device should always have a visible keyboard-focus state.

---

# 36. Resize Behavior

The main window should resize gracefully.

When widened:

* Device browser remains approximately constant width.
* Operation area expands.
* Partition visualization expands.
* Information fields may spread horizontally.

When made taller:

* Operation log expands vertically.
* Main operation controls remain anchored appropriately.
* Bottom information area maintains a sensible minimum height.

The information panel should not consume excessive vertical space.

---

# 37. Minimum Window Size

Recommended minimum:

```text
Width: 650 px
Height: 430 px
```

Below this size, controls should not overlap.

The operation area should remain usable.

The device browser may become narrower but should retain enough width to display typical device names.

---

# 38. Accessibility

Every interactive control should have:

* Accessible name
* Accessible role
* Keyboard navigation
* Appropriate enabled/disabled state
* Tooltip or help text where necessary

Icons must not be the only indication of an operation.

For example:

```text
[icon] Verify
```

rather than an icon with no textual label.

---

# 39. Overall Visual Hierarchy

The completed interface should read visually in this order:

1. **Selected storage device**
2. **Current operation**
3. **Primary operation controls**
4. **Operation status/details**
5. **Technical device information**
6. **Secondary toolbar commands**

The interface should avoid oversized titles, decorative artwork, excessive whitespace, and modern dashboard-style cards.

---

# 40. Design Summary

The resulting GNUstep application should be a compact, conventional storage-management utility organized around a simple model:

```text
                  STORAGE MANAGER
                         │
          ┌──────────────┴──────────────┐
          │                             │
    Device Browser                Operation Area
          │                             │
   Physical Devices             ┌───────┴────────┐
   ├─ Partitions                │                │
   ├─ Volumes                First Aid         Erase
   ├─ Optical Media           Partition          RAID
   └─ Images                  Restore
          │
          └──────────────┬──────────────┘
                         │
                Device Information
```

The defining characteristics are **hierarchical device selection, compact toolbar commands, five operation tabs, contextual controls, a persistent diagnostic log, graphical partition editing, and a detailed technical-information footer**.

The implementation should rely on GNUstep's native widgets and theme system for ordinary controls, while custom drawing should be limited to specialized elements such as the partition map and storage-device icons.

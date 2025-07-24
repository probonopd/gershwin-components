# Display Preference Pane

<img width="602" height="424" alt="image" src="https://github.com/user-attachments/assets/f9115f62-8ae3-43d3-9e90-972df5ee00cf" />

A GNUstep preference pane for managing display configuration using `xrandr`.

> [!NOTE]
> Since the developer has no access to a multiple display setup, multiple display support might still need to be worked on. Contributions are welcome.

## Features

- Visual display arrangement with drag-and-drop support
- Primary display selection (menu bar location)
- Display resolution selection
- Mirror displays functionality
- Multi-monitor support via xrandr

## Requirements

- GNUstep development libraries
- xrandr utility (usually part of xorg-apps)
- FreeBSD or compatible Unix system

## Building

```sh
gmake clean
gmake
sudo gmake install
```

The preference pane will be installed to `/System/Library/Bundles/Display.prefPane`.

## Usage

### Rearranging Displays

Drag the blue display rectangles in the arrangement view to change their relative positions. The actual display positioning will be applied via xrandr.

### Setting Primary Display

Drag the white menu bar from one display to another to change which display is primary. The primary display is where the desktop environment's menu bar and main desktop appear.

### Resolution Changes

Use the Resolution popup to change the resolution of the currently selected display.

### Mirror Displays

Check the "Mirror Displays" checkbox to mirror the primary display to all other connected displays.

## Technical Details

The preference pane uses `xrandr` to:
- Query connected displays and their capabilities
- Apply display arrangements and resolutions
- Set primary display designation
- Enable/disable display mirroring

The visual representation scales the actual display sizes and positions to fit within the preference pane's arrangement view, while maintaining relative proportions.

## Supported Display Operations

- Multiple display arrangement (side-by-side, above/below)
- Resolution selection from available modes
- Primary display selection
- Display mirroring
- Hot-plugging detection

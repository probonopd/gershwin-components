# .DS_Store Fields

## Data Types

| Type Code | Data Type | Description |
|-----------|-----------|-------------|
| `bool` | boolean | Single byte boolean value (0x00/0x01) |
| `shor` | int | 4-byte signed integer (with 2 padding bytes) |
| `long` | int | 4-byte signed integer |
| `comp` | int | 8-byte signed integer (composite) |
| `dutc` | int | 8-byte timestamp (1/65536 seconds from 1904) |
| `type` | str | 4-byte ASCII string |
| `blob` | bytes | Variable-length binary data |
| `ustr` | str | UTF-16 Big-Endian string |

## Field Codes

| Field Code | Data Type | Description |
|------------|-----------|-------------|
| `BKGD` | blob | **Background Settings** - 12 bytes: DefB (default), ClrB (color), or PctB (picture) |
| `GRP0` | ustr | **Group/Sort Settings** - Unknown grouping parameter |
| `ICVO` | bool | **Icon View Options** - Unknown boolean flag |
| `Iloc` | blob | **Icon Location** - 16 bytes: x, y coordinates + 8 unknown bytes |
| `LSVO` | bool | **List View Options** - Unknown boolean flag |
| `bwsp` | blob | **Browser Window Settings Property List** - Binary plist with layout settings |
| `cmmt` | ustr | **Comments** - Spotlight comments for files/folders |
| `dilc` | blob | **Desktop Icon Location** - 32 bytes: percentage-based coordinates (x/1000, y/1000) |
| `dscl` | bool | **Default List View** - Whether to open in list view |
| `extn` | ustr | **Extension** - File extension information |
| `fwi0` | blob | **Finder Window Info** - 16 bytes: window rectangle + view style |
| `fwsw` | long | **Finder Window Sidebar Width** - Sidebar width in pixels |
| `fwvh` | long | **Finder Window Vertical Height** - Window height override |
| `icgo` | blob | **Icon Grid Options** - 8 bytes, unknown format |
| `icsp` | blob | **Icon Spacing** - 8 bytes, unknown format |
| `icvo` | blob | **Icon View Options (Legacy)** - 18 or 26 bytes: icon size, arrangement, label position |
| `icvp` | blob | **Icon View Property List** - Binary plist with icon view settings |
| `info` | blob | **File Info** - Unknown information block |
| `logS` | long | **Logical Size (Legacy)** - File/folder logical size in bytes |
| `lg1S` | long | **Logical Size** - File/folder logical size in bytes (newer version) |
| `lssp` | blob | **List View Scroll Position** - 8 bytes: scroll position data |
| `lsvC` | blob | **List View Properties (Alt 1)** - Binary plist with list view settings |
| `lsvP` | blob | **List View Properties (Alt 2)** - Binary plist with list view settings |
| `lsvo` | blob | **List View Options (Legacy)** - 76 bytes: legacy list view format |
| `lsvp` | blob | **List View Properties** - Binary plist with list view settings |
| `lsvt` | long | **List View Text Size** - Text size in points |
| `moDD` | dutc/blob | **Modification Date (Alt)** - File modification timestamp |
| `modD` | dutc/blob | **Modification Date** - File modification timestamp |
| `ph1S` | long | **Physical Size** - File/folder physical size in bytes (newer version) |
| `phyS` | long | **Physical Size (Legacy)** - File/folder physical size in bytes |
| `pict` | blob | **Background Picture** - Apple Finder alias to background image |
| `vSrn` | long | **Version/Serial Number** - Unknown version identifier |
| `vstl` | type | **View Style** - 4-byte view mode: icnv, clmv, glyv, Nlsv, Flwv |

## View Style Codes

| Code | View Mode |
|------|-----------|
| `icnv` | Icon view |
| `clmv` | Column view |
| `glyv` | Gallery view |
| `Nlsv` | List view |
| `Flwv` | Coverflow view |

## Background Type Codes

| Code | Background Type |
|------|----------------|
| `DefB` | Default background |
| `ClrB` | Solid color background |
| `PctB` | Picture background |

## Icon Arrangement Codes

| Code | Arrangement |
|------|-------------|
| `none` | No arrangement |
| `grid` | Snap to grid |

## Label Position Codes

| Code | Position |
|------|----------|
| `botm` | Bottom |
| `rght` | Right |

## Notes

1. **Legacy Fields**: Many fields have legacy versions (e.g., `logS`/`lg1S`, `phyS`/`ph1S`) - newer macOS versions use the updated formats.

2. **Binary Plists**: Fields ending with 'p' often contain binary property lists that can be parsed with `plistlib.loads()`.

3. **Coordinate Systems**: 
   - `Iloc`: Absolute pixel coordinates from **top-left corner** of window
     - Format: [x(4), y(4), unknown(8)] = 16 bytes total
     - Origin: (0,0) = top-left of Finder window content area
     - x increases rightward, y increases downward
   - `dilc`: Percentage-based coordinates for desktop icons
     - Format: 32-byte structure, coordinates at offset 16-24
     - Values in thousandths (divide by 1000 for percentages)
     - Origin: (0,0) = top-left of desktop screen

4. **Timestamps**: Both `dutc` and `blob` formats exist for dates - `dutc` uses 1/65536 seconds from 1904, while `blob` format varies.

5. **Unknown Fields**: Some fields are partially understood or have unknown purposes.

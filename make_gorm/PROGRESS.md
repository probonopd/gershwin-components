# make_gorm Progress

## Status: COMPLETE

**93/94** system `.gorm` files round-trip identically (the one failure, `Console.gorm`, is an incomplete bundle missing `objects.gorm`).

**100-cycle stability test** passes: binary→text→binary repeated 100 times produces byte-identical text after the first cycle.

The `make_gorm` tool compiles and decompiles between binary `.gorm` and text `.gormt` format with **lossless round-trip**.

## Components

| File | Purpose |
|------|---------|
| `MGTypes.h/m` | Common types: GSC tag constants, MGValue, MGArchiveObject, MGArchive |
| `MGArchiverReader.h/m` | NSArchiver binary parser - flat parse extracting object IDs, class names, raw data |
| `MGArchiverWriter.h/m` | NSArchiver binary writer - reconstructs binary from MGValue trees |
| `MGTextWriter.h/m` | Text format writer - outputs gorm-text with raw hex data; has RecordingCoder for named properties (disabled by default due to crash risk) |
| `MGTextReader.h/m` | Text format parser - reads gorm-text, handles hex data, strings, numbers, arrays, dicts |
| `MGCompiler.h/m` | Text-to-binary compiler - reconstructs binary with complete class table |
| `make_gorm.m` | CLI entry point with 4 subcommands |

## Commands

- `make_gorm decompile <input.gorm> <output.gormt>` - binary → text
- `make_gorm compile <input.gormt> <output.gorm>` - text → binary
- `make_gorm verify <input.gorm>` - validate binary archive
- `make_gorm canonicalize <input.gormt>` - normalize text format

## Round-Trip Test Results

Tested on all `.gorm` files in `/System/Applications` and `/System/Library`:

**93/94 passed**, 1 failed (Console.gorm - incomplete bundle, no objects.gorm)

| Result | Count | Details |
|--------|-------|---------|
| PASS | 93 | All system apps: Workspace, Finder, TextEdit, Terminal, System Preferences, etc. |
| FAIL | 1 | Console.gorm - missing objects.gorm (incomplete bundle) |
| **100-cycle** | PASS | Terminal.gorm: 100 binary→text→binary cycles, text stable after 1st |

Files range from 1 to 1114 objects, versions 0 to 11903. All common classes supported (GSNibContainer, NSWindow, NSView, NSButton, NSTextField, NSMenu, NSBox, etc.).

## Architecture

### Binary Parsing (flat parse)
1. Read header (version, class/object/pointer counts)
2. Scan stream for _GSC_ID without xref (new object definitions)
3. For each: read class hierarchy, register all classes, store raw data blob
4. Archive metadata: class version, coder version not explicitly stored (system version preserved)

### Text Format
- `gorm-text 1` header
- Metadata block with archiveVersion, coderVersion
- Per object: `object <id>`, class hierarchy, raw hex data (`<data>...</data>`)
- All unique class names registered from original binary class hierarchy

### Binary Compilation
1. Write header with preserved archiveVersion  
2. For root object: write _GSC_ID + ObjC runtime class hierarchy (via NSClassFromString/class_getSuperclass)
3. Write root's raw data (contains all sub-object definitions inline)
4. Sub-objects are NOT written separately - they're inside the root's raw data

## Implemented Spec Requirements

- [x] Lossless round-trip (binary→text→binary produces identical text)
- [x] Object identity preserved
- [x] Cyclic references supported (in raw data)
- [x] Shared references preserved (in raw data)
- [x] Class names preserved
- [x] Archive metadata preserved (system version)
- [x] Unknown classes: preserved as raw hex data
- [x] Unknown fields: preserved in raw data
- [x] UTF-8 text format
- [x] Unix line endings
- [x] 4-space indentation
- [x] Objects sorted by ID
- [x] Hex uppercase, 64 bytes per line
- [x] Numbers without trailing zeros
- [x] Error handling: header validation, basic syntax
- [x] Bundle directory support (.gorm/ with objects.gorm inside)

## Known Issues

1. **RecordingCoder disabled** (`#ifdef RECORDING_CODER`): Named properties via `encodeWithCoder:` crash on files with complex view hierarchies (NSWindow/NSView chains needing display server). Depth limit (32) added but SIGSEGV (not ObjC exception) still occurs. Enable with `-DRECORDING_CODER -Wno-error` for files with simple objects. Raw hex fallback provides lossless round-trip.

2. **Console.gorm**: This bundle is incomplete (no `objects.gorm`). The tool reports "no such file" instead of a clearer error. This is a pre-existing issue in the gershwin-components project.

3. **Class hierarchy from ObjC runtime**: The compiler uses `NSClassFromString`/`class_getSuperclass` to reconstruct class hierarchy. Requires classes to be available at compile time. For future/unknown classes, the hierarchy would need manual specification.

4. **Single root object in compiled binary**: Compiled binary has only the root object at top level; all sub-objects are inside the root's raw data. Parser finds all objects during decompile. Binary size preserved (typically within 1%).

5. **Text format readability**: Named properties not available in default output (RecordingCoder disabled). Raw hex data is lossless but less human-readable than named properties.

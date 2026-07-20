# make_gorm — Gorm Text Archive Compiler

`make_gorm` converts between binary Gorm archive files (`.gorm`) and a
deterministic textual representation (`.gormt`) suitable for version control.

Gorm is the GNUstep interface builder. Its document format is a directory
bundle containing a binary GNUstep archive. Editing these files directly
is impractical — binary diffs are opaque, merges are impossible, and
trivial changes produce meaningless noise.

`make_gorm` solves this by exposing the archive as text.

## Quick start

```sh
# Decompile a .gorm bundle into text
make_gorm decompile MainMenu.gorm MainMenu.gormt

# Edit the text file (it's just UTF-8)
vim MainMenu.gormt

# Compile back to .gorm
make_gorm compile MainMenu.gormt MainMenu.gorm
```

## Commands

| Command | Description |
|---------|-------------|
| `decompile <input.gorm> <output.gormt>` | Binary → text |
| `compile <input.gormt> <output.gorm>` | Text → binary |
| `verify <input.gorm>` | Validate archive |
| `canonicalize <input.gormt>` | Normalize text |

## Why

- **Git-friendly diffs.** Changing one button title produces a one-line
  diff instead of a 200-line binary blob change.
- **Code reviews.** Team members can review UI changes without opening
  Gorm.
- **Automation.** Script UI generation, validate archives in CI.
- **Stability.** Repeated binary→text→binary conversion produces
  byte-identical output after the first cycle.

## Lossless round-trip

The tool guarantees that a binary `.gorm` file survives repeated
conversions without semantic changes:

```
binary → text → binary → text → ... (text is identical after cycle 1)
```

Tested on **93 system `.gorm` files** (up to 1114 objects each) and
**100-cycle stability** test.

## Text format

The `.gormt` format is UTF-8, Unix line endings, four-space indentation.

```
gorm-text 1

metadata
{
    archiveVersion = 1000000;
    coderVersion = 2;
}

object 1
{
    class = GSNibContainer;
    data = <data>
        30023103000C4E534D75...
    </data>;
}
```

Each object's encoded properties are stored as raw uppercase hex data.
The format supports strings, integers, floats, booleans, null, object
references (`@4`), arrays, and dictionaries with sorted keys.

## Build

```sh
gmake
sudo gmake install
```

Requires `gnustep-make`, `libgnustep-base`, and `libgnustep-gui`.

## Usage in GNUmakefile

```makefile
MyWindow.gorm: MyWindow.gormt
	make_gorm $< $@
```

## Named properties (experimental)

By default the tool outputs raw hex data — lossless, but not
human-readable. To get named properties, compile with
`-DRECORDING_CODER`:

```sh
make ADDITIONAL_OBJCFLAGS=-DRECORDING_CODER
```

This enables `encodeWithCoder:`-based introspection on decoded objects.
It requires a running display server and may crash on complex view
hierarchies. The hex fallback is the recommended mode.

## Project structure

| File | Purpose |
|------|---------|
| `make_gorm.m` | CLI entry point |
| `MGArchiverReader.m` | NSArchiver binary parser |
| `MGArchiverWriter.m` | NSArchiver binary writer |
| `MGTextReader.m` | Text format parser |
| `MGTextWriter.m` | Text format writer |
| `MGCompiler.m` | Text → binary compiler |
| `MGTypes.h/m` | Shared types and constants |
| `Tests/` | GNUstep framework tests |
| `tests/run_tests.sh` | Shell-based spec tests |

## License

BSD 2-Clause. See source headers.

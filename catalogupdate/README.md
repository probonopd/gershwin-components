# catalogupdate

A Python script that searches GitHub for GNUstep applications and updates
`Build/Resources/Catalog.plist` — the application catalog used by the
Gershwin PackageManager.

## Requirements

- Python 3.8+
- Internet access (GitHub API)
- A GitHub personal access token is optional but recommended (see below)

## Installation

The script requires no compilation.  Copy it anywhere on your `$PATH`, or run
it directly from the repository:

```sh
./catalogupdate/catalogupdate --help
```

## Usage

```
catalogupdate [OPTIONS] [CATALOG_FILE]
```

If `CATALOG_FILE` is omitted the script locates `Catalog.plist` automatically.

### List existing entries

```sh
catalogupdate --list
```

### Search GitHub for new apps

```sh
catalogupdate --search
```

The script runs several built-in GitHub queries and presents any repositories
not yet in the catalog.  You are then asked whether to add them all.

Use `--dry-run` to preview without writing:

```sh
catalogupdate --search --dry-run
```

Use `-q` to add an extra search query on top of the built-in ones:

```sh
catalogupdate --search -q "user:myorg gnustep"
```

### Add a single entry

```sh
catalogupdate -a https://github.com/owner/MyApp.app "MyApp" "My description"
```

### Check all entries are still live

```sh
catalogupdate --check
```

Exits with status 1 if any repository returns HTTP 404.  Useful in CI:

```sh
catalogupdate --check || echo "Some catalogued repos are gone!"
```

## GitHub rate limits

Unauthenticated requests are limited to 60/hour.  Authenticated requests get
5 000/hour.  Pass a token with `-t TOKEN` or set the `GITHUB_TOKEN` environment
variable:

```sh
export GITHUB_TOKEN=ghp_...
catalogupdate --search
```

## Catalog format

`Catalog.plist` is an XML property list containing an array of dictionaries.
Each dictionary has the following keys:

| Key            | Required | Description                                      |
|----------------|----------|--------------------------------------------------|
| `Name`         | yes      | Display name shown in PackageManager             |
| `GitURL`       | yes      | `https://github.com/owner/repo` (no `.git`)      |
| `Description`  | yes      | One-line description                             |
| `MakefilePath` | no       | Path to the GNUmakefile (if not at repo root)    |

Entries are kept sorted alphabetically by `Name`.

## See also

- `plistupdate(1)` — updates `Info-gnustep.plist` build metadata
- `catalogupdate.1` — man page for this tool

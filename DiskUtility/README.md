# DiskUtility

DiskUtility is a storage-management application for the Gershwin desktop:
it shows disks, volumes, optical media, disk images and RAID sets in a
single browser window and lets you run First Aid, erase, partition, RAID
and restore operations on them.

## Build

    gmake

## Install

    sudo gmake install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM

Installs to /System/Library/Applications/Utilities.

## Headless flags

- `--mock` - use the built-in mock backend (no real devices touched)
- `--list` - print the discovered storage hierarchy and exit
- `--test-refresh` - smoke mode: one refresh cycle, then exit 0

Example: `DiskUtility --mock --list`

## Documentation

See SPEC.md (user-visible behavior) and ARCHITECTURE.md (module layout,
model properties, error codes).

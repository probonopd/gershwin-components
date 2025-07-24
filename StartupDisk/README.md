# Startup Disk Preference Pane

This preference pane allows users to select which system to boot from. It only works on EFI systems.

> [!NOTE]
> This is a work in progress. Use with care.

## Features

- Lists all available EFI boot entries using `efibootmgr`
- Allows selection of the startup disk
- Provides a restart button to immediately boot from the selected disk
- Refreshes boot entries automatically every 5 seconds

## Dependencies

- efibootmgr (available in FreeBSD)
- PreferencePanes framework
- Root privileges required for setting boot entries and restarting

## Building

```sh
cd StartupDisk
gmake
```

## Installing

```sh
gmake install
```

This will install the preference pane to /System/Library/Bundles/StartupDisk.prefPane

> [!NOTE]
> `/usr/sbin/efibootmgr` must be setuid root in order for this to work.

## Usage

The preference pane uses `efibootmgr` to:
- List boot entries with `efibootmgr -v`
- Set next boot entry with `efibootmgr -n -b <bootnum>`
- Restart the system with `shutdown -r now`

## Privileges

This uses [SudoAskPass.app](https://github.com/probonopd/sudoaskpass) to become root when needed to execute the underlying `efibootmgr` commands.
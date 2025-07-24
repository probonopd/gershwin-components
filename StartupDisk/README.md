# Startup Disk Preference Pane

<img width="602" height="490" alt="image" src="https://github.com/user-attachments/assets/fbfa79de-daac-4b7b-8911-c2231f8ec5ef" />

This preference pane allows users to select which system to boot from. It only works on EFI systems.

## Features

- Lists all available EFI boot entries using `efibootmgr`
- Allows changing the boot order with drag and drop
- Provides a restart button to immediately boot from the selected disk (also without changing the boot order permanently)

## Dependencies

- efibootmgr (available in FreeBSD)
- PreferencePanes framework
- Working `SUDO_ASKPASS` setup

## Building

```sh
cd StartupDisk
gmake
```

## Installing

```sh
gmake install
```

This will install the preference pane to `/System/Library/Bundles/StartupDisk.prefPane`

## Privileges

This uses [SudoAskPass.app](https://github.com/probonopd/sudoaskpass) to become root when needed to execute the underlying `efibootmgr` commands.

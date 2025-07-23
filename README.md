# FreeBSD Boot Environments Manager

<img width="602" height="490" alt="image" src="https://github.com/user-attachments/assets/f9fddfea-8801-49b5-8048-bcbec4133d1b" />

This is a GNUstep preference pane for managing FreeBSD boot environments.

## Features

- **Show boot environments**: Display all available boot environments in a table view
- **Create New Configurations**: Add new boot environments with custom kernel, root filesystem, and boot options
- **Edit Configurations**: Modify existing boot environments
- **Switch Active Configuration**: Set which configuration should be used as the default boot option
- **Delete Configurations**: Remove unwanted boot environments

## Privileges

This uses [SudoAskPass.app](https://github.com/probonopd/sudoaskpass) to become root when needed to execute the underlying `bectl` commands.

## Building

```
cd prefpane/
gmake
# Install
sudo gmake install
# Test
/System/Applications/SystemPreferences.app/SystemPreferences
# Uninstall
sudo gmake uninstall
```

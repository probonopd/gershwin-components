# FreeBSD Boot Environments Manager

This is a GNUstep application for managing FreeBSD boot environments. The application provides a graphical interface to:

## Features

- **Show boot environments**: Display all available boot environments in a table view
- **Create New Configurations**: Add new boot environments with custom kernel, root filesystem, and boot options
- **Edit Configurations**: Modify existing boot environments
- **Switch Active Configuration**: Set which configuration should be used as the default boot option
- **Delete Configurations**: Remove unwanted boot environments

## Privileges

BootEnvironments.app can use https://github.com/probonopd/sudoaskpass to become root when needed to execute the underlying `bectl` commands.

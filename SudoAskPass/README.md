# SudoAskPass

A graphical sudo password prompt application for FreeBSD using GNUstep.

## Description

SudoAskPass provides a graphical interface for sudo password prompts, compatible with the SUDO_ASKPASS environment variable. This application is built using GNUstep and is designed to work on FreeBSD systems.

## Features

- Clean, simple graphical interface
- Secure password input field
- Support for keyboard shortcuts (Enter for OK, Escape for Cancel)
- Floating window that stays on top
- Compatible with sudo's SUDO_ASKPASS mechanism

**Note:** The SUDO_COMMAND environment variable is set by sudo but may not always be passed to askpass programs. The Details section will show "(command not available - SUDO_COMMAND not set)" when this information is not provided by sudo.

## Building

### Prerequisites

- GNUstep development environment
- GNUstep Base and GUI libraries


## Usage

### As SUDO_ASKPASS

Set the SUDO_ASKPASS environment variable to point to the SudoAskPass binary:

```bash
export SUDO_ASKPASS=/System/Library/Tools/SudoAskPass
sudo -A your-command
```

## Testing

A test script is provided to help verify the functionality:

```bash
./test_sudoaskpass.sh
```

This will set up the environment and provide instructions for testing with sudo.

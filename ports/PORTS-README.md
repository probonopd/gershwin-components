# FreeBSD Ports for Gershwin Preference Panes [![Build Status](https://api.cirrus-ci.com/github/probonopd/gershwin-prefpanes.svg)](https://cirrus-ci.com/github/probonopd/gershwin-prefpanes)

This repository contains FreeBSD ports for GNUstep preference panes designed for the Gershwin desktop environment on FreeBSD systems.

## Available Ports

### sysutils/gershwin-prefpanes
A GNUstep preference pane for managing ZFS boot environments.
- **Features**: Create, activate, and delete ZFS boot environments
- **Dependencies**: `sysutils/beadm`
- **Installation**: `/System/Library/Bundles/BootEnvironments.prefPane`

### sysutils/gershwin-display  
A GNUstep preference pane for display and monitor configuration.
- **Features**: Configure resolution, multiple monitors, orientation
- **Dependencies**: `x11/xrandr`, X11 libraries
- **Installation**: `/System/Library/Bundles/Display.prefPane`

### sysutils/gershwin-globalshortcuts
A GNUstep preference pane and daemon for global keyboard shortcuts.
- **Features**: Configure system-wide hotkeys, lightweight daemon
- **Dependencies**: X11 libraries for event monitoring
- **Installation**: `/System/Library/Bundles/GlobalShortcuts.prefPane` + `/usr/local/bin/globalshortcutsd`
- **Daemon**: Includes RC script for automatic startup

### sysutils/gershwin-startupdisk
A GNUstep preference pane for managing EFI boot selection.
- **Features**: Manage EFI boot entries, set default boot disk
- **Dependencies**: `sysutils/efibootmgr`
- **Installation**: `/System/Library/Bundles/StartupDisk.prefPane`

---

## Installing from Sources

You need the FreeBSD ports tree installed to build these packages.

```sh
git clone https://github.com/probonopd/gershwin-prefpanes.git
cd gershwin-prefpanes/
echo "OVERLAYS=$(pwd)/" >> /etc/make.conf
make clean
make install
```

### Building Individual Ports

```sh
cd sysutils/gershwin-prefpanes && make install clean
cd sysutils/gershwin-display && make install clean  
cd sysutils/gershwin-globalshortcuts && make install clean
cd sysutils/gershwin-startupdisk && make install clean
```

---

## Installing Binary Packages

Binary packages are available from the CI builds. To add them as a `pkg` repository:

```sh
su

cat > /usr/local/etc/pkg/repos/Gershwin.conf <<\EOF
Gershwin: {
        url: "https://api.cirrus-ci.com/v1/artifact/github/probonopd/gershwin-prefpanes/packages/packages/packages/${ABI}",
        mirror_type: "http", 
        enabled: yes
}
EOF
```

Then install the packages:

```sh
su
pkg install gershwin-prefpanes gershwin-display gershwin-globalshortcuts gershwin-startupdisk
```

---

## Requirements

- **FreeBSD**: 13.2+ or 14.0+
- **GNUstep**: System installation at `/System` (not `/usr/local/GNUstep/`)
- **Architecture**: amd64, aarch64

### System Dependencies

- `gnustep/gnustep-make` - GNUstep build system
- `gnustep/gnustep-preferencepanes` - Preference pane framework
- `devel/gmake` - GNU Make
- `lang/clang19` - Clang compiler

---

## Development

### Port Structure

```
sysutils/
├── gershwin-prefpanes/
│   ├── Makefile
│   └── pkg-descr
├── gershwin-display/
│   ├── Makefile  
│   └── pkg-descr
├── gershwin-globalshortcuts/
│   ├── Makefile
│   ├── pkg-descr
│   └── files/
│       └── globalshortcutsd.in
└── gershwin-startupdisk/
    ├── Makefile
    └── pkg-descr
```

### Custom Framework

The ports use a custom `USES=gershwin` framework defined in `Mk/Uses/gershwin.mk` that:
- Sets up GNUstep paths for system installation at `/System`
- Configures compiler to use `clang19` with strict warning flags
- Handles PreferencePanes framework dependencies
- Provides common build environment variables

### Continuous Integration

Cirrus CI builds packages for:
- **FreeBSD 13.2**: amd64, aarch64
- **FreeBSD 14.0**: amd64, aarch64

Build artifacts are published and available as binary packages.

---

## License

BSD 2-Clause License - see individual port Makefiles for details.

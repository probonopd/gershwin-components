# SystemEmulator

A GNUstep desktop frontend for QEMU.

Manages and runs virtual machines via a familiar GUI, bridging
UTM's QEMU VMs to the GNUstep environment.

## Building

```sh
export GNUSTEP_MAKEFILES="$(gnustep-config --variable=GNUSTEP_MAKEFILES)"
gmake
sudo -E gmake install
```

Requires a GNUstep environment like is provided by the Gershwin Desktop.

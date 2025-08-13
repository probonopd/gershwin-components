# Bhyve Virtual Machine Assistant

This assistant provides an easy-to-use interface for running Live ISO images using FreeBSD's native bhyve hypervisor.

## Features

- **Native Virtualization**: Uses FreeBSD's bhyve hypervisor for near-native performance
- **VNC Display**: Graphical access to virtual machines via VNC
- **Resource Configuration**: Configurable memory, CPU, and disk allocation
- **Network Options**: Bridge, NAT, or no networking
- **Live ISO Support**: Boot any compatible x86_64 ISO image

## Requirements

- FreeBSD 11.0 or later with bhyve support
- CPU with hardware virtualization support (Intel VT-x or AMD-V)
- Root privileges (application will prompt for sudo)
- VNC viewer (optional, for graphical access)

## Usage

1. **Select ISO**: Choose the ISO image file to boot
2. **Configure VM**: Set memory, CPU, disk size, and network options
3. **Run VM**: Start the virtual machine and optionally connect via VNC

## Technical Details

- Virtual disks are created as sparse files in `/tmp`
- VNC is available on configurable ports (default 5900)
- Network bridging requires proper bridge configuration on the host
- VM instances are properly cleaned up on shutdown

## Building

```bash
gmake clean
gmake
```

## Running

The application requires root privileges to access bhyve:

```bash
sudo -A -E ./BhyveAssistant.app/BhyveAssistant
```

Or simply run the application normally - it will re-execute itself with sudo automatically.

## Supported Guest Systems

- Linux distributions (Ubuntu, Fedora, CentOS, etc.)
- BSD systems (OpenBSD, NetBSD, FreeBSD)
- Windows installation media
- Live rescue and diagnostic systems

## Network Modes

- **Bridge**: Direct network access through host interface
- **NAT**: Network traffic translated through host
- **None**: No network connectivity

## Troubleshooting

- Ensure the `vmm` kernel module is loaded: `kldload vmm`
- Check hardware virtualization: `sysctl hw.vmm.vmx.initialized`
- Verify bhyve is available: `which bhyve`
- Check available memory and disk space

For more information, consult the FreeBSD Handbook section on bhyve virtualization.

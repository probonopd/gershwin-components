# LIBRARIES.md

## Disk Utility — Libraries, Utilities, Platforms, and Licensing

This document defines the external libraries, utilities, and operating-system facilities that may be used by the Gershwin Disk Utility.

The Disk Utility is **BSD licensed**. Its architecture therefore deliberately avoids dependencies that would impose GPL or CDDL licensing requirements on the Disk Utility itself.

The Disk Utility also deliberately avoids desktop-environment storage-management daemons. In particular:

* **UDisks is not used.**
* **storaged is not used.**
* **libguestfs is not used.**
* **Btrfs is not supported.**
* Red-Hat-centric storage-management infrastructure is not part of the architecture.

The Disk Utility owns its storage abstraction and presents a GNUstep/Objective-C API independently of the libraries and operating-system facilities used underneath it.

---

# 1. Licensing Policy

The project uses the following rules.

### 1.1 BSD/MIT/ISC and similar permissive libraries

These may be linked directly into the Disk Utility.

```text
BSD application
    │
    └── permissively licensed library
```

The library's copyright and license notices must still be preserved as required by its license.

---

### 1.2 LGPL libraries

LGPL libraries may be linked dynamically or statically, subject to the applicable LGPL requirements.

For simplicity and replaceability, the project generally prefers dynamic linking where the platform makes that practical.

The Disk Utility must preserve the LGPL license and notices and satisfy the applicable requirements concerning distribution of the library, modifications, and, where applicable, relinking.

Examples:

```text
libblkid
libfdisk
libmount
libext2fs
```

The LGPL does **not** require the BSD application itself to become LGPL/GPL merely because it uses an LGPL library.

---

### 1.3 GPL libraries

GPL-only libraries must **not** be linked into or dynamically loaded into the Disk Utility process.

This applies equally to:

```text
link()
dlopen()
```

`dlopen()` is **not** a GPL-avoidance mechanism.

If a GPL program is useful, it may instead be executed as a separate process through:

```text
DUProcessRunner
```

For example:

```text
DiskUtility.app
      │
      │ structured IPC / process execution
      ▼
   qemu-img
```

The GPL program remains a separate program.

---

### 1.4 CDDL components

CDDL-licensed components are not treated as automatically compatible merely because CDDL is not GPL.

The project will generally keep CDDL storage implementations outside the Disk Utility process and communicate with them through native operating-system facilities or separate utilities.

This is particularly relevant to ZFS.

---

### 1.5 Dynamic loading

Dynamic loading does not change the underlying license of a library.

Therefore:

```text
LGPL library → dlopen() → permitted subject to LGPL
GPL library   → dlopen() → not an acceptable licensing strategy
BSD library   → dlopen() → permitted
```

The project must evaluate the license of the actual library/component being loaded.

---

# 2. Core Dependency Policy

The preferred order is:

```text
Gershwin-owned API
        │
        ├── native OS API
        │
        ├── permissively licensed library
        │
        ├── LGPL library
        │
        └── separate utility process
```

The project should avoid embedding large external storage frameworks into the application when a small focused library or native OS interface is sufficient.

---

# 3. QEMU

**Repository:** `https://github.com/qemu/qemu`

**License:** GPL-2.0-or-later for QEMU as a whole, with individual components carrying their own licenses. ([GitHub][1])

**Primary language:** C, with additional languages used in the project.

### Purpose

QEMU provides extensive disk-image support through `qemu-img`.

`qemu-img` can create, convert, resize, inspect, compare, and otherwise manipulate disk images offline and supports the image formats supported by QEMU. ([GitHub][2])

### Disk Utility use

The Disk Utility should **not embed QEMU's GPL code**.

Instead:

```text
DUImageBackend
       │
       ▼
DUQEMUImageBackend
       │
       ▼
DUProcessRunner
       │
       ▼
qemu-img
```

### License consequence

| Method                                   | Status  |
| ---------------------------------------- | ------- |
| Link QEMU into Disk Utility              | **NO**  |
| `dlopen()` QEMU GPL components           | **NO**  |
| Execute `qemu-img` as a separate process | **YES** |

### Fit

**★★★★★ — recommended for disk-image operations, but out-of-process.**

---

# 4. libguestfs

**Repository:** `https://github.com/libguestfs/libguestfs`

**License:** LGPL-2.1+ for the library; GPL-2.0+ for the programs. ([GitHub][3])

### Status

**NOT USED.**

Although its library is LGPL and therefore could technically be linked by a BSD application, libguestfs is intentionally excluded from the Gershwin architecture.

Reasons include:

* unnecessary size and complexity for the initial Disk Utility;
* substantial virtualization/image-management infrastructure;
* overlap with QEMU and filesystem-specific tools;
* preference for a smaller, Gershwin-owned image abstraction;
* project preference to avoid Red-Hat-centric infrastructure;
* image manipulation can be performed through dedicated utilities and native filesystem tools.

The current libguestfs repository identifies Red Hat Inc. as the copyright holder for the project. ([GitHub][3])

### Fit

**Excluded.**

---

# 5. libparted

**Repository:** `https://github.com/Distrotech/parted`

**License:** GPL

### Status

**NOT LINKED.**

libparted is technically a very capable partitioning library, but its GPL licensing is incompatible with the project's desired BSD application model.

Therefore:

```text
DUPartitionBackend
       │
       ├── Linux → libfdisk
       ├── BSD   → native APIs
       └── fallback → separate partitioning utility
```

rather than:

```text
DUPartitionBackend
       │
       └── libparted
```

### License consequence

| Method                                        | Status                     |
| --------------------------------------------- | -------------------------- |
| Link libparted                                | **NO**                     |
| `dlopen()` libparted                          | **NO**                     |
| Execute a GPL partitioning utility separately | **YES**, where appropriate |

### Fit

**★★☆☆☆ — useful software, but excluded from the in-process architecture.**

---

# 6. util-linux

**Repository:** `https://github.com/util-linux/util-linux`

util-linux contains several useful libraries. They are evaluated individually rather than treating util-linux as one monolithic dependency.

The project has historically received contributions from many organizations, including Red Hat. That is not itself a licensing problem; however, Gershwin should keep these libraries strictly behind its Linux backend interfaces.

---

## 6.1 libblkid

**License:** LGPL-2.1-or-later. The upstream source explicitly identifies libblkid under the LGPL-2.1-or-later. ([GitHub][4])

### Purpose

Filesystem and block-device identification.

Useful for:

* filesystem detection;
* UUID detection;
* filesystem labels;
* partition signatures;
* block-device probing.

### Integration

```text
DULinuxDeviceDiscovery
        │
        ▼
DUBlockDeviceProbe
        │
        ▼
libblkid
```

### License consequence

| Method           | Status      |
| ---------------- | ----------- |
| Link             | **YES**     |
| `dlopen()`       | **YES**     |
| Separate process | unnecessary |

LGPL requirements must be satisfied when distributing the library.

### Fit

**★★★★★ — recommended.**

---

## 6.2 libfdisk

**License:** LGPL-2.1-or-later.

### Purpose

Linux partition-table manipulation and inspection.

### Integration

```text
DULinuxPartitionBackend
        │
        ▼
libfdisk
```

### License consequence

| Method           | Status      |
| ---------------- | ----------- |
| Link             | **YES**     |
| `dlopen()`       | **YES**     |
| Separate process | unnecessary |

### Architectural rule

No `libfdisk` structures may escape into the public Disk Utility API.

### Fit

**★★★★★ — recommended Linux partition implementation.**

---

## 6.3 libmount

**License:** LGPL-2.1-or-later. Upstream libmount source files explicitly carry the LGPL-2.1-or-later license. ([GitHub][5])

### Purpose

Linux mount and mount-table handling.

### Integration

```text
DULinuxMountBackend
        │
        ▼
libmount
```

### License consequence

| Method           | Status      |
| ---------------- | ----------- |
| Link             | **YES**     |
| `dlopen()`       | **YES**     |
| Separate process | unnecessary |

### Fit

**★★★★☆ — recommended where useful.**

---

# 7. e2fsprogs

**Repository:** `https://github.com/tytso/e2fsprogs`

### Purpose

ext2/ext3/ext4 filesystem management.

The project contains both libraries and GPL-licensed utilities.

The `libext2fs` source identifies the library under the GNU Library GPL v2, while the project also contains GPL-licensed programs such as `e2fsck`, `mke2fs`, `resize2fs`, and others. ([GitHub][6])

---

## 7.1 libext2fs

**License:** GNU Library GPL v2 / LGPL-compatible library licensing.

### Integration

```text
DUExtFilesystemBackend
        │
        ▼
libext2fs
```

### License consequence

| Method           | Status                                      |
| ---------------- | ------------------------------------------- |
| Link             | **YES**, subject to LGPL/LGPLv2 obligations |
| `dlopen()`       | **YES**, subject to the same                |
| Separate process | optional                                    |

### Fit

**★★★★★ — recommended where direct ext filesystem access is needed.**

---

## 7.2 e2fsprogs utilities

Examples:

```text
e2fsck
mke2fs
mkfs.ext4
resize2fs
tune2fs
```

These should be treated as external programs rather than libraries.

```text
DUFilesystemBackend
        │
        ▼
DUProcessRunner
        │
        ▼
e2fsck / mkfs.ext4 / resize2fs
```

### License consequence

The GPL utility does not become part of the BSD application merely because Disk Utility invokes it as a separate process.

### Fit

**★★★★★ — recommended as external filesystem tools.**

---

# 8. dosfstools

**Repository:** `https://github.com/dosfstools/dosfstools`

**License:** GPL-3.0-or-later.

### Purpose

FAT12/FAT16/FAT32 filesystem creation and checking.

Important programs include:

```text
mkfs.fat
fsck.fat
fatlabel
```

### Integration

```text
DUFATFilesystemBackend
        │
        ▼
DUProcessRunner
        │
        ├── mkfs.fat
        ├── fsck.fat
        └── fatlabel
```

### License consequence

| Method                       | Status  |
| ---------------------------- | ------- |
| Link GPL code                | **NO**  |
| `dlopen()` GPL code          | **NO**  |
| Execute utilities separately | **YES** |

### Fit

**★★★★★ — recommended as external tools.**

---

# 9. exfatprogs

**Repository:** `https://github.com/exfatprogs/exfatprogs`

**License:** GPL-2.0-or-later.

### Purpose

exFAT filesystem management.

Useful programs include:

```text
mkfs.exfat
fsck.exfat
tune.exfat
dump.exfat
```

### Integration

```text
DUExFATFilesystemBackend
        │
        ▼
DUProcessRunner
        │
        └── exfatprogs utilities
```

### License consequence

| Method           | Status  |
| ---------------- | ------- |
| Link             | **NO**  |
| `dlopen()`       | **NO**  |
| Separate process | **YES** |

### Fit

**★★★★★ — recommended as external tools.**

---

# 10. Btrfs

**Status: EXCLUDED.**

The Gershwin Disk Utility **does not support Btrfs**.

Therefore none of the following are dependencies:

```text
btrfs-progs
libbtrfsutil
libbtrfs
btrfs utilities
```

There should be no Btrfs provider in the Disk Utility architecture.

The filesystem-provider model should therefore not contain:

```text
DUBtrfsFilesystemBackend
```

### Fit

**☆☆☆☆☆ — intentionally unsupported.**

---

# 11. OpenZFS

**Repository:** `https://github.com/openzfs/zfs`

**License:** CDDL-1.0.

### Purpose

ZFS storage pools, datasets, volumes, snapshots, RAID-like storage layouts, and filesystem management.

### Status

ZFS is considered a **platform storage technology**, not a library to embed into the BSD Disk Utility.

Where supported by the host OS, the Disk Utility should communicate with ZFS through native OS facilities and separate administrative utilities.

For example:

```text
DUZFSBackend
      │
      ├── zpool
      └── zfs
```

through `DUProcessRunner` or a platform-specific privileged helper.

### License consequence

The Disk Utility should not incorporate CDDL source into its BSD application merely because CDDL is permissive in some respects.

Keeping ZFS outside the application process gives a much cleaner licensing boundary.

### Fit

**★★★★☆ — useful platform integration, not an embedded library.**

---

# 12. libarchive

**Repository:** `https://github.com/libarchive/libarchive`

**License:** BSD-style permissive licensing, with individual files/components carrying their applicable notices.

### Purpose

Archive and filesystem-image handling.

Useful for:

* archive extraction;
* archive creation;
* ISO-related workflows;
* boot-media support;
* filesystem-like image contents.

### Integration

```text
DUArchiveBackend
DUOpticalMediaBackend
DUImageBackend
        │
        ▼
libarchive
```

### License consequence

| Method           | Status      |
| ---------------- | ----------- |
| Link             | **YES**     |
| `dlopen()`       | **YES**     |
| Separate process | unnecessary |

Required copyright/license notices must be retained.

### Fit

**★★★★★ — excellent direct dependency.**

---

# 13. libcdio

**Repository:** `https://github.com/libcdio/libcdio`

**License:** mixed LGPL/GPL licensing across the project/components.

### Purpose

Optical media access and CD/DVD handling.

Potential functionality includes:

* CD-ROM access;
* optical-media metadata;
* TOC handling;
* ISO9660;
* MMC/SCSI optical operations.

### Integration

Only individually audited LGPL/permissively licensed components may be linked.

GPL-only components must remain out of process.

```text
DUOpticalMediaBackend
        │
        └── approved libcdio component
```

### License consequence

Do **not** treat "libcdio" as having one blanket license.

The exact library/component being linked must be audited before inclusion.

### Fit

**★★★☆☆ — optional; audit before adoption.**

---

# 14. SquashFS Tools

**Repository:** `https://github.com/plougher/squashfs-tools`

**License:** GPL-2.0-or-later.

### Purpose

Creation and extraction of SquashFS filesystem images.

### Integration

```text
DUSquashFSBackend
        │
        ▼
DUProcessRunner
        │
        ├── mksquashfs
        └── unsquashfs
```

### License consequence

| Method           | Status  |
| ---------------- | ------- |
| Link             | **NO**  |
| `dlopen()`       | **NO**  |
| Separate process | **YES** |

### Fit

**★★★☆☆ — optional image/boot-media support.**

---

# 15. GPT fdisk

**Repository:** `https://github.com/rodsbooks/gdisk`

**License:** GPL-2.0-or-later.

### Purpose

GPT/MBR partition-table management and conversion.

Utilities include:

```text
gdisk
sgdisk
cgdisk
```

### Integration

These may be invoked through:

```text
DUProcessRunner
```

when native partition libraries do not provide the required operation.

### License consequence

| Method           | Status  |
| ---------------- | ------- |
| Link             | **NO**  |
| `dlopen()`       | **NO**  |
| Separate process | **YES** |

### Fit

**★★★☆☆ — fallback/reference partitioning tool.**

---

# 16. BSD Native Storage Facilities

The BSD platforms should preferentially use their own storage APIs rather than importing Linux storage infrastructure.

---

## 16.1 FreeBSD

Primary facilities:

```text
GEOM
devd
ioctl
gpart
glabel
geli
gmirror
gstripe
mount
umount
newfs
fsck
zpool
zfs
```

Architecture:

```text
DUFreeBSDStorageBackend
        │
        ├── DUGEOMBackend
        ├── DUFreeBSDDeviceMonitor
        ├── DUFreeBSDPartitionBackend
        ├── DUFreeBSDMountBackend
        └── DUProcessRunner
```

### Fit

**★★★★★ — native and preferred.**

---

## 16.2 OpenBSD

Primary facilities:

```text
disklabel
fdisk
ioctl
mount
umount
bioctl
```

Architecture:

```text
DUOpenBSDStorageBackend
        │
        ├── DUDisklabelBackend
        ├── DUOpenBSDDeviceDiscovery
        ├── DUOpenBSDMountBackend
        └── DUProcessRunner
```

### Fit

**★★★★★ — native and preferred.**

---

## 16.3 NetBSD

Primary facilities:

```text
disklabel
ioctl
mount
umount
native device interfaces
```

Architecture:

```text
DUNetBSDStorageBackend
        │
        ├── DUNetBSDPartitionBackend
        ├── DUNetBSDDeviceDiscovery
        ├── DUNetBSDMountBackend
        └── DUProcessRunner
```

### Fit

**★★★★★ — native and preferred.**

---

# 17. Image Architecture

The image subsystem should be:

```text
DUImageBackend
       │
       ├── DUQEMUImageBackend
       │       └── qemu-img
       │
       ├── DUISOImageBackend
       │       └── libarchive / native tools
       │
       └── DUSquashFSBackend
               └── mksquashfs / unsquashfs
```

QEMU's `qemu-img` is particularly suitable because it is explicitly intended to create, convert, and modify images offline. It also warns against modifying images while they are in use, which should be integrated into the Disk Utility's resource-locking model. ([GitHub][2])

---

# 18. Filesystem Architecture

The initial filesystem-provider set is intentionally limited.

```text
DUFilesystemBackend
        │
        ├── DUExtFilesystemBackend
        │      ├── libext2fs
        │      └── e2fsprogs utilities
        │
        ├── DUFATFilesystemBackend
        │      └── dosfstools
        │
        ├── DUExFATFilesystemBackend
        │      └── exfatprogs
        │
        ├── DUUFSFilesystemBackend
        │      └── BSD native tools/APIs
        │
        └── DUZFSBackend
               └── native ZFS facilities
```

**Btrfs is deliberately absent.**

---

# 19. Partition Architecture

The partition subsystem should avoid GPL libraries.

```text
DUPartitionBackend
        │
        ├── DULibFdiskPartitionBackend
        │       └── libfdisk
        │
        ├── DULinuxNativePartitionBackend
        │
        ├── DUFreeBSDPartitionBackend
        │       └── GEOM / gpart
        │
        ├── DUOpenBSDPartitionBackend
        │       └── disklabel / fdisk
        │
        └── DUNetBSDPartitionBackend
                └── disklabel / native APIs
```

`libparted` is intentionally **not** included.

GPT fdisk is available only as an optional external utility where necessary.

---

# 20. Device Discovery

Device discovery is platform-specific.

### Linux

```text
/sys
/dev
libblkid
libudev, where appropriate
ioctl
native Linux APIs
```

### FreeBSD

```text
/dev
devd
GEOM
ioctl
native APIs
```

### OpenBSD

```text
/dev
ioctl
disklabel
native APIs
```

### NetBSD

```text
/dev
ioctl
disklabel
native APIs
```

No UDisks layer exists between these facilities and the Disk Utility.

---

# 21. Device Monitoring

```text
DUDeviceMonitor
        │
        ├── DULinuxDeviceMonitor
        ├── DUFreeBSDDeviceMonitor
        ├── DUOpenBSDDeviceMonitor
        └── DUNetBSDDeviceMonitor
```

Possible event sources include:

```text
Linux → udev/sysfs
FreeBSD → devd/GEOM
OpenBSD → native device mechanisms
NetBSD → native device mechanisms
```

The application receives normalized Gershwin events:

```text
deviceAppeared
deviceDisappeared
deviceChanged
volumeMounted
volumeUnmounted
storageTopologyChanged
```

---

# 22. Process Execution

GPL utilities are integrated through:

```text
DUProcessRunner
```

rather than as libraries.

The process runner must provide:

```text
structured arguments
stdout
stderr
exit status
cancellation
progress
timeouts
environment control
```

The application must never construct shell commands.

Bad:

```text
"mkfs.ext4 " + devicePath
```

Good:

```text
["mkfs.ext4", devicePath]
```

The privileged helper must similarly expose typed operations rather than arbitrary command execution.

---

# 23. Privileged Helper

The application remains unprivileged.

```text
DiskUtility.app
       │
       │ authenticated IPC
       ▼
Privileged Storage Helper
       │
       ├── native APIs
       ├── approved libraries
       └── external utilities
```

Examples:

```text
EraseDevice
PartitionDevice
FormatVolume
MountVolume
UnmountVolume
ResizeFilesystem
CreateImage
ConvertImage
RestoreImage
CreateRAID
DestroyRAID
```

There must be no generic:

```text
execute(command)
runShell(command)
```

operation.

---

# 24. Resource Locking

The Disk Utility must lock storage resources before destructive operations.

Resources include:

```text
physical devices
partitions
logical volumes
RAID devices
storage pools
mounted filesystems
disk-image files
```

This is particularly important for image operations.

For example, `qemu-img` explicitly warns that modifying an image while it is being used by another process can destroy the image. ([GitHub][2])

Therefore:

```text
DUResourceLockManager
        │
        ├── device locks
        ├── partition locks
        ├── volume locks
        └── image-file locks
```

---

# 25. Direct-Link Dependency Summary

The preferred in-process dependencies are:

| Dependency            | License                   |       Direct link | Status                |
| --------------------- | ------------------------- | ----------------: | --------------------- |
| **libarchive**        | BSD-style                 |           **YES** | Recommended           |
| **libblkid**          | LGPL-2.1+                 |           **YES** | Recommended           |
| **libfdisk**          | LGPL-2.1+                 |           **YES** | Recommended           |
| **libmount**          | LGPL-2.1+                 |           **YES** | Recommended           |
| **libext2fs**         | LGPL / GNU Library GPL v2 |           **YES** | Recommended           |
| **libguestfs**        | LGPL library              | **NO — excluded** | Not used              |
| **libparted**         | GPL                       |            **NO** | Excluded              |
| **QEMU libraries**    | Mixed, QEMU overall GPL-2 |            **NO** | Use `qemu-img`        |
| **btrfs libraries**   | GPL/LGPL components       | **NO — excluded** | Not used              |
| **OpenZFS libraries** | CDDL                      |            **NO** | Native/out-of-process |
| **libcdio**           | Mixed                     |         **AUDIT** | Optional              |

---

# 26. Separate-Process Dependency Summary

The following may be used through `DUProcessRunner`:

| Utility / subsystem | License | Process execution |
| ------------------- | ------- | ----------------: |
| **qemu-img**        | GPL-2   |           **YES** |
| **e2fsck**          | GPL     |           **YES** |
| **mkfs.ext4**       | GPL     |           **YES** |
| **resize2fs**       | GPL     |           **YES** |
| **tune2fs**         | GPL     |           **YES** |
| **mkfs.fat**        | GPL-3   |           **YES** |
| **fsck.fat**        | GPL-3   |           **YES** |
| **mkfs.exfat**      | GPL-2   |           **YES** |
| **fsck.exfat**      | GPL-2   |           **YES** |
| **mksquashfs**      | GPL     |           **YES** |
| **unsquashfs**      | GPL     |           **YES** |
| **gdisk**           | GPL     |           **YES** |
| **sgdisk**          | GPL     |           **YES** |
| **gpart**           | BSD     |           **YES** |
| **glabel**          | BSD     |           **YES** |
| **geli**            | BSD     |           **YES** |
| **gmirror**         | BSD     |           **YES** |
| **zpool**           | CDDL    |           **YES** |
| **zfs**             | CDDL    |           **YES** |

---

# 27. Explicitly Excluded

The following are **not dependencies of the Disk Utility**:

```text
UDisks
UDisks2
storaged
libguestfs
btrfs
btrfs-progs
libbtrfsutil
libparted
```

The project does not introduce a desktop storage-management daemon between the application and the operating system.

The project also does not introduce Btrfs support.

---

# 28. Target Architecture

The resulting architecture is:

```text
                         GNUstep Disk Utility
                                  │
                                  ▼
                         Application Services
                                  │
                                  ▼
                           Storage Domain
                                  │
                         Storage Topology
                                  │
                                  ▼
                         Backend Interfaces
                                  │
          ┌───────────────────────┼────────────────────────┐
          │                       │                        │
          ▼                       ▼                        ▼
      Platform                 Images                Filesystems
      Backend                  Backend                 Backend
          │                       │                        │
    ┌─────┼─────┐                 │             ┌──────────┼─────────┐
    │     │     │                 │             │          │         │
  Linux FreeBSD BSDs             QEMU         ext4        FAT      exFAT
    │     │     │                 │             │          │
    │     │     │                 ▼             ▼          ▼
    │     │     │             qemu-img      e2fsprogs   dosfstools
    │     │     │
    ▼     ▼     ▼
 native native native
 APIs   APIs   APIs
    │
    ├── LGPL libraries where useful
    │
    └── native utilities through DUProcessRunner
```

The essential rule is:

```text
BSD Disk Utility
        │
        ├── BSD/permissive libraries → link
        ├── LGPL libraries           → link with LGPL compliance
        ├── GPL utilities            → separate process
        ├── CDDL utilities           → separate process/native OS boundary
        └── excluded technologies   → do not support
```

This keeps the **Disk Utility itself BSD licensed**, keeps the storage abstraction under Gershwin's control, avoids UDisks/storaged, avoids libguestfs and Btrfs, and prevents GPL libraries from being smuggled into the application simply by using `dlopen()`. The distinction between an LGPL library and its GPL companion programs is particularly important for projects such as libguestfs and e2fsprogs. ([GitHub][3])

[1]: https://github.com/qemu/qemu/blob/master/LICENSE?utm_source=chatgpt.com "qemu/LICENSE at master · qemu/qemu · GitHub"
[2]: https://github.com/qemu/qemu/blob/master/docs/tools/qemu-img.rst?utm_source=chatgpt.com "qemu/docs/tools/qemu-img.rst at master · qemu/qemu · GitHub"
[3]: https://github.com/libguestfs/libguestfs?utm_source=chatgpt.com "GitHub - libguestfs/libguestfs: library and tools for accessing and modifying virtual machine disk images. · GitHub"
[4]: https://github.com/util-linux/util-linux/blob/master/libblkid/src/blkid.h.in?utm_source=chatgpt.com "util-linux/libblkid/src/blkid.h.in at master · util-linux/util-linux · GitHub"
[5]: https://github.com/util-linux/util-linux/blob/master/libmount/src/utils.c?utm_source=chatgpt.com "util-linux/libmount/src/utils.c at master · util-linux/util-linux · GitHub"
[6]: https://github.com/tytso/e2fsprogs/blob/master/lib/ext2fs/inode.c?utm_source=chatgpt.com "e2fsprogs/lib/ext2fs/inode.c at master · tytso/e2fsprogs · GitHub"

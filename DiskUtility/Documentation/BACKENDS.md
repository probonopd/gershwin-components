# BACKENDS.md

How DiskUtility talks to the operating system's storage stack. See
ARCHITECTURE.md sections 17-24 for the abstraction and LIBRARIES.md for the
dependency/licensing analysis this document summarizes.

## 1. Backend Selection

`DUBackendFactory +backendWithError:` (Sources/Backend/DUBackendFactory.m)
picks one implementation of the `DUStorageBackend` protocol:

1. `DUForceMockBackend` user default set to YES (`--mock` command-line flag
   sets it in main.m) -> `DUMockStorageBackend`, error output untouched.
2. Compile-time platform match (`__linux__`, `__FreeBSD__`, `__OpenBSD__`,
   `__NetBSD__`) whose backend class is compiled in, resolved via
   `NSClassFromString` -> that platform backend.
3. Anything else (unknown OS, or known OS built without its backend) ->
   degraded mode: `DUMockStorageBackend.degradedBackend`. The app launches
   normally; discovery fails with a clear message
   (`DUErrorBackendUnavailable` from the factory,
   `DUErrorDiscoveryFailed` from the degraded backend) and every entry of
   the capability report reads "no". The UI never crashes; operations stay
   disabled.

The factory never returns nil.

## 2. Linux

Priority platform. Sources: Sources/Backend/Linux/ plus Parsers/.

### 2.1 Discovery

- Primary source: `lsblk -P -b -o NAME,PKNAME,PATH,TYPE,SIZE,FSTYPE,MOUNTPOINT,LABEL,PARTUUID,UUID,MODEL,RO,RM,HOTPLUG,MAJ:MIN`.
  Output is `KEY="value"` pairs, one line per device, parsed by
  `DULsblkParser` into row dictionaries.
- Fallback when lsblk is absent or unusable: direct `/sys/block` scan -
  sizes from `size` files in 512-byte sectors, flags from `ro`/`removable`,
  model from `device/model`, partitions enumerated as `<disk><n>` entries.
  Filesystem metadata is left unset rather than guessed.
- Enrichment: one plain `blkid` run, parsed by `DUBlkidParser`
  ("full" format `/dev/sda1: UUID="..." TYPE="vfat" ...`; unknown tokens are
  camelCased and kept). Supplies labels, UUIDs, partition types, and the
  whole-disk table type (`pttype`) which is normalized to GPT/MBR by
  `DUPartitionTableParser`. A missing or failing blkid never fails
  discovery.
- Mount state comes from lsblk's MOUNTPOINT column; usage numbers come from
  `statvfs()` on the mount point while mounted.
- Optical drives are `rom`-type rows; eject capability requires `eject`.

### 2.2 Tools probed at runtime

Resolved through `+executablePathForName:` and cached per name
(`DULinuxToolCache`). Absent tools disable features, never crash:

| Tool | Purpose | Disabled when missing |
| --- | --- | --- |
| `lsblk` | device inventory | falls back to /sys scan |
| `blkid` | fs/label/uuid/table enrichment | scheme stays unknown |
| `parted` | partitioning (preferred) | uses sfdisk instead |
| `sfdisk` | partitioning fallback | partitioning off if parted also absent |
| `partprobe` | kernel table reread after writing | skipped, non-fatal |
| `mkfs.ext4`, `mkfs.vfat` | any erase at all | whole-disk/partition Erase off |
| `mkfs.<fstype>` | format to that filesystem | that type not offered |
| `fsck.<fstype>`, `e2fsck` | verify/repair | Verify/Repair off for that volume |
| `wipefs` | signature wipe before erase | degrades to plain mkfs |
| `dd` | zero-fill secure erase, restore | secure erase/restore off |
| `tune2fs` | ext journal toggle | journaling menu off |
| `mdadm` | RAID set creation | RAID management "no" |
| `mount`, `umount` | mount management (elevated) | unprivileged udisksctl path used if present (slated for removal, TODO.md) |
| `eject` | tray/media ejection | Eject off |
| `qemu-img` | image inspect/convert/resize | raw/gz imaging still works |
| `gzip` | .img.gz streams | gz format off |
| `cat` | privileged read of root-only block nodes | checksum/imaging needs privileges |
| `xorriso`, `growisofs`, `wodim`, `cdrecord` | optical burning (first present wins) | Burn off for optical drives |

Image conversion (`qemu-img convert`) and resizing (`qemu-img resize`)
are offered on registered disk images whenever qemu-img exists; burning
runs the probed cdrecord-family tool against the drive node through the
privileged pipeline (LIBRARIES.md sections 3 and 1.3).

### 2.3 Partitioning

`DULinuxPartitionTool.applyPlan:toDevicePath:`:

- Preferred: `parted -s <dev> mklabel <gpt|msdos>` then one
  `parted -s <dev> mkpart ...` per entry via argument vectors. msdos plans
  get `primary` slots and an explicit `set N boot on` for bootable entries;
  first partition starts at 1 MiB.
- Fallback (no parted): sfdisk wants a stdin script, which DUProcessRunner
  never provides, so the rendered script travels through a temporary file
  passed as trailing operand (`sfdisk --no-reread --force <dev> <file>`).
- Afterwards `partprobe <dev>` runs elevated; failure is non-fatal.
- All writers run elevated through `DUAuthorizationManager`.

### 2.4 Format / check / resize per filesystem

`DULinuxFilesystemTool` tables:

| fstype | format tool (flags) | checker (aliases) | resize tool |
| --- | --- | --- | --- |
| ext2/ext3/ext4 | `mkfs.extN -F` (-L label) | `fsck.extN`, alias `e2fsck` | `resize2fs` |
| vfat | `mkfs.vfat -I` (-n label) | `fsck.vfat` / `fsck.fat` | - |
| exfat | `mkfs.exfat` (-n label) | `fsck.exfat` | - |
| ntfs | `mkfs.ntfs -Q` (--label) | `fsck.ntfs` | `ntfsresize` |
| xfs | `mkfs.xfs -f` (-L) | `fsck.xfs` | `xfs_growfs` |
| btrfs | `mkfs.btrfs -f` (removal pending, TODO.md) | `fsck.btrfs` | `btrfs` |
| f2fs | `mkfs.f2fs` (-l) | `fsck.f2fs` | `resize.f2fs` |
| swap | `mkswap` (-L) | none | - |

- The `-F/-I/-Q/-f` flags keep mkfs non-interactive: no stdin exists, so an
  "are you sure?" prompt would read EOF and abort.
- Verify runs the checker with `-n` and accepts exit status 0 only (even
  auto-corrections mean damage). Repair runs `-y` and accepts 0 or 1.
- Progress parsing maps e2fsck "Pass N:" lines and mke2fs stage messages
  onto a monotonic fraction; dd progress lines yield byte counts.

### 2.5 Erase, images, RAID

- Erase = optional `wipefs -a` (non-fatal when absent), optional zero-fill
  via streamed `dd if=/dev/zero of=<node> bs=1M status=progress`, then
  `mkfs`.
- Image creation: in-process chunked copy with SHA-256 over the exact
  stream plus read-back verification. Raw and gzip need nothing but gzip;
  qcow2/vhd/vdi are produced by a `qemu-img convert` post-pass and offered
  only when qemu-img exists. Root-only block nodes are re-read through a
  privileged `cat` pipeline. Format probing prefers `qemu-img info
  --output=json`, falling back to an extension map.
- Restore writes images back to devices with dd-based streaming.
- RAID: `mdadm --create /dev/md/<name> --level <0|1|linear> ...`.

### 2.6 Optional direct-link libraries

When their headers are present at build time, five LGPL/BSD libraries link
directly (LIBRARIES.md sections 6.1, 6.2, 6.3, 7.1, 12): libblkid probes
filesystem/label/uuid per node in-process, preferring its results over the
`blkid` command snapshot; libmount supplies the mount-point table ahead of
lsblk's MOUNTPOINT column; libext2fs reads capacity/free bytes from the
superblock of unmounted ext2/3/4 volumes; libarchive identifies image
content (iso9660/tar/zip/cpio/7zip) between qemu-img probing and the file-
extension map; libfdisk inspects whole-disk partition tables read-only,
refining scheme plus per-partition offset/size/type/name ahead of the
lsblk/blkid fields. Every integration is additive: with a library absent the
wrappers compile to explicit stubs (`+isAvailable` -> NO) and discovery,
mount state, volume statistics and image identification degrade to the
existing command-line/magic-byte paths unchanged. The Linux capability
report exposes each as a "libblkid probing"/"libmount mounts"/"libext2fs
stats"/"libarchive identify" yes/no diagnostic.

## 3. FreeBSD

Priority platform. Sources: Sources/Backend/FreeBSD/ plus Parsers/.

### 3.1 Discovery

Everything derives from geom(8) text output, run through
`DUFreeBSDGEOMAdapter` and parsed by `DUFreeBSDGEOMParser`:

- `geom disk list` - one block per disk; builds `DUStorageDevice` roots.
  Skips `cd*` (handled by the cd pass), eMMC boot windows
  (`mmcsd*boot0/boot1`), and zero-size placeholder providers.
- `geom part list <disk>` - one provider block per partition; supplies
  index, offset, length, type (`freebsd-ufs`, `!165` MBR ids, ...), labels,
  and the enclosing Geom header's `scheme` (normalized to GPT/MBR).
- `geom cd list` - optical drives; falls back to probing `/dev/cd0` in
  restricted environments.
- Parser input shape: optional `Geom name:` header with attribute lines
  (`state: OK`, `scheme: GPT`), then numbered `providers:` blocks
  (`1. Name: ada0p1`, `Mediasize: 536870912 (512M)`); `consumers:` ignored.
  Header attributes are inherited into each provider dictionary; sizes take
  the leading integer of "<bytes> (<human>)".
- Live mount state: one `mount(8)` snapshot per discovery pass, parsed from
  `device on mountpoint (fstype, options)` lines; usage via `statvfs()`.
- Connection classification from node names: `da` -> USB/removable,
  `ada` -> SATA internal, `nvme`/`nvd` -> NVMe, `mmcsd` -> SD.

### 3.2 Tools probed at runtime

Cached in `DUFreeBSDToolCache`; the capability report mirrors installed
tools so diagnostics show honest answers:

| Tool | Purpose | Disabled when missing |
| --- | --- | --- |
| `geom` | all discovery | discovery fails (backend reports "no") |
| `gpart` | create/add/destroy partition tables | Partitioning off; whole-disk erase off |
| `newfs` | UFS format | UFS format off |
| `newfs_msdos` | FAT format | FAT format off |
| `fsck_ffs` | UFS verify/repair | UFS First Aid off |
| `fsck_msdosfs` | FAT verify/repair | FAT First Aid off |
| `dd` | secure erase zeros, restore, image creation | those ops off |
| `mount`, `umount` | mount management (elevated) | mount/unmount off |
| `cdcontrol` / `camcontrol` | tray eject | Eject off |
| `gmirror`, `gstripe`, `gconcat`, `glabel` | RAID sets | RAID management "no" |
| `gzip` | .img.gz image format | gz format not offered |
| `qemu-img` | qcow2/vhd/vdi image formats | not offered |

Convert and resize run through `qemu-img` on registered images; burning is
offered when a cdrecord-family tool (xorriso, growisofs, wodim, cdrecord)
is installed and runs against the drive node with privilege escalation.

### 3.3 Operations

- Partitioning: `gpart create -s gpt|<scheme> <node>`, then
  `gpart add -t <type> [-s sectors] [-i index] [-l label] <node>` per plan
  entry; sector geometry comes from a fresh `geom part list`, not the
  discovery snapshot. Erase removes tables with `gpart destroy -F`,
  tolerating "no such geom" on blank disks.
- Format/check: UFS via `newfs [-L label]` / `fsck_ffs` (verify `-n -f`),
  msdosfs via `newfs_msdos [-L label]` / `fsck_msdosfs` (verify `-n`);
  repair passes the fix-it flag. Labels truncated to 15 (UFS MAXLABELLEN)
  and 11 (FAT) characters before invocation.
- Erase: optional `dd if=/dev/zero of=<node> bs=1M status=progress`
  (progress from "<N> bytes transferred" lines), `gpart destroy -F`, then
  the filesystem formatter.
- Mount: `mount -t <mapped fstype> <node> <dir>` where ext2/3/4 map to
  `ext2fs`, iso9660 to `cd9660`, fat variants to `msdosfs`; `umount <target>`;
  eject prefers `cdcontrol -f <node> eject` over `camcontrol eject`.
- RAID: level maps to tool (`mirror`->`gmirror`, `stripe`->`gstripe`,
  `concat`->`gconcat`), invoked as `tool label -h <name> <members...>`.
- Images: same raw/gz/qemu ladder as Linux; restore via `dd`.

All table-writing, formatting, mounting, and eject operations run elevated
through `DUAuthorizationManager`; `geom` and `mount` snapshots run
unprivileged.

## 4. NetBSD (provisional)

Less tested; treat behavior as provisional. Sources:
Sources/Backend/NetBSD/.

- Discovery: `disklabel <disk>` per disk, parsed by `DUNetBKSDisklabelParser`
  (shared grammar engine with OpenBSD: `bytes/sector:`, `sectors/unit:`
  geometry, then `[letter]: size offset fstype [fsize bsize cpg] # mount`
  rows after a "<N> partitions:" marker; sector counts converted to bytes).
  Mount state from a `mount -p` snapshot (fstab-style columns).
- Operations: partitioning applies a disklabel template via
  `disklabel -R <rawdisk> <template>` (reported "partial"); formatting with
  `newfs`/`newfs_msdos`; checking with `fsck_ffs`/`fsck_msdos`;
  `mount`/`umount` elevated; `eject`; zero-fill/restore via `dd`.
- Capability report: RAID, image mounting/conversion always "no".

## 5. OpenBSD (provisional)

Less tested; treat behavior as provisional. Sources:
Sources/Backend/OpenBSD/.

Same shape as NetBSD: `disklabel <disk>` discovery via
`DUOpenBSDDisklabelParser`, `mount -p` mount snapshot, `disklabel -R`
partitioning (partial), `newfs`/`newfs_msdos` formatting,
`fsck_ffs`/`fsck_msdos` checking, elevated `mount`/`umount`, `eject`, and
dd-based erase/restore. LIBRARIES.md also names `bioctl` as a native
facility for future RAID work; no code paths use it yet.

## 6. Licensing Policy Summary

Authoritative reference: LIBRARIES.md sections 1 and 25-27. Short form:

- BSD/MIT-style libraries may be linked directly.
- LGPL libraries (libblkid, libfdisk, libmount, libext2fs) may be linked
  subject to LGPL compliance; dynamic linking preferred.
- GPL and CDDL programs must NOT enter the process by link or `dlopen()`;
  they may run only as separate processes through `DUProcessRunner`
  (qemu-img, e2fsprogs tools, dosfstools, exfatprogs, squashfs tools,
  gdisk/sgdisk, zpool/zfs).
- Explicitly excluded technologies: UDisks/UDisks2/storaged, storaged-type
  desktop storage daemons generally, libguestfs, btrfs/btrfs-progs/
  libbtrfsutil, and linking against libparted. Remaining udisksctl call
  sites are tracked for removal in TODO.md.

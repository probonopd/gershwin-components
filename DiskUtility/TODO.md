# DiskUtility TODO

State: Waves 1-6 of PLAN.md done (build clean, 223 test assertions green,
`--list --mock` works). Priority order per user: **Linux + FreeBSD first,
NetBSD/OpenBSD last**.

## P1 - Linux + FreeBSD

- [x] LIBRARIES.md conformance, Linux backend:
      - btrfs removed from DULinuxFilesystemTool.m (types/format/label/
        fsck/resize tables) and DULinuxPartitionTool.m (parted tokens).
      - udisksctl branches removed from mount/unmount in
        DULinuxStorageBackend.m; always mount(8)/umount(8) via
        DUAuthorizationManager.
      - Audit clean: no libguestfs/storaged/libparted/dlopen anywhere.
- [x] FreeBSD backend hardening (6 bugs fixed):
      - whole-disk guard false-negative let destructive ops run under
        mounted filesystems (DUFreeBSDStorageBackend.m mountedNodeAmong:)
      - gpart type tokens invalid for MBR/GPT combos; now scheme-aware,
        fails before table creation
      - volume.backendPath never set (mount/verify on volumes broken)
      - image creation gated on sha256 tool presence, not just dd
      - device erase capability now also requires gpart
      - ada0s1a BSD-label partitions nested under their slice
      - new fixtures: geom-part-list-ada0s1.txt, geom-disk-list-mmcsd.txt,
        geom-cd-list-empty.txt (need `git add -f`, .gitignore ignores *.txt)
- [x] Localization: Resources/English.lproj/Localizable.strings generated
      mechanically (319 keys = all NSLocalizedString uses), validated via
      NSDictionary parse; wired into GNUmakefile RESOURCE_FILES; confirmed
      inside DiskUtility.app/Resources.

## P2 - Cross-cutting

- [x] Full `gmake clean && gmake`: zero errors, zero warnings.
- [x] `sh Tests/run.sh`: 223 assertions green.
- [x] `--list --mock` prints hierarchy.
- [x] `COPYING` (BSD-2-Clause) + Documentation/{BACKENDS,SECURITY,
      DEVELOPMENT}.md written; Linux/FreeBSD in depth, NetBSD/OpenBSD
      marked provisional.

## P3 - NetBSD/OpenBSD

- [x] NetBSD hardening: dd progress parser inverted guard fixed; whole-disk
      busy-guard now matches wd0/wd0a shapes (was blind to digit-ending
      names); invalid `status=progress` operand removed (NetBSD dd aborts
      on unknown operands); argv/tool-probe audit clean; new fixtures:
      dmesg-boot.txt, disklabel-sd0-usb.txt, mount-p.txt.
- [x] OpenBSD hardening: hw.disknames comma+DUID line misparse fixed;
      same dd progress + status=progress fixes; whole-disk busy-guard
      sd0/sd0a shape fix; eject now uses raw node (/dev/rcd0c); parser
      verified against disklabel-sd0.txt; new fixtures: hw-disknames.txt,
      dmesg-disks.txt, mount-p.txt, disklabel-wd0.txt.
- [x] FreeBSD dd progress parser (same latent bug as NetBSD) fixed.
- [x] Conformance audit all four backends: no btrfs/udisks/storaged/
      libguestfs/libparted/dlopen anywhere.
- [x] Full clean rebuild zero warnings; 223 tests green; mock smoke OK.

Open policy notes (no action taken):
- FreeBSD dd keeps status=progress (supported since FreeBSD 13, fails
  visibly on older worlds) - deliberate, commented in code.
- Whole-disk erase formats the raw c/d node directly (OpenBSD rsd0c,
  NetBSD rwd0d) - platform convention, consistent per backend.
- Pre-mount /media mkdir fails hard for askpass-only users; works for
  root sessions. Left as fail-hard per project rules.

## P5 - LIBRARIES.md integration (link the approved libraries)

Approved direct links (LIBRARIES.md section 25): libarchive, libblkid,
libfdisk, libmount, libext2fs. Present on this host: blkid, mount,
ext2fs, archive (libfdisk dev headers absent -> stays dormant until a
host provides them).

- [x] Sources/Backend/Libraries/: Foundation-only wrappers
      DUBlkidLibrary (fs/uuid/label probing), DUMountLibrary (mount
      table via libmount), DUExt2Library (read-only ext2/3/4 superblock
      stats for unmounted volumes), DUArchiveLibrary (ISO/archive
      identification). Each behind a HAVE_LIB* compile guard; absent lib
      compiles to explicit "unavailable", surfaced in capability report
      (ARCHITECTURE.md 60/65, never a silent guess).
- [x] Integrate: Linux discovery prefers libblkid probe (existing parser
      path stays as fallback when wrapper unavailable/unsuccessful);
      mount listing via libmount; unmounted ext volumes get real
      used/total stats; ISO images identified via libarchive;
      capabilitiesReport gained four library diagnostic keys (Linux).
- [x] Tests/TestLibraries (t_Libraries, 18 assertions): probes against
      scratch FILE images created by the test itself - no real devices,
      no destructive ops anywhere.
- [x] GNUmakefile + Tests/GNUmakefile conditional linking (fixed a make
      ordering bug where the later plain LDFLAGS assignment wiped the
      conditional additions); BACKENDS.md section 2.6 documents it.
- [x] libfdisk installed (libfdisk-dev) and integrated as the fifth
      library: DUFdiskLibrary read-only inspection (scheme + per-partition
      start/size/type/uuid/name) refines Linux discovery when present;
      parted/sfdisk stay authoritative for writes this round - switching
      apply over to libfdisk needs on-device validation first.
- [x] Verified: ldd shows all five libraries linked (blkid, mount,
      ext2fs, archive, fdisk); 246 assertions green; clean build zero
      warnings; reinstalled to SYSTEM; GUI shows real disk, zero
      self-started operations.

## P4 - Wave 7 delivery

- [x] `.DISABLED` marker: user decided - keep component out of top-level
      build dispatch for now.
- [x] Installed: `sudo gmake install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM`
      -> /System/Applications/Utilities/DiskUtility.app; /Local verified
      clean; English.lproj present in bundle.
- [x] GUI smoke test via driveui (real backend): window layout correct,
      real nvme discovery, capability-gated toolbar, five tabs, live
      operation log, info panel fields populated.
- [x] Bug found + fixed during smoke test: `--mock` was written to the
      persistent user defaults, silently forcing the mock backend on every
      later launch. Now per-process argument parsing only
      (DUBackendFactory backendForArguments:error:, test updated, stale
      default scrubbed from user prefs).
- [ ] Open, not reproducible: two early instances vanished silently
      between tool calls (no crash trace, no signal evidence); watchdog +
      repeated-drive_ui reproductions (6+) all stable. Suspected external
      session-supervisor activity on this desktop, not an app bug.
      Revisit if it recurs on a quiet system. Recurred once more during
      the Partition-tab session (one idle instance, no trace); every
      other instance survived minutes of heavy drive_ui interaction.

## P6 - Partition tab made functional (GUI wiring + fixes)

The pane code existed but was never fed: DUOperationController only held
the pane's raw NSView, so no selection/refresh/busy state ever reached it
and the tab stayed empty. Fixed end to end, verified via driveui against
--mock (no destructive ops, Apply never clicked):

- [x] DUOperationController now owns DUPartitionViewController like the
      other panes; refreshForObject: and setControlsEnabled: fan out to
      it. Removed the setPartitionPane:/setRAIDPane: view-injection API
      and the manual creation in DUMainWindowController.
- [x] Child selection resolves to the parent device: selecting a volume
      or partition row shows the owning disk's map in the Partition tab
      (reference-UI behavior); RAID sets keep the placeholder.
- [x] Pane no longer wipes in-progress edits when rescans re-select the
      same disk; it adopts the fresh device object instead.
- [x] Implemented the missing formatChanged: action (popup previously
      targeted an unimplemented selector = runtime crash); format choice
      records a pending change like rename/resize.
- [x] Map layout: applyFramesForWidth:height: never set _mapView.frame
      (only its mask), so the map floated at 100x100 over the buttons.
      Now fills the middle band; form rows centered against it; pane
      switched to DUPaneView relayout like the other tabs.
- [x] Info form live on arrival: syncAllViews mirrors the map's implicit
      first-tile selection (setLayout: does not notify the delegate).
- [x] Drag-resize fixed (DUDiskMapView mouseDragged): the old math
      re-subtracted the tile origin from an already tile-relative value
      (every drag on partition >= 2 collapsed to the 1 MiB floor,
      silently shrinking partitions) and clamped size against the
      absolute end offset. Now pointer-to-byte conversion with size-space
      clamps; verified 19 GB -> 20 GB growth into the tail.
- [x] New partitions default to "Partition n" (count + 1, bumped past
      names in use) instead of the layout's raw UUID; Name field stays
      editable. Default format comes from the popup's current selection,
      matched to the added partition by identifier diff.
- [x] Scheme popup capped at 16 offered counts (was: every feasible
      count up to the scheme limit, e.g. 128 GPT entries); higher counts
      remain reachable via "+".
- [x] Verified via driveui: device select populates map+form; tile click
      switches selection; +/- work; format change; scheme shrink with
      hatched free space; Options dialog open/cancel; revert restores
      baseline and disarms Apply; resize arms Apply. 246 test assertions
      green, clean build, zero warnings.

## P7 - Tab-switch overlap fixes (headless uitest session)

All driven from the isolated uitest session (Xvfb :99, user uitest) per
the gershwin-wm-headless-testing skill - the user's desktop :0 is never a
test target. Reproduced "overlapping items when switching tabs" and fixed
four independent causes:

- [x] Real layout overlap: at small pane heights the 3-row volume form
      (88px) exceeded the map band (65px at the 800x600 headless geometry;
      reachable on real desktops near the 650x450 minimum window too) and
      its top row rode up into the Volume Scheme popup - two controls in
      one spot. Row gaps now compress (12px -> 2px floor) so the form
      always fits under the scheme row.
- [x] Stale-pixel ghosts: the window's plain NSView content view draws no
      background, so any region whose view was hidden or removed kept old
      pixels forever (frozen operation strip after hide, doubled footer
      values). Window now uses an opaque DUContentView.
- [x] Footer values double-struck after operations: the info area view
      never participates in partial redraws (its drawRect provably never
      runs) and the value fields were transparent, so every partial
      repaint during an operation stacked glyphs onto stale pixels. Info
      fields now draw an opaque controlBackgroundColor.
- [x] Damage scheduled from timer callbacks (strip hide) is only flushed
      with the next X11 event, which may never come; tab swaps left 1px
      -stale text in unrelated panes. Tab selection (NSTabViewDelegate)
      and strip hide now redraw the window synchronously.
- [x] Threading hardening found on the way: DUStorageManager posted the
      topology notification on the calling thread (device monitor and
      operation workers) while the only observer drives AppKit - now
      marshaled to the main thread; verify/mount/unmount/eject completion
      blocks (backend worker threads) marshal their alerts and refresh
      kicks to the main thread too; NSNull passed through
      performSelectorOnMainThread crashed the completion and froze the
      strip (nil passes through unchanged).
- [x] Headless verification: tab cycles before/during/after a mock verify
      - panes, operation strip, info footer all render clean; strip folds
      away without ghosts; 246 assertions green; zero warnings.

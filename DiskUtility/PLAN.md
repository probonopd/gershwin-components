# DiskUtility Implementation Plan

Implementation of `DiskUtility.app` per SPEC.md and ARCHITECTURE.md.
Work is organized in waves; agents within a wave run in parallel on **disjoint
file sets**. Boxes are checked off as waves complete.

## Ground rules (apply to every file)

- Objective-C, ARC (`-fobjc-arc -fobjc-runtime=gnustep-2.0`), GNUstep Make,
  `-Wall -Wextra -O2`, zero warnings.
- New-file header:
  ```objc
  /*
   * Copyright (c) 2026 Simon Peter
   *
   * SPDX-License-Identifier: BSD-2-Clause
   */
  ```
- No dispatch/GCD. Use NSThread/NSTimer/performSelector:onThread:.
- No em-dash anywhere. Comments explain WHY, not WHAT.
- Models/Services/Backend/Operations import Foundation only (no AppKit).
- Platform code guarded by `#if defined(__linux__) / __FreeBSD__ /
  __OpenBSD__ / __NetBSD__` so the whole tree parses on every OS.
- UI metrics come from vendored `AppearanceMetrics.h` (copy from
  ../Sound/AppearanceMetrics.h). No hardcoded layout values elsewhere.
- All user-visible strings via NSLocalizedString; device/volume names never localized.
- Never shell-interpolate user input; args passed as arrays via DUProcessRunner.
- Fail hard on unexpected failures; no silent fallback paths.

## Canonical interface pins (all agents code against these)

Backend protocol (Sources/Backend/DUStorageBackend.h):

```objc
@class DUStorageObject;
@protocol DUStorageBackend <NSObject>
- (NSArray *)discoverStorageObjects:(NSError **)error;
- (NSDictionary *)capabilitiesReport;
- (BOOL)supportsOperation:(NSString *)op forObject:(DUStorageObject *)object;
- (void)verifyObject:(DUStorageObject *)object
            progress:(void (^)(double progress, NSString *message))progress
          completion:(void (^)(NSError *error))completion;
- (void)repairObject:(DUStorageObject *)object
            progress:(void (^)(double progress, NSString *message))progress
          completion:(void (^)(NSError *error))completion;
- (void)eraseObject:(DUStorageObject *)object
            options:(NSDictionary *)options
           progress:(void (^)(double progress, NSString *message))progress
         completion:(void (^)(NSError *error))completion;
- (void)partitionDevice:(DUStorageObject *)device
                withPlan:(DUPartitionPlan *)plan
               progress:(void (^)(double progress, NSString *message))progress
             completion:(void (^)(NSError *error))completion;
- (void)mountObject:(DUStorageObject *)object
          completion:(void (^)(NSError *error, NSString *mountPoint))completion;
- (void)unmountObject:(DUStorageObject *)object
            completion:(void (^)(NSError *error))completion;
- (void)ejectObject:(DUStorageObject *)object
          completion:(void (^)(NSError *error))completion;
- (void)restoreFromSource:(DUStorageObject *)source
              destination:(DUStorageObject *)destination
                  options:(NSDictionary *)options
                 progress:(void (^)(double progress, NSString *message))progress
               completion:(void (^)(NSError *error))completion;
@end
```

Error domain: `DUStorageErrorDomain`; codes per ARCHITECTURE.md section 45.

Notifications (defined in DUNotifications.h under Services/):
`DUStorageTopologyDidChangeNotification`,
`DUStorageSelectionDidChangeNotification`, `DUOperationDidStartNotification`,
`DUOperationDidUpdateNotification`, `DUOperationDidFinishNotification`,
`DUOperationDidFailNotification`. UserInfo carries the related object(s).

Model property lists follow ARCHITECTURE.md sections 9-16 verbatim
(identifier, displayName, parent, children, capabilities, backendPath ...).

Selection-driven update contract (SPEC section 30): selection change updates
toolbar availability, tab availability, operation context, info panel, title -
implemented once in DUMainWindowController, children receive
`-refreshForObject:` calls.

---

## Wave 1 - Foundations (4 agents in parallel)

- [x] **1A. Scaffolding**
      Files: `GNUmakefile` (complete final OBJC file list below),
      `Resources/DiskUtilityInfo.plist`, `Resources/DiskUtility.png` +
      `Resources/Icons/*.svg|png` (toolbar: verify, info, burn, mount, eject,
      journal, newimage, convert, resize; devices: disk, volume, optical,
      media, image; drawn as tiny monochrome SVG converted via ImageMagick,
      Menu-style), `README.md`, vendored `AppearanceMetrics.h`.
      GNUmakefile modeled on ../Processes/GNUmakefile: APP_NAME=DiskUtility,
      SYSTEM domain, apps installed under Utilities/, global
      ADDITIONAL_OBJCFLAGS `-Wall -Wextra -O2 -fobjc-runtime=gnustep-2.0 -fobjc-arc`.
- [x] **1B. Models**
      Files: `Sources/Models/{DUStorageObject,DUStorageDevice,DUPartition,
      DUStorageVolume,DUOpticalMedia,DUDiskImage,DURAIDSet,
      DUStorageCapabilities,DUPartitionLayout,DUPartitionPlan}.{h,m}`.
      DUPartitionLayout = pending-layout editing model (add/remove/resize,
      overlap + fit validation, pure logic, fully unit-testable).
      DUPartitionPlan = immutable op description per ARCHITECTURE.md section 87.
- [x] **1C. Utilities**
      Files: `Sources/Utilities/{DUErrors,DUProcessRunner,DUParsing}.{h,m}`.
      DUProcessRunner: NSTask wrapper, arg arrays, stdout/stderr capture,
      streaming callback, cancellation (SIGTERM + wait), timeout, no shell.
      DUErrors: domain + code helpers.
      DUParsing: shared helpers (size strings to bytes, tokenizing).
- [x] **1D. Parsers + fixtures**
      Files: `Sources/Backend/Parsers/{DULsblkParser,DUBlkidParser,
      DUFreeBSDGEOMParser,DUOpenBSDDisklabelParser,DUNetBKSDisklabelParser,
      DUPartitionTableParser}.{h,m}`,
      `Tests/Fixtures/{Linux,FreeBSD,OpenBSD,NetBSD}/` sample outputs.
      Input NSString/JSON in, NSArray/NSDictionary out. Locale-independent.

Verification: each agent compiles own files standalone:
`clang -c -fobjc-arc -fobjc-runtime=gnustep-2.0 -Wall -Wextra -O2
-I/System/Library/Headers -ISources -ISources/Models <file>.m -o /tmp/opencode/x.o`

## Wave 2 - Contracts + services + first tests (3 agents in parallel)

- [x] **2A. Backend contract**
      Files: `Sources/Backend/DUStorageBackend.{h,m}`,
      `DUBackendCapabilities.h`, `DUBackendFactory.{h,m}`,
      `Sources/Backend/DUMockStorageBackend.{h,m}`.
      Factory picks backend by uname; unsupported OS returns backend whose
      discovery reports BackendUnavailable (app stays launchable).
      Mock generates the artificial hierarchy of ARCHITECTURE.md section 56.
- [x] **2B. Services + operations**
      Files: `Sources/Services/{DUStorageManager,DUOperationManager,
      DUDeviceMonitor,DUAuthorizationManager,DUImageService,DUNotifications}.{h,m}`,
      `Sources/Operations/DUOperation.{h,m}` + Verify/Repair/Erase/Partition/
      Restore/RAID/Image concrete ops.
      Manager: owns snapshot, diff/reconcile (section 37), identifier resolve,
      per-device locks (section 33), notification publishing.
      OperationManager: state machine Pending->Preparing->Running->
      Completed/Failed/Cancelled, conflicting-op rejection, history.
      AuthorizationManager: run directly if euid==0, else `sudo -A`
      (GUI askpass via $SUDO_ASKPASS; a GUI owns no terminal for a prompt),
      else PermissionDenied error (no interactive prompts).
      DeviceMonitor: NSTimer poll (default 10 s, pref DURefreshInterval).
- [x] **2C. Unit tests for Wave 1** (189 assertions green)
      Follow `/Local/Users/admin/.claude/skills/gnustep-red-green-tdd/SKILL.md`
      (PASS macro set). `Tests/GNUmakefile`, test tools: TestModels,
      TestParsing (fixtures), TestPartitionLayout. Red-green where practical.

## Wave 3 - Backends + operation tabs (6 agents in parallel)

- [x] **3A. Linux backend**: discovery via lsblk --json/--pairs + sysfs,
      blkid probing, mount/umount, eject, fsck verify/repair, mkfs erase,
      parted/sfdisk partition apply from DUPartitionPlan, mdadm RAID,
      wipefs security options, tune2fs journal toggle, dd restore,
      qemu-img image convert/resize/truncate-create. Capability-probe every
      external tool at runtime; missing tool => capability off.
      Files: `Sources/Backend/Linux/*`.
- [x] **3B. FreeBSD backend**: geom part list/diskid discovery, gpart
      partitioning, fstab/mount, fsck.ffs verify/repair, newfs erase,
      gmirror/gstripe RAID, mdconfig images. `Sources/Backend/FreeBSD/*`.
- [x] **3C. OpenBSD backend**: dmesg/disklabel discovery, disklabel -E
      partitioning, mount/umount, fsck, newfs, vnconfig images.
      `Sources/Backend/OpenBSD/*`.
- [x] **3D. NetBSD backend**: dmesg/sysctl discovery, fdisk/disklabel,
      mount, fsck, newfs, vnd images. `Sources/Backend/NetBSD/*`.
      (3B-3D compile-guarded; must parse on Linux CI.)
- [x] **3E. Operation tabs A**: `Sources/Views/DUOperationLogView.{h,m}`,
      `Sources/Controllers/DUOperationController.{h,m}` (tab container),
      `DUFirstAidViewController`, `DUEraseViewController`,
      `DURestoreViewController` (.h/.m each). Layouts per SPEC sections
      9-13, 14, 21; confirmations per section 32; log auto-scroll.
- [x] **3F. Operation tabs B** (RAID pane deferred by user decision; tab shows unavailable placeholder): `Sources/Views/DUDiskMapView.{h,m}`
      (custom-drawn proportional map, click-select, drag-resize boundaries),
      `Sources/Controllers/DUPartitionViewController.{h,m}` (scheme popup,
      +/- controls, volume info form, Options dialog, Apply/Revert with
      pending-layout dirty state), `DURAIDViewController.{h,m}`
      (available/members lists, type popup, create flow).

## Wave 4 - App shell + window assembly (2 agents in parallel)

- [x] **4A. Application shell**: `Sources/main.m` (Processes-style env
      bootstrap; flags: `--mock` force mock backend, `--list` print tree
      headless then exit, `--test-refresh` smoke mode),
      `Sources/Application/DUApplicationDelegate.{h,m}`,
      `DUPreferencesController.{h,m}` (defaults: DUShowDetails,
      DUConfirmDestructiveOperations, DURefreshInterval,
      DULastSelectedOperation, DUWindowFrame), app menu bar built in code,
      shutdown ordering per ARCHITECTURE.md section 96.
- [x] **4B. Main window assembly**: `Sources/Controllers/
      DUMainWindowController.{h,m}`, `DUDeviceBrowserController.{h,m}`,
      `DUDeviceOutlineView.{h,m}`, `DUInformationController.{h,m}`.
      Window 780x515, min 650x430; toolbar (9 items, capability-enabled);
      outline browser 22-25% width with disclosure, 20 px rows, 16 px icons,
      contextual menus per SPEC section 33; persistent bottom info panel
      (disk/volume/optical/image field sets, SPEC sections 22-26);
      selection-change fan-out; window frame persistence.

## Wave 5 - Integration (me + fixer agent)

- [x] Full `gmake clean && gmake`: zero errors, zero warnings.
- [x] `--list --mock` prints hierarchy; `--test-refresh` exits 0. Real Linux discovery verified on nvme hardware.
- [x] Fixed cross-module mismatches (GNUstep API gaps, protocol stubs); git diff limited to DiskUtility/.
- [x] PLAN.md updated. Deviations: RAID UI deferred (user decision), programmatic UI instead of .gsmarkup, udev event monitoring replaced by conservative NSTimer polling per ARCHITECTURE.md 64 fallback.

## Wave 6 - Tests green + hardening (agent)

- [x] Contract tests: t_MockBackend (29 assertions) covers mock hierarchy + factory fallback + degraded mode.
- [x] Full suite green: 218 assertions across 4 tools, 0 failed.
- [x] Warning-free rebuild after fixes.

## Wave 7 - Delivery (me, with user)

- [ ] Ask user; then `sudo gmake install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM`;
      verify nothing landed in /Local.
- [ ] Optional GUI smoke test via driveui.
- [ ] NO commits without explicit user authorization.

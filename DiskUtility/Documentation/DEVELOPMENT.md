# DEVELOPMENT.md

Developer guide for DiskUtility. See README.md for user-facing basics,
ARCHITECTURE.md for module layout, SPEC.md for behavior, PLAN.md/TODO.md
for status.

## 1. Build

- Build: `gmake` (in this directory).
- Install: `sudo gmake install GNUSTEP_INSTALLATION_DOMAIN=SYSTEM`
  (installs to /System/Library/Applications/Utilities).
- Clean rebuild: build artifacts under `obj/` and `DiskUtility.app/` may be
  root-owned after a sudo build or install. Remove them with
  `sudo rm -rf obj DiskUtility.app` before rebuilding as a normal user.
- This component carries an empty `.DISABLED` marker file, which excludes
  it from the parent gershwin-components repo's top-level build dispatch
  (that GNUmakefile skips any subdirectory containing `.DISABLED`). Build
  and install it explicitly from this directory; do not remove the marker
  without deciding the app should join the tree-wide build.

## 2. Tests

Run:

    sh Tests/run.sh

The script sources GNUstep.sh, runs `gmake` inside Tests/, then executes
each tool binary from Tests/obj/ and prints per-tool PASS counts, exiting
nonzero on any failed assertion, uncaught exception, or missing binary.

Test tools (Tests/GNUmakefile):

| Tool | Source | Covers |
| --- | --- | --- |
| `t_Parsing` | TestParsing.m | all parsers fed recorded fixtures: lsblk pairs, blkid full output, FreeBSD geom list output, OpenBSD/NetBSD disklabel output, partition table normalization |
| `t_PartitionLayout` | TestPartitionLayout.m | DUPartitionLayout and DUPartitionPlan logic |
| `t_Models` | TestModels.m | storage domain model objects (device/partition/volume/image/optical/RAID, capabilities) |
| `t_MockBackend` | TestMockBackend.m | DUMockStorageBackend hierarchy/mounts and DUBackendFactory selection incl. degraded mode |
| `t_SHA256` | TestSHA256.m | DUSHA256 implementation |

Wiring notes: sources under test compile once into the ARC-enabled
`DUWave1TestSupport` convenience library; the test tools themselves are
NOT ARC because the ObjectTesting macros send explicit retain/release.
Tools link the shared library via rpath into ./obj.

Fixtures live in plain-text files under Tests/Fixtures/, one directory per
platform:

- `Tests/Fixtures/Linux/lsblk-pairs.txt`, `blkid.txt`
- `Tests/Fixtures/FreeBSD/geom-disk-list.txt`, `geom-part-list-ada0.txt`
- `Tests/Fixtures/OpenBSD/disklabel-sd0.txt`
- `Tests/Fixtures/NetBSD/disklabel-wd0.txt`

The shared loader (Tests/TestFixtures.h) runs the tools with Tests/ as
working directory; a missing fixture aborts loudly rather than failing
single assertions.

## 3. Headless Modes

All flags apply regardless of position (Sources/main.m):

- `--mock` - sets the `DUForceMockBackend` default; every later backend
  request returns DUMockStorageBackend, no real devices touched.
- `--list` - prints the discovered storage hierarchy as an indented,
  iterative pre-order dump (`name [identifier] type=N path=...`) and exits;
  exit 1 when discovery fails.
- `--test-refresh` - smoke mode: one refresh cycle on a background NSThread
  with a bounded 10-second wait so CI cannot wedge, prints
  `refresh finished. roots=<n>`, exits 0 only when at least one root was
  discovered.

Example: `DiskUtility --mock --list`.

## 4. Conventions

- Language/runtime: Objective-C with ARC -
  `-fobjc-arc -fobjc-runtime=gnustep-2.0 -fobjc-arc-exceptions`; built with
  `-Wall -Wextra -O2`. Zero warnings is
  a hard requirement; fix them before finishing work.
- Foundation-first core: Models/, Services/, Backend/, Operations/,
  Utilities/ import `<Foundation/Foundation.h>` only. AppKit stays in
  Application/, Controllers/, Views/. A future CLI should be able to reuse
  everything below the UI (ARCHITECTURE.md section 77).
- UI values come from AppearanceMetrics.h (repo root). Do not hardcode
  layout constants.
- User-visible strings go through NSLocalizedString everywhere, including
  backend error messages.
- No dispatch/libdispatch/GCD anywhere - it is unreliable here. Use
  NSThread (detached worker threads with autorelease pools), NSTimer,
  `performSelector:onThread:`; synchronize with NSLock/@synchronized.
- Platform conditionals (`#if defined(__linux__)` etc.) stay confined to
  Sources/Backend/ (and Utilities/); Views/, Controllers/, Models/ must not
  know which OS they run on.
- Comments explain WHY, not WHAT. No em-dashes anywhere; use plain
  hyphens.
- New files carry:
  `Copyright (c) 2026 Simon Peter` +
  `SPDX-License-Identifier: BSD-2-Clause`.
- Licensing rules for dependencies: see LIBRARIES.md and
  Documentation/BACKENDS.md section 6 - GPL/CDDL code never links into or
  dlopen()s into this process; external programs run only via
  DUProcessRunner.

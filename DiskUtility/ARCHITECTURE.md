# Architecture

## 1. Purpose

This document defines the architecture for a native GNUstep desktop disk-management application targeting:

* Linux
* FreeBSD
* OpenBSD
* NetBSD
* Other Unix-like systems with a sufficiently complete GNUstep environment

The application should be architected as a **proper GNUstep application**, using Objective-C, Foundation, AppKit, and GNUstep conventions rather than treating GNUstep as a compatibility layer for a platform-specific application.

The primary architectural goals are:

1. Native GNUstep integration.
2. Clean separation between UI, storage-domain logic, and operating-system backends.
3. No Linux-specific assumptions in the core application.
4. No BSD-specific assumptions in the core application.
5. Safe handling of privileged storage operations.
6. Asynchronous execution of all potentially blocking device operations.
7. A stable internal storage model independent of the underlying operating system.
8. Testability without requiring real disks.
9. Ability to add additional Unix backends without restructuring the UI.
10. Use of standard GNUstep build, resource, notification, preference, and application-lifecycle mechanisms.

---

# 2. Architectural Overview

The application is divided into five major layers:

```text
┌───────────────────────────────────────────────────────────────┐
│                         AppKit UI                             │
│                                                               │
│  Windows / Views / Controllers / Outline View / Toolbar       │
└───────────────────────────────┬───────────────────────────────┘
                                │
                                ▼
┌───────────────────────────────────────────────────────────────┐
│                    Application Services                       │
│                                                               │
│  Selection / Operations / Jobs / Validation / Presentation   │
└───────────────────────────────┬───────────────────────────────┘
                                │
                                ▼
┌───────────────────────────────────────────────────────────────┐
│                      Storage Domain                           │
│                                                               │
│  Devices / Volumes / Partitions / Images / RAID / Formats    │
└───────────────────────────────┬───────────────────────────────┘
                                │
                                ▼
┌───────────────────────────────────────────────────────────────┐
│                    Storage Backend API                        │
│                                                               │
│  Discovery / Mount / Unmount / Partition / Format / Verify   │
└───────────────────────────────┬───────────────────────────────┘
                                │
                 ┌──────────────┴──────────────┐
                 ▼                             ▼
        ┌─────────────────┐          ┌─────────────────┐
        │ Linux Backend   │          │ BSD Backends    │
        │                 │          │                 │
        │ udev/sysfs      │          │ geom/devd/etc.  │
        │ lsblk           │          │ native tools    │
        │ mount           │          │ mount           │
        │ cryptsetup*     │          │ disklabel/etc.* │
        └─────────────────┘          └─────────────────┘

* Optional functionality depends on platform/backend support.
```

The **UI never talks directly to `/dev`, `mount`, `lsblk`, GEOM, disklabel, or other platform mechanisms**.

All such operations pass through the backend abstraction.

---

# 3. Technology Stack

## 3.1 Language

Primary language:

* Objective-C

Use:

* Foundation
* AppKit
* GNUstep Base
* GNUstep GUI

C may be used for small low-level integration components where appropriate.

C++ should not be required by the core application.

## 3.2 Build System

The preferred build environment is GNUstep's standard tooling.

The project should support:

```text
GNUmakefile
```

using GNUstep's standard make infrastructure.

The application should be buildable using the conventional GNUstep workflow:

```text
. /path/to/GNUstep.sh
make
make install
```

or the equivalent environment configured by the user's GNUstep installation.

Do not require Xcode, Cocoa, Objective-C++ tooling, or platform-specific IDE projects.

A secondary build system may be provided later, but GNUstep's build conventions remain authoritative.

---

# 4. Repository Layout

Recommended repository structure:

```text
DiskUtility/
├── GNUmakefile
├── README.md
├── ARCHITECTURE.md
├── COPYING
├── ChangeLog
│
├── Sources/
│   ├── main.m
│   │
│   ├── Application/
│   │   ├── DUApplicationDelegate.h
│   │   ├── DUApplicationDelegate.m
│   │   ├── DUPreferencesController.h
│   │   └── DUPreferencesController.m
│   │
│   ├── Controllers/
│   │   ├── DUMainWindowController.h
│   │   ├── DUMainWindowController.m
│   │   ├── DUDeviceBrowserController.h
│   │   ├── DUDeviceBrowserController.m
│   │   ├── DUOperationController.h
│   │   ├── DUOperationController.m
│   │   └── DUInformationController.h
│   │
│   ├── Views/
│   │   ├── DUDeviceOutlineView.h
│   │   ├── DUDeviceOutlineView.m
│   │   ├── DUDiskMapView.h
│   │   ├── DUDiskMapView.m
│   │   ├── DUOperationLogView.h
│   │   └── DUOperationLogView.m
│   │
│   ├── Models/
│   │   ├── DUStorageDevice.h
│   │   ├── DUStorageDevice.m
│   │   ├── DUStorageVolume.h
│   │   ├── DUStorageVolume.m
│   │   ├── DUDiskImage.h
│   │   ├── DUDiskImage.m
│   │   ├── DUPartition.h
│   │   ├── DUPartition.m
│   │   ├── DURAIDSet.h
│   │   └── DURAIDSet.m
│   │
│   ├── Services/
│   │   ├── DUStorageManager.h
│   │   ├── DUStorageManager.m
│   │   ├── DUOperationManager.h
│   │   ├── DUOperationManager.m
│   │   ├── DUDeviceMonitor.h
│   │   ├── DUDeviceMonitor.m
│   │   ├── DUAuthorizationManager.h
│   │   ├── DUAuthorizationManager.m
│   │   └── DUImageService.h
│   │
│   ├── Backend/
│   │   ├── DUStorageBackend.h
│   │   ├── DUStorageBackend.m
│   │   ├── DUBackendCapabilities.h
│   │   ├── DUBackendFactory.h
│   │   └── DUBackendFactory.m
│   │
│   ├── Backend/Linux/
│   │   ├── DULinuxStorageBackend.h
│   │   ├── DULinuxStorageBackend.m
│   │   ├── DULinuxDeviceDiscovery.h
│   │   └── DULinuxDeviceDiscovery.m
│   │
│   ├── Backend/FreeBSD/
│   │   ├── DUFreeBSDStorageBackend.h
│   │   ├── DUFreeBSDStorageBackend.m
│   │   └── DUFreeBSDDeviceDiscovery.m
│   │
│   ├── Backend/OpenBSD/
│   │   ├── DUOpenBSDStorageBackend.h
│   │   ├── DUOpenBSDStorageBackend.m
│   │   └── DUOpenBSDDeviceDiscovery.m
│   │
│   ├── Backend/NetBSD/
│   │   ├── DUNetBSDStorageBackend.h
│   │   ├── DUNetBSDStorageBackend.m
│   │   └── DUNetBSDDeviceDiscovery.m
│   │
│   ├── Operations/
│   │   ├── DUOperation.h
│   │   ├── DUOperation.m
│   │   ├── DUVerifyOperation.h
│   │   ├── DUVerifyOperation.m
│   │   ├── DURepairOperation.h
│   │   ├── DURepairOperation.m
│   │   ├── DUEraseOperation.h
│   │   ├── DUEraseOperation.m
│   │   ├── DUPartitionOperation.h
│   │   ├── DUPartitionOperation.m
│   │   ├── DURestoreOperation.h
│   │   ├── DURestoreOperation.m
│   │   └── DURAIDOperation.h
│   │
│   └── Utilities/
│       ├── DUProcessRunner.h
│       ├── DUProcessRunner.m
│       ├── DUParsing.h
│       ├── DUParsing.m
│       ├── DUErrors.h
│       └── DUErrors.m
│
├── Resources/
│   ├── MainMenu.gsmarkup
│   ├── MainWindow.gsmarkup
│   ├── FirstAidView.gsmarkup
│   ├── EraseView.gsmarkup
│   ├── PartitionView.gsmarkup
│   ├── RAIDView.gsmarkup
│   ├── RestoreView.gsmarkup
│   ├── InfoView.gsmarkup
│   ├── Localizable.strings
│   ├── Images/
│   └── Icons/
│
├── Tests/
│   ├── Models/
│   ├── Backend/
│   ├── Operations/
│   ├── Parsing/
│   └── Fixtures/
│
└── Documentation/
    ├── BACKENDS.md
    ├── SECURITY.md
    └── DEVELOPMENT.md
```

The exact directory structure may evolve, but the architectural separation should remain.

---

# 5. GNUstep Application Lifecycle

The application should follow the standard GNUstep application lifecycle.

`main.m` should be deliberately small.

Conceptually:

```text id="q1c1n7"
main
 │
 ├── NSAutoreleasePool
 │
 ├── NSApplication sharedApplication
 │
 ├── create application delegate
 │
 └── run
```

The application delegate owns application-wide services and creates the main window controller.

The delegate should not contain storage-management logic.

---

# 6. Application Delegate

`DUApplicationDelegate` is responsible for application lifecycle and global service initialization.

Responsibilities:

* Initialize the application.
* Create global services.
* Register default preferences.
* Create the main window controller.
* Respond to application termination.
* Coordinate application-wide notifications.

It should not:

* Enumerate `/dev`.
* Execute partitioning commands.
* Format disks.
* Parse platform command output.
* Manipulate views directly beyond application-level coordination.

---

# 7. Main Window Controller

`DUMainWindowController` owns the main window.

Responsibilities:

* Create/load the main window.
* Coordinate the device browser.
* Coordinate the operation area.
* Coordinate the information panel.
* Maintain current selection.
* Respond to storage-discovery changes.
* Update toolbar state.

The controller should act as an orchestration layer rather than becoming a monolithic controller.

---

# 8. MVC Structure

The UI should follow a conventional GNUstep/AppKit MVC design.

```text
Model
  │
  │ notifications / bindings / controller calls
  ▼
Controller
  │
  │ view state
  ▼
View
```

Models should not import AppKit.

For example:

```text id="u5m1l4"
DUStorageDevice.h
    ↓
Foundation only

DUMainWindowController.h
    ↓
Foundation + AppKit

DUDiskMapView.h
    ↓
AppKit
```

The storage domain must remain usable in a non-GUI test process.

---

# 9. Storage Domain Model

The central domain abstraction is a storage object hierarchy.

## 9.1 Base object

Define a common `DUStorageObject` abstraction.

Conceptually:

```text id="h5t5j7"
DUStorageObject
├── DUStorageDevice
├── DUPartition
├── DUStorageVolume
├── DUOpticalMedia
├── DUDiskImage
└── DURAIDSet
```

Every storage object should have:

* Stable identifier
* Display name
* Object type
* Parent
* Children
* Capabilities
* State
* Backend-specific identifier

---

# 10. Stable Object Identity

The UI must not use display names as identifiers.

For example, these are not sufficient:

```text
"Data"
"disk0"
"/dev/sda"
```

Instead, each object has a stable internal identifier.

Example:

```objc
@interface DUStorageObject : NSObject

@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *displayName;

@end
```

The backend can associate the object with:

```text
Linux:
  /dev/sda
  /dev/disk/by-id/...

FreeBSD:
  /dev/ada0

OpenBSD:
  /dev/sd0

NetBSD:
  /dev/wd0
```

The rest of the application must not care which representation is used.

---

# 11. Device Model

`DUStorageDevice` represents a physical or virtual storage device.

Possible properties:

```text id="y7s3k8"
identifier
displayName
devicePath
connectionType
capacity
removable
readOnly
ejectable
partitionScheme
healthStatus
partitions
```

The device model should distinguish:

* Physical device
* Virtual device
* Removable device
* Optical device

using explicit type/capability information rather than string inspection.

---

# 12. Partition Model

`DUPartition` represents a partition-table entry.

Properties:

```text id="y1q6dy"
identifier
index
offset
size
partitionType
partitionName
filesystemType
bootable
readOnly
volume
```

The partition map view should consume these properties without knowing how the partition information was obtained.

---

# 13. Volume Model

`DUStorageVolume` represents a mounted or mountable filesystem.

Properties:

```text id="k4t8uj"
identifier
displayName
mountPoint
filesystemType
capacity
availableSpace
usedSpace
mounted
readOnly
ownersEnabled
fileCount
folderCount
```

The model may contain optional metadata.

The UI should gracefully handle unavailable values.

For example:

```text
Available: —
```

rather than assuming that every filesystem exposes every metric.

---

# 14. Disk Image Model

`DUDiskImage` represents an image file.

Properties may include:

```text id="w3m8jv"
path
format
size
compressed
encrypted
readOnly
mounted
```

The image implementation should remain separate from physical-device management.

---

# 15. RAID Model

`DURAIDSet` represents a logical storage set.

Properties:

```text id="qg6l4n"
identifier
name
raidLevel
members
capacity
status
degraded
```

RAID support is capability-driven.

A backend that does not provide a particular RAID mode must report it as unavailable rather than forcing the UI to know platform details.

---

# 16. Capability System

A central capability abstraction prevents platform-specific conditionals from leaking into the UI.

Example:

```text id="0x1k2n"
DUStorageCapabilities
├── canVerify
├── canRepair
├── canErase
├── canPartition
├── canResize
├── canMount
├── canUnmount
├── canEject
├── canBurn
├── canCreateImage
├── canRestore
├── canCreateRAID
└── canRepairPermissions
```

The toolbar and operation tabs derive their enabled state from capabilities.

Do not write:

```objc
if (isLinux) ...
if (isFreeBSD) ...
```

inside UI controllers.

Instead:

```objc
if ([device.capabilities canPartition]) ...
```

---

# 17. Backend Abstraction

The most important portability boundary is `DUStorageBackend`.

The interface defines storage operations in application terms.

Conceptually:

```objc
@protocol DUStorageBackend <NSObject>

- (NSArray *)discoverStorageObjects:(NSError **)error;

- (void)refreshStorageObjects;

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

@end
```

The exact API can use operation objects rather than blocks; the important requirement is that callers operate entirely through the abstraction.

---

# 18. Backend Responsibilities

A backend is responsible for:

1. Device discovery.
2. Device metadata.
3. Filesystem detection.
4. Mount-state detection.
5. Partition-table detection.
6. Capability detection.
7. Executing storage operations.
8. Parsing platform-specific output.
9. Converting platform errors into application errors.
10. Monitoring storage topology changes.

The backend is **not** responsible for:

* Drawing UI.
* Presenting confirmation dialogs.
* Choosing which tab is selected.
* Deciding how information is laid out.
* Formatting user-facing strings except for structured backend error information.

---

# 19. Linux Backend

The Linux backend should use a layered strategy.

Preferred sources of information:

1. `/sys`
2. `/dev`
3. udev/libudev where available
4. Standard system utilities where appropriate
5. Specialized libraries where justified

Typical facilities may include:

```text id="h8x8c6"
udev
sysfs
mount
umount
lsblk
blkid
findmnt
parted
sfdisk
wipefs
fsck.*
mkfs.*
```

The backend should not assume that every distribution installs every command.

Availability should be detected at runtime.

Do not parse human-localized output.

Prefer:

* machine-readable output
* stable command flags
* direct system APIs
* structured interfaces

over human-oriented command output.

---

# 20. BSD Backends

BSD platforms should have dedicated backend implementations where their storage stacks differ materially.

Do not create one enormous:

```text
DUBSDBackend
```

with hundreds of operating-system conditionals.

Prefer:

```text id="c7l5wy"
DUFreeBSDStorageBackend
DUOpenBSDStorageBackend
DUNetBSDStorageBackend
```

Each backend can share common BSD utility code where appropriate.

---

# 21. FreeBSD

FreeBSD storage discovery should integrate with the system's storage framework, including GEOM where appropriate.

The backend may use:

* `/dev`
* GEOM information
* device event facilities
* filesystem utilities
* mount utilities
* partitioning utilities
* native storage-management interfaces

The backend should translate GEOM concepts into the application's generic model.

The rest of the application must not depend on GEOM terminology.

---

# 22. OpenBSD

OpenBSD has different storage and device-management conventions.

The backend should use native OpenBSD facilities and utilities appropriate to the operation.

Platform-specific details remain isolated within:

```text
Backend/OpenBSD/
```

The UI should receive the same generic model:

```text
DUStorageDevice
DUPartition
DUStorageVolume
```

regardless of how the information was acquired.

---

# 23. NetBSD

NetBSD receives its own backend for the same reason.

Device discovery, partitioning, filesystem operations, and device naming conventions should be handled exclusively inside:

```text
Backend/NetBSD/
```

Do not allow NetBSD-specific device names to escape into the domain model as behavioral dependencies.

---

# 24. Backend Factory

`DUBackendFactory` selects the appropriate backend.

Selection can use compile-time platform identification combined with runtime capability probing.

Conceptually:

```text id="0r3d5q"
Operating System
       │
       ▼
DUBackendFactory
       │
       ├── Linux
       ├── FreeBSD
       ├── OpenBSD
       ├── NetBSD
       └── Unsupported
```

The factory returns a single backend interface to the application.

Unsupported functionality should be represented through capabilities.

---

# 25. Do Not Build the UI Around Shell Commands

Shell commands are implementation details.

The architecture must not look like:

```text
UI
 ↓
NSString command
 ↓
NSTask
 ↓
parse stdout
 ↓
update UI
```

Instead:

```text
UI
 ↓
Operation Controller
 ↓
Storage Service
 ↓
Operation
 ↓
Backend
 ↓
Native API / command / helper
```

This distinction is important because command-line interfaces vary significantly between systems.

---

# 26. Process Execution

Some operations will necessarily require invoking external utilities.

Provide a dedicated abstraction:

```text
DUProcessRunner
```

Responsibilities:

* Launch executable.
* Pass arguments without shell interpretation.
* Capture stdout.
* Capture stderr.
* Capture exit status.
* Stream output.
* Support cancellation.
* Support environment configuration.
* Prevent accidental shell injection.

Never construct shell commands like:

```text
"rm -rf " + userInput
```

or:

```text
system(command)
```

User-provided paths must always be passed as arguments.

---

# 27. Privileged Operations

Disk management inevitably requires privileged operations.

Privilege handling should be isolated behind:

```text
DUAuthorizationManager
```

The UI should never:

* run the entire application as root
* request a root shell
* use `sudo` interactively
* embed passwords
* execute arbitrary commands as root

The normal GUI process should remain unprivileged.

Only individual operations that require elevated privileges should cross the privilege boundary.

---

# 28. Privileged Helper

Where elevated access is required, provide a small helper/service process.

Conceptually:

```text
Unprivileged GUI
      │
      │ authenticated IPC
      ▼
Privileged Helper
      │
      ▼
Storage subsystem
```

The helper should expose a narrowly defined protocol.

Example operations:

```text id="y1b3lm"
getDeviceInfo
mount
unmount
eject
erase
partition
format
repair
restore
createRAID
destroyRAID
```

It must not expose:

```text
execute(command)
runShell(command)
```

---

# 29. Helper Security

The helper must:

* Validate every request.
* Validate object identifiers.
* Validate paths.
* Validate operation parameters.
* Reject unknown operations.
* Reject malformed requests.
* Never interpret request data as shell syntax.
* Restrict executable paths.
* Restrict allowed operations.
* Return structured errors.

The helper should assume that the GUI process can be compromised.

Privilege boundaries must therefore be explicit.

---

# 30. Operation Model

Long-running work should be represented as objects.

Base class:

```text
DUOperation
```

Examples:

```text
DUVerifyOperation
DURepairOperation
DUEraseOperation
DUPartitionOperation
DURestoreOperation
DURAIDOperation
DUImageOperation
```

Each operation has:

```text id="8m0l8p"
identifier
state
progress
message
startTime
finishTime
error
```

State machine:

```text id="by2q0z"
Pending
  ↓
Preparing
  ↓
Running
  ├──→ Cancelling
  │       ↓
  │     Cancelled
  │
  ├──→ Completed
  │
  └──→ Failed
```

---

# 31. Asynchronous Operations

No storage operation may block the main AppKit thread.

This includes:

* Device discovery
* Filesystem probing
* Mounting
* Unmounting
* Verification
* Repair
* Formatting
* Partitioning
* Image creation
* Image conversion
* Image resizing
* Restore
* RAID operations

Use background execution facilities appropriate to the GNUstep/Foundation environment.

UI updates must be marshalled back to the main thread.

---

# 32. Operation Manager

`DUOperationManager` owns active operations.

Responsibilities:

* Start operations.
* Track operations.
* Cancel operations.
* Deliver progress.
* Deliver completion.
* Maintain operation history.
* Ensure only valid concurrent operations run.

Example:

```text id="dbv4b9"
DUOperationManager
       │
       ├── Verify Operation
       ├── Erase Operation
       └── Restore Operation
```

The operation manager can reject conflicting operations.

For example:

```text
Erase /dev/device
```

should prevent another operation from simultaneously modifying the same device.

---

# 33. Device Locking

Before destructive operations, acquire an application-level operation lock.

The lock should be based on the stable device identifier.

Example:

```text id="u7k6t5"
device-123
   │
   ├── Verify: running
   ├── Erase: rejected
   └── Partition: rejected
```

This is not a substitute for OS-level locking.

The backend must still rely on the operating system and storage tools to prevent conflicting access.

---

# 34. Device Discovery

Discovery should be represented as a service:

```text
DUDeviceMonitor
```

Responsibilities:

* Initial enumeration.
* Detect device arrival.
* Detect device removal.
* Detect mount changes.
* Detect partition changes.
* Refresh metadata.

The UI subscribes to model changes.

It should not periodically scan `/dev` itself.

---

# 35. Device Change Notifications

When topology changes:

```text
DeviceMonitor
      ↓
StorageManager
      ↓
Model update
      ↓
NSNotification
      ↓
Controllers
      ↓
Views
```

Use Foundation notifications or another normal GNUstep mechanism for model-change propagation.

Controllers should not poll unnecessarily.

---

# 36. Storage Manager

`DUStorageManager` is the application's central storage-domain service.

Responsibilities:

* Own the active backend.
* Maintain the current storage model.
* Refresh devices.
* Resolve stable identifiers.
* Expose capabilities.
* Start storage operations.
* Publish topology changes.

It should not own AppKit views.

---

# 37. Model Update Strategy

Device discovery produces a new snapshot.

The storage manager compares it against the existing model.

Possible changes:

```text
Added device
Removed device
Added volume
Removed volume
Mounted
Unmounted
Metadata changed
Partition table changed
```

The UI should update incrementally where practical.

Avoid rebuilding the entire outline view on every filesystem event.

---

# 38. UI Binding Strategy

GNUstep bindings can be used for straightforward property presentation, but the application should not become dependent on bindings for complex storage state.

Recommended:

* Direct controller/model coordination for storage state.
* Bindings for simple form fields where they improve clarity.
* Explicit callbacks for asynchronous operations.
* Notifications for topology changes.

The architecture should remain understandable without relying on implicit binding behavior.

---

# 39. Device Browser Controller

`DUDeviceBrowserController` owns the outline/tree view.

Responsibilities:

* Provide hierarchical storage objects.
* Handle selection.
* Expand/collapse devices.
* Update when storage topology changes.
* Initiate contextual commands.

It should not perform disk operations itself.

Instead:

```text id="f4j4am"
Device Browser
      ↓
Operation Controller
      ↓
Operation Manager
```

---

# 40. Operation Controller

`DUOperationController` coordinates the operation tabs.

It determines:

* Current selected object.
* Current operation.
* Operation capabilities.
* Which controls are enabled.
* Which operation object to construct.

Example:

```text id="6x3k1v"
Selected object
      +
Selected tab
      +
Capabilities
      ↓
DUOperationController
      ↓
DUVerifyOperation
```

---

# 41. Operation Views

Each operation should have its own view/controller pair.

Example:

```text id="i7t8vz"
DUFirstAidViewController
DUEraseViewController
DUPartitionViewController
DURAIDViewController
DURestoreViewController
```

Do not put every operation into one enormous view controller.

Each controller owns:

* Its controls.
* Validation.
* Operation-specific presentation.
* Operation-specific state.

It delegates actual storage work to the operation/service layer.

---

# 42. Partition Map View

`DUDiskMapView` is a specialized custom view.

It is responsible only for presentation and interaction.

It should:

* Draw partitions.
* Display names.
* Display relative sizes.
* Highlight selection.
* Handle mouse interaction.
* Allow partition boundary dragging where supported.

It should not:

* Modify partition tables.
* Execute partitioning utilities.
* Format volumes.
* Determine filesystem types.

When the user finishes editing:

```text id="t1e6iq"
DUDiskMapView
      ↓
DUPartitionModel
      ↓
DUPartitionOperation
```

---

# 43. Partition Editing Model

Do not immediately modify the real disk when the user drags a partition boundary.

Maintain a pending layout:

```text id="v2f2a8"
Actual Layout
     +
Pending Changes
     ↓
Proposed Layout
```

The `Apply` action converts the proposed layout into an operation.

`Revert` discards the proposed layout.

This makes the UI predictable and allows validation before destructive changes occur.

---

# 44. Validation

Before an operation reaches a backend, validate it at the domain level.

Examples:

### Erase

Check:

* Object is erasable.
* Format is supported.
* Name is valid.
* Device is not locked.
* Required privileges are available.

### Partition

Check:

* Proposed layout fits device capacity.
* Partitions do not overlap.
* Minimum sizes are respected.
* Partition scheme supports the requested layout.
* Backend supports the required operation.

### Restore

Check:

* Source exists.
* Destination exists.
* Source and destination are distinct where required.
* Destination is writable.
* Destination capacity is sufficient.

---

# 45. Error Model

Errors should be structured.

Define an application error domain such as:

```text id="2f9q8w"
DUStorageErrorDomain
```

Categories can include:

```text
DiscoveryFailed
PermissionDenied
DeviceBusy
UnsupportedOperation
InvalidArgument
DeviceNotFound
FilesystemError
PartitionError
MountError
UnmountError
VerificationFailed
RepairFailed
EraseFailed
RestoreFailed
Cancelled
BackendUnavailable
```

A backend translates platform-specific failures into these application-level errors.

---

# 46. User-Facing Error Messages

Do not expose raw shell output as the primary error message.

Instead:

```text
Unable to erase the selected device.

The device is currently in use by another process.
```

The detailed backend output can be available in the operation log.

This gives users a useful explanation while retaining technical information for diagnosis.

---

# 47. Logging

Use Foundation logging facilities for application diagnostics.

Separate:

### User operation log

Visible in the UI.

Contains:

* operation steps
* progress messages
* warnings
* completion status

### Developer/application log

Used for:

* backend diagnostics
* unexpected state
* debugging
* IPC failures
* discovery errors

Do not mix internal debugging noise into the normal operation log.

---

# 48. Localization

All user-visible strings must be localizable.

Use GNUstep's localization mechanisms and `.strings` resources.

Never construct user-facing messages through string concatenation where localization could change word order.

Prefer format strings:

```text
"Erasing %@" 
```

with localized format semantics.

Filesystem and device names are user data and should never be localized.

---

# 49. Resource Management

GUI resources belong under the application bundle/resource directory.

Examples:

```text
Resources/
├── MainMenu.gsmarkup
├── MainWindow.gsmarkup
├── Images/
├── Icons/
└── Localizable.strings
```

Where GNUstep resource loading supports it, use:

```objc
[[NSBundle mainBundle] pathForResource:...]
```

rather than hard-coded installation paths.

---

# 50. Interface Construction

The application should prefer GNUstep interface resources where practical.

The main window can be defined using GNUstep-compatible GUI resources / GSGuiBuilder/GSMarkup conventions, with controllers connecting the interface to application services.

Programmatic UI construction is acceptable for highly dynamic controls such as:

* Partition maps
* Device lists
* Dynamic RAID members

Avoid creating every static label and button manually in code.

---

# 51. AppKit Ownership

Use conventional ownership:

```text
Application Delegate
       │
       └── Main Window Controller
               │
               ├── Device Browser Controller
               ├── Operation Controller
               └── Information Controller
```

Controllers retain their required model/service dependencies.

Views do not own global services.

The backend does not retain view/controllers.

This keeps lifecycle relationships unidirectional.

---

# 52. Notifications

Define application-specific notification names centrally.

Examples:

```text id="u7lq2f"
DUStorageTopologyDidChangeNotification
DUStorageSelectionDidChangeNotification
DUOperationDidStartNotification
DUOperationDidUpdateNotification
DUOperationDidFinishNotification
DUOperationDidFailNotification
```

Notifications should carry structured objects where possible rather than relying on global state.

---

# 53. Threading Model

The main thread owns:

* NSApplication
* Windows
* Views
* AppKit objects
* User interaction

Background execution owns:

* Device probing
* Process execution
* Storage operations
* Parsing large command output
* Device monitoring where necessary

General rule:

```text
AppKit → main thread
Storage I/O → background
UI notification → main thread
```

Do not manipulate AppKit controls directly from backend threads.

---

# 54. Concurrency

The application should support multiple non-conflicting background operations where useful.

For example:

```text
Verify Device A
        +
Inspect Device B
```

may run concurrently.

But operations modifying the same object must be serialized.

The operation manager should provide resource-based serialization rather than a global "only one operation at a time" lock.

---

# 55. Testing Architecture

The storage domain must be testable without actual storage devices.

Tests should be divided into:

```text
Models
Parsing
Backends
Operations
Controllers
Views
```

The most important tests should not require root privileges.

---

# 56. Mock Backend

Define:

```text
DUMockStorageBackend
```

It should generate an artificial storage hierarchy:

```text
Internal Disk
├── System
├── Data
└── Recovery

External Disk
└── Backup

Optical Drive
└── Installation Media

Disk Image
└── Image Volume
```

This permits UI development without modifying real devices.

---

# 57. Fixture-Based Backend Testing

Backend parsers should accept fixture data.

For example:

```text
Tests/Fixtures/Linux/
Tests/Fixtures/FreeBSD/
Tests/Fixtures/OpenBSD/
Tests/Fixtures/NetBSD/
```

Fixtures should contain representative:

* Device listings
* Partition listings
* Filesystem information
* Mount information
* Error output
* Command exit statuses

This allows parsing to be tested independently of the host operating system.

---

# 58. Integration Tests

Integration tests should be optional and explicitly marked.

They may require:

* root privileges
* loop devices
* virtual disks
* temporary filesystems
* virtual machines
* platform-specific facilities

Never make destructive integration tests operate on arbitrary host disks.

Use disposable virtual storage.

---

# 59. Backend Contract Tests

Every backend should pass a common contract suite.

Conceptually:

```text
DUStorageBackendContractTests
```

The same tests should run against:

```text
LinuxBackend
FreeBSDBackend
OpenBSDBackend
NetBSDBackend
MockBackend
```

where the operation is supported.

This ensures that the platform implementations present consistent semantics.

---

# 60. Feature Detection

Portability must be based on capabilities rather than assumptions.

For example:

```text
Backend supports partitioning
Backend supports filesystem repair
Backend supports secure erase
Backend supports RAID
Backend supports image conversion
```

A feature unavailable on one platform should appear disabled or hidden according to the application's UX policy.

The UI must never crash because a backend returns an unsupported capability.

---

# 61. Platform Conditional Compilation

Conditional compilation should be concentrated in backend selection and low-level integration.

Acceptable:

```objc
#if defined(__linux__)
...
#elif defined(__FreeBSD__)
...
#elif defined(__OpenBSD__)
...
#elif defined(__NetBSD__)
...
#endif
```

inside:

```text
Backend/
Utilities/
```

Avoid these checks in:

```text
Views/
Controllers/
Models/
```

A controller should not know whether it is running on Linux or BSD.

---

# 62. Filesystem Support

Filesystem support should be capability-based.

The model should use identifiers such as:

```text
filesystemType = "ext4"
filesystemType = "ufs"
filesystemType = "zfs"
filesystemType = "ntfs"
filesystemType = "vfat"
filesystemType = "xfs"
```

The UI should not assume a fixed list.

Backend metadata can describe:

```text
displayName
canFormat
canRepair
canResize
canMount
```

This allows platform-specific filesystems to appear naturally.

---

# 63. Mount Management

Mount operations should be exposed through:

```text
mountObject:
unmountObject:
```

The backend determines the correct mechanism.

The UI only understands:

```text
mounted
unmounted
mountPoint
readOnly
```

Do not make the main application construct mount commands.

---

# 64. Device Monitoring

The device monitor should use the best native mechanism available.

Examples:

```text
Linux:
  udev/device events

FreeBSD:
  devd / native device events

OpenBSD:
  native device/event mechanisms where available

NetBSD:
  native device/event mechanisms where available
```

If event-driven monitoring is unavailable, the backend may fall back to periodic refresh.

The fallback interval should be configurable and conservative.

---

# 65. Graceful Degradation

The application must still operate when optional infrastructure is absent.

Examples:

```text
No udev
    ↓
Use filesystem/device probing fallback

No RAID support
    ↓
RAID tab disabled

No secure erase facility
    ↓
Security Options exposes only supported methods

No image conversion support
    ↓
Convert command disabled
```

The application should not terminate simply because an optional backend facility is unavailable.

---

# 66. Unsupported Operating Systems

If the application is compiled on an unsupported system, the backend factory should return a backend that exposes discovery failure clearly.

The application should launch and explain:

```text
Storage management is not available on this system.

No compatible storage backend was detected.
```

This is preferable to failing during application startup.

---

# 67. Configuration and Preferences

Use standard GNUstep user-default mechanisms for preferences.

Examples:

```text
DUShowDetails
DUConfirmDestructiveOperations
DURefreshInterval
DULastSelectedOperation
DUWindowFrame
```

Never store configuration in arbitrary files under `/etc` unless system-wide configuration is explicitly required.

Per-user preferences belong in the user's normal GNUstep preferences domain.

---

# 68. Window Restoration

Store:

* Window size
* Window position
* Sidebar width
* Last selected operation

Do not persist a device selection solely by display name.

If restoring the previous selection:

1. Resolve its stable identifier.
2. Verify the device still exists.
3. Select it if available.
4. Otherwise select the first suitable device.

---

# 69. Data Flow Example: Verify

A verify operation should follow this sequence:

```text id="m5x9zq"
User clicks "Verify Disk"
        │
        ▼
DUFirstAidViewController
        │
        ▼
Validate selected object
        │
        ▼
DUStorageManager
        │
        ▼
DUVerifyOperation
        │
        ▼
DUStorageBackend
        │
        ▼
Platform implementation
        │
        ▼
Progress / output
        │
        ├──────────────→ Operation Log
        │
        └──────────────→ Progress UI
        │
        ▼
Completion
        │
        ▼
Refresh storage model
```

---

# 70. Data Flow Example: Partition

Partitioning follows a stricter sequence:

```text
User edits graphical partition layout
        │
        ▼
Pending partition model
        │
        ▼
Validate proposed layout
        │
        ▼
User clicks Apply
        │
        ▼
Confirmation dialog
        │
        ▼
DUPartitionOperation
        │
        ▼
Backend
        │
        ▼
Privilege boundary
        │
        ▼
Partition subsystem
        │
        ▼
Refresh device topology
```

The UI must never treat the graphical layout as proof that the real disk has already changed.

---

# 71. Data Flow Example: Erase

```text
User chooses format
        │
        ▼
Erase Controller
        │
        ▼
Validate parameters
        │
        ▼
Show destructive confirmation
        │
        ▼
Create DUEraseOperation
        │
        ▼
Storage Backend
        │
        ▼
Privileged helper if required
        │
        ▼
Filesystem/device operation
        │
        ▼
Refresh model
        │
        ▼
Update UI
```

---

# 72. Data Flow Example: Device Arrival

```text
Operating system event
        │
        ▼
Platform Device Monitor
        │
        ▼
DUDeviceMonitor
        │
        ▼
DUStorageManager
        │
        ▼
Reconcile storage model
        │
        ▼
DUStorageTopologyDidChangeNotification
        │
        ├── Device Browser
        ├── Toolbar
        └── Information Panel
```

---

# 73. Separation of Concerns

The following boundaries are mandatory.

### Views

Responsible for:

* Drawing.
* Input.
* Visual state.

Not responsible for:

* Storage operations.
* Privilege escalation.
* Device discovery.

### Controllers

Responsible for:

* User interaction.
* View state.
* Coordinating services.

Not responsible for:

* Parsing platform commands.
* Device enumeration.

### Models

Responsible for:

* Storage state.
* Domain properties.
* Relationships.

Not responsible for:

* AppKit.
* Shell commands.

### Services

Responsible for:

* Application-wide coordination.
* Operation management.
* Device monitoring.

Not responsible for:

* Drawing.

### Backends

Responsible for:

* Platform-specific storage interaction.

Not responsible for:

* User-interface decisions.

---

# 74. Dependency Direction

Dependencies should point toward abstractions.

Preferred:

```text
Views
  ↓
Controllers
  ↓
Services
  ↓
Backend Protocol
  ↓
Platform Backend
```

Models can be shared by all layers but should remain independent of AppKit.

Avoid:

```text
Linux Backend
     ↓
View Controller
```

or:

```text
View
     ↓
NSTask
```

or:

```text
Model
     ↓
NSWindow
```

---

# 75. Naming Conventions

Use a project prefix consistently:

```text
DU
```

Examples:

```text
DUStorageDevice
DUStorageVolume
DUMainWindowController
DUStorageManager
DUStorageBackend
DUVerifyOperation
```

Avoid generic names such as:

```text
Manager
Device
Operation
Controller
Backend
```

because they become difficult to search and can collide with framework classes.

---

# 76. Memory Management

The project should support the memory-management model appropriate to the selected GNUstep environment.

The implementation should not require modern Objective-C runtime features that are unavailable on supported GNUstep configurations.

If the project targets environments where manual reference counting is required, use:

```objc
retain
release
autorelease
```

consistently.

If a sufficiently modern GNUstep runtime is selected as a project requirement, ARC may be adopted, but this decision must be explicit and documented.

Do not mix ownership models casually.

---

# 77. Foundation-First Core

The storage domain and operation layer should be compilable without AppKit.

For example, a future command-line diagnostic tool should theoretically be able to reuse:

```text
Models/
Backend/
Operations/
Services/
Utilities/
```

without importing:

```text
AppKit
```

This is a strong architectural test of whether the GUI is properly separated from storage logic.

---

# 78. Command-Line Diagnostic Tool

A future optional executable could reuse the core services:

```text
diskutil-cli
```

with commands such as:

```text
list
info DEVICE
verify DEVICE
erase DEVICE
mount DEVICE
unmount DEVICE
```

This is not required for the initial release, but the architecture should not prevent it.

The GUI and CLI should share the same backend contracts.

---

# 79. Backend Capability Reporting

Backends should expose a capability report.

Example:

```text id="f7c5h2"
Platform: FreeBSD

Device discovery: yes
Mount management: yes
Partitioning: yes
Filesystem formatting: yes
Filesystem repair: partial
Secure erase: no
RAID management: yes
Disk image mounting: yes
Disk image conversion: partial
```

This can be used by diagnostics and support tools.

---

# 80. Security Principles

Storage-management software should follow a conservative security model.

Rules:

1. GUI runs unprivileged.
2. Privilege is acquired only when required.
3. Privileged operations are narrowly scoped.
4. Never invoke a shell with user input.
5. Validate all device identifiers.
6. Validate all paths.
7. Never trust device names as authorization.
8. Confirm destructive operations.
9. Never silently overwrite storage.
10. Log privileged operations.
11. Treat backend output as untrusted data.
12. Never expose privileged helper functionality beyond the defined protocol.

---

# 81. Recovery and Failure

If an operation fails halfway through:

* Preserve the operation log.
* Report failure.
* Refresh the affected device.
* Re-read partition and filesystem state.
* Do not assume the previous model remains correct.
* Disable operations until the refreshed state is known.

For example:

```text
Partition operation failed
        ↓
Do NOT simply restore old model
        ↓
Re-probe device
        ↓
Reconcile actual state
        ↓
Update UI
```

This is particularly important because storage operations can partially succeed.

---

# 82. Device Removal During Operation

If a device disappears while an operation is active:

1. Mark the operation as interrupted.
2. Stop sending commands where possible.
3. Capture process termination.
4. Refresh storage topology.
5. Display a clear error.
6. Do not attempt to recreate the device model artificially.

Example:

```text
The device was disconnected while the operation
was in progress.

The current state of the device could not be verified.
```

---

# 83. Backend Process Cancellation

Every external process should have a cancellation mechanism.

Cancellation should:

1. Signal the process.
2. Wait for termination.
3. Clean up descriptors.
4. Mark the operation cancelled.
5. Refresh device state.

Do not simply abandon a running process.

---

# 84. Resource Cleanup

Backends must correctly release:

* File descriptors
* Pipes
* Process handles
* Device handles
* IPC connections
* Temporary files
* Temporary mount points
* Background worker resources

The application should remain stable after repeated operations.

---

# 85. Temporary Files

Temporary resources should be created through Foundation APIs where possible.

Never use predictable names such as:

```text
/tmp/diskutility
```

Use securely created temporary paths.

Temporary files must be removed on:

* successful completion
* failure
* cancellation
* application termination where practical

---

# 86. Testing Destructive Code

Destructive operations should have two layers:

### Planning

Pure logic that produces an operation plan:

```text
ErasePlan
PartitionPlan
RestorePlan
```

### Execution

Backend-specific implementation of the plan.

This allows tests such as:

```text
Given:
  disk size = 100 GB
  partition A = 50 GB
  partition B = 50 GB

When:
  partition A resized to 60 GB

Then:
  partition B becomes 40 GB
```

without touching a disk.

---

# 87. Operation Plans

For complex operations, use immutable or effectively immutable operation descriptions.

Example:

```text id="2z5j4k"
DUPartitionPlan

diskIdentifier
partitionScheme
partitions[]
destructive
requiresPrivilege
```

The backend receives the validated plan rather than a collection of loosely related UI values.

This reduces the chance that UI state can be accidentally interpreted as an operation.

---

# 88. Backend Adapters

Where a platform command is required, isolate it behind a small adapter.

Example:

```text id="f8w5p3"
DULinuxPartitionTool
DULinuxFilesystemTool
DUFreeBSDGEOMAdapter
DUOpenBSDPartitionAdapter
```

The higher-level backend composes these components.

This prevents the platform backend itself from becoming another monolithic class.

---

# 89. Parsers

Command output parsing should be isolated.

Example:

```text id="6slv8p"
DULsblkParser
DUBlkidParser
DUFreeBSDGEOMParser
DUPartitionTableParser
```

Parsers should:

* Take input.
* Produce structured Foundation objects.
* Never modify devices.
* Be independently unit-testable.

A parser should never directly update the UI.

---

# 90. External Command Policy

When using system commands:

* Use absolute executable paths after discovery.
* Pass arguments as an array.
* Avoid shell expansion.
* Request machine-readable output.
* Set a controlled environment.
* Capture exit status.
* Capture stderr separately.
* Apply reasonable timeouts where appropriate.

Do not rely on:

```text
PATH
LANG
LC_ALL
user shell aliases
shell functions
```

for correctness.

---

# 91. Locale Independence

Backend parsing must be locale-independent.

For command-line tools that support machine-readable output, use it.

For tools whose output cannot be made machine-readable:

* Set a known locale where supported.
* Keep parsers platform-specific.
* Test multiple representative versions.
* Avoid parsing translated human prose whenever possible.

User-facing strings remain localized independently.

---

# 92. Version Differences

Operating systems and utilities evolve.

Backends should detect supported command capabilities rather than assuming one exact version.

For example:

```text
probe utility
      ↓
determine supported options
      ↓
select implementation
```

Do not scatter version checks throughout the application.

Keep compatibility logic inside the backend adapter.

---

# 93. Backend API Stability

The application-level backend API should describe **intent**, not implementation.

Good:

```text
verifyVolume:
eraseDevice:
mountVolume:
partitionDeviceWithPlan:
```

Bad:

```text
runLsblk:
runGparted:
runGpart:
runDisklabel:
```

The latter exposes platform implementation details to higher layers.

---

# 94. UI State Machine

The main UI can be modeled as:

```text
No Device
    │
    ▼
Device Selected
    │
    ├── First Aid
    ├── Erase
    ├── Partition
    ├── RAID
    └── Restore
          │
          ▼
     Operation Running
          │
       ┌──┴──┐
       ▼     ▼
   Complete Failed
       │     │
       └──┬──┘
          ▼
    Refresh Device
```

The operation tabs remain available where the backend indicates that the operation is supported.

---

# 95. Initial Startup

Startup sequence:

```text
NSApplication launches
        ↓
Application delegate initialized
        ↓
Backend factory creates backend
        ↓
Storage manager initialized
        ↓
Device monitor initialized
        ↓
Main window controller created
        ↓
Initial device discovery
        ↓
Device browser populated
        ↓
First suitable device selected
        ↓
Information panel populated
```

Device discovery must not block the UI during startup.

---

# 96. Shutdown

On normal application termination:

1. Stop device monitoring.
2. Prevent new operations.
3. Request cancellation of cancellable operations.
4. Wait for safe termination where appropriate.
5. Close backend/helper connections.
6. Save preferences/window state.
7. Release controllers and services.

The application should not terminate abruptly while it has a privileged storage operation actively modifying a device.

---

# 97. Packaging

The application should install as a conventional GNUstep application bundle.

Conceptually:

```text
DiskUtility.app/
├── Resources/
├── DiskUtility
└── Libraries/
```

The exact bundle layout should follow GNUstep conventions for the target installation.

Do not hard-code:

```text
/usr/local/share/...
/opt/...
```

into application logic.

Resource discovery should use the application bundle/resource system.

---

# 98. Installation

Installation should support standard GNUstep deployment.

The build system should provide targets for:

```text
make
make install
make clean
make distclean
```

Packaging can subsequently provide native packages such as:

```text
.deb
.rpm
.txz
.pkg
```

without changing the application architecture.

---

# 99. Platform Packaging

Platform packaging belongs outside the core source tree where possible.

For example:

```text
Packaging/
├── Debian/
├── Fedora/
├── FreeBSD/
├── OpenBSD/
└── NetBSD/
```

Packaging files may install:

* Application bundle
* Privileged helper
* Desktop entry
* Icons
* MIME associations where appropriate
* Policy/authorization configuration

The source code should not contain distribution-specific installation logic.

---

# 100. Final Architectural Principle

The central rule is:

> **The application should be a GNUstep storage-management application with platform backends, not a platform-specific storage utility wrapped in a GNUstep GUI.**

The correct dependency structure is:

```text
                    ┌──────────────────────┐
                    │      GNUstep UI      │
                    │ AppKit / Controllers │
                    │ Views / Resources   │
                    └──────────┬───────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │ Application Services │
                    │ Operations / State   │
                    └──────────┬───────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │   Storage Domain     │
                    │ Models / Plans       │
                    └──────────┬───────────┘
                               │
                               ▼
                    ┌──────────────────────┐
                    │ Backend Abstraction  │
                    └──────────┬───────────┘
                               │
             ┌─────────────────┼─────────────────┐
             ▼                 ▼                 ▼
       ┌───────────┐     ┌───────────┐     ┌───────────┐
       │   Linux   │     │ FreeBSD   │     │ OpenBSD   │
       │  Backend  │     │  Backend  │     │  Backend  │
       └───────────┘     └───────────┘     └───────────┘
                               │
                               ▼
                         ┌───────────┐
                         │ NetBSD    │
                         │ Backend   │
                         └───────────┘
```

Every layer should be independently understandable and testable.

**AppKit owns presentation. Foundation owns application/domain primitives. Storage services own orchestration. Backends own operating-system integration. Privileged helpers own privileged execution.**

That separation is the architectural foundation required for a maintainable GNUstep application that behaves consistently across Linux and the BSD family.

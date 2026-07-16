# Status Item Architecture for Menu

> [!NOTE]
> This is a **discussion draft** reflecting the current implementation. Discussion is encouraged. Possibly this could evolve into a standard within GNUstep if there is sufficient interest in this. Suggestions are welcome.

## Overview

This document describes the extensible architecture for status items (similar to system tray icons) in the Menu application. Status items appear on the right side of the menu bar and provide system information and functionality.

## Design Goals

1. **Extensibility**: New status items can be added without modifying core Menu code
2. **Plugin Architecture**: Status items are loadable bundles, not separate processes
3. **Clean Separation**: Each status item is self-contained and independent
4. **Cross-Platform**: Works on both BSD and Linux systems
5. **Lightweight**: Minimal resource usage with efficient updates
6. **Consistent API**: All status items use the same protocol interface

## Architecture Components

### 1. StatusItemProvider Protocol

The core protocol that all status items must implement. Defines the contract for:
- Initialization and lifecycle management
- Visual representation (title, icon, menu)
- Update frequency and behavior
- Cleanup and resource management

### 2. StatusItemManager

Central manager within MenuController that:
- Discovers and loads status item bundles at startup
- Manages the lifecycle of all status items
- Positions status items in the menu bar
- Coordinates updates and events
- Provides shared resources (timers, display connection)

### 3. Status Item Bundles

Individual bundles implementing specific functionality:
- **SystemMonitor.bundle**: CPU and RAM usage monitoring
- **TimeDisplay.bundle**: Enhanced time/date display
- Future bundles: Network monitor, battery status, volume control, etc.

## Protocol Definition

```objectivec
@protocol StatusItemProvider <NSObject>

@required
// Unique identifier for this status item
- (NSString *)identifier;

// Display title (can be dynamic)
- (NSString *)title;

// Width in pixels needed for this item
- (CGFloat)width;

// Called when the status item is loaded
- (void)loadWithManager:(id)manager;

// Called to update the status item (on timer or event)
- (void)update;

// Called when item is clicked
- (void)handleClick;

@optional
// Menu to display on click (if nil, uses handleClick)
- (NSMenu *)menu;

// Icon to display (if nil, uses title)
- (NSImage *)icon;

// Update interval in seconds (default: 1.0)
- (NSTimeInterval)updateInterval;

// Called when unloading
- (void)unload;

@end
```

## Status Item Lifecycle

1. **Discovery**: At startup, StatusItemManager scans for .bundle files in:
   - `/System/Library/Menu/StatusItems/`
   - `~/Library/Menu/StatusItems/`
   - `Menu.app/Contents/Resources/StatusItems/`

2. **Loading**: For each bundle:
   - Load the bundle using NSBundle
   - Instantiate the principal class
   - Verify it implements StatusItemProvider protocol
   - Call `loadWithManager:` to initialize

3. **Positioning**: Items are positioned right-to-left:
   - Calculate total width needed
   - Position from right edge, leaving space for each item
   - Create NSMenuView for each item

4. **Updates**: Manager schedules timers based on each item's `updateInterval`:
   - Coalesce items with same interval to one timer
   - Call `update` method on each item
   - Item updates its title/icon/state

5. **Interaction**: When user clicks an item:
   - If item provides menu, display it
   - Otherwise call `handleClick` method

6. **Cleanup**: On shutdown:
   - Call `unload` on each item
   - Release resources
   - Unload bundles

## Implementation Details

### SystemMonitor Bundle

Provides CPU and RAM usage information:

**Features:**
- CPU percentage (0-100% per core, averaged)
- RAM percentage (used/total)
- Updates every second
- Cross-platform (BSD and Linux)
- Click shows detailed menu with per-core CPU info

**Platform-Specific Code:**
- Linux: Read `/proc/stat` for CPU, `/proc/meminfo` for RAM
- BSD: Use `sysctl` API for both CPU and RAM
- Compile-time detection using `#ifdef __linux__` / `#ifdef __FreeBSD__`

### TimeDisplay Bundle

Enhanced time and date display:

**Features:**
- Shows current time in HH:MM format
- On click, displays date for 5 seconds
- Returns to time display automatically
- Formatted date: "Day, Month D, YYYY"

**Implementation:**
- Maintains internal state (showing time vs. date)
- Uses NSTimer for auto-revert to time
- Elegant fade transition (optional)

## Bundle Structure

Each status item bundle contains:

```
StatusItemName.bundle/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   └── StatusItemName (shared library)
│   └── Resources/
│       └── (icons, images, etc.)
```

**Info.plist** must contain:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" 
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>StatusItemName</string>
    <key>CFBundleIdentifier</key>
    <string>org.gershwin.menu.statusitem.name</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>NSPrincipalClass</key>
    <string>StatusItemNameProvider</string>
</dict>
</plist>
```

## File Organization

```
Menu/
├── StatusItemProvider.h          # Protocol definition
├── StatusItemManager.h           # Manager class header
├── StatusItemManager.m           # Manager implementation
├── StatusItems/                  # Bundle sources
│   ├── SystemMonitor/
│   │   ├── GNUmakefile
│   │   ├── Info.plist
│   │   ├── SystemMonitorProvider.h
│   │   └── SystemMonitorProvider.m
│   └── TimeDisplay/
│       ├── GNUmakefile
│       ├── Info.plist
│       ├── TimeDisplayProvider.h
│       └── TimeDisplayProvider.m
└── GNUmakefile                   # Updated to build bundles
```

## Build System Integration

The main GNUmakefile compiles bundles as sub-projects:

```makefile
# After building the main app, build status item bundles
after-Menu-all::
	@echo "Building status item bundles..."
	cd StatusItems/SystemMonitor && $(MAKE)
	cd StatusItems/TimeDisplay && $(MAKE)
	@echo "Installing status item bundles..."
	mkdir -p $(GNUSTEP_SYSTEM_ROOT)/Library/Menu/StatusItems
	cp -r StatusItems/SystemMonitor/SystemMonitor.bundle \
	      $(GNUSTEP_SYSTEM_ROOT)/Library/Menu/StatusItems/
	cp -r StatusItems/TimeDisplay/TimeDisplay.bundle \
	      $(GNUSTEP_SYSTEM_ROOT)/Library/Menu/StatusItems/
```

Each bundle has its own GNUmakefile:

```makefile
include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = SystemMonitor
BUNDLE_EXTENSION = .bundle

SystemMonitor_PRINCIPAL_CLASS = SystemMonitorProvider
SystemMonitor_OBJC_FILES = SystemMonitorProvider.m
SystemMonitor_RESOURCE_FILES = Info.plist

include $(GNUSTEP_MAKEFILES)/bundle.make
```

## Performance Considerations

1. **Update Frequency**: Default 1 second, configurable per item
2. **Timer Coalescing**: Items with same interval share one timer
3. **Lazy Loading**: Bundles loaded on-demand, not all at startup (future)
4. **Efficient System Calls**: Cache file descriptors, minimize syscalls
5. **No Process Spawning**: All code runs in Menu process

## Security Considerations

1. **Bundle Signature**: Future - verify bundles are signed
2. **Sandboxing**: Limit bundle capabilities to prevent abuse
3. **Resource Limits**: Prevent runaway CPU/memory usage
4. **Safe Loading**: Handle corrupt bundles gracefully

## Future Extensions

Potential status items to add:
- Network activity (up/down speed)
- Battery level and charging status (laptops)
- Volume control with slider
- Bluetooth status
- WLAN connection info
- Notifications indicator
- Weather information
- Calendar events

## Migration Path

Current time menu will be replaced by:
1. Keep existing `createTimeMenu` temporarily
2. Implement new StatusItemManager
3. Create TimeDisplay bundle
4. Create SystemMonitor bundle
5. Load bundles in MenuController
6. Remove old time menu code
7. Deploy and test

## API Stability

The StatusItemProvider protocol is version 1.0. Changes will be:
- Backward compatible (add optional methods)
- Versioned if breaking changes needed
- Documented in release notes

## Example Usage

Creating a new status item:

```objectivec
// MyStatusItem.h
@interface MyStatusItemProvider : NSObject <StatusItemProvider>
@end

// MyStatusItem.m
@implementation MyStatusItemProvider

- (NSString *)identifier {
    return @"org.gershwin.menu.myitem";
}

- (NSString *)title {
    return @"🔔 3";  // Bell icon with count
}

- (CGFloat)width {
    return 50.0;
}

- (void)loadWithManager:(id)manager {
    // Initialize resources
    [self update];
}

- (void)update {
    // Update internal state
    // Refresh title/icon if changed
}

- (void)handleClick {
    // Handle user click
    NSLog(@"Item clicked!");
}

- (NSTimeInterval)updateInterval {
    return 5.0;  // Update every 5 seconds
}

@end
```
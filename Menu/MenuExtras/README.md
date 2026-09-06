# Menu Extras — Developer Guide

This directory contains standalone `.gsmenuextra` bundles loaded at runtime
by `MenuExtraManager`. Items appear on the right side of the menu bar.

## Protocol: `GSMenuExtra`

Every extra must conform to `GSMenuExtra` (`GSMenuExtra.h`).

### Required

```objc
- (NSString *)title;            // Displayed text
- (CGFloat)width;               // Cached pixel width
- (void)setManager:(MenuExtraManager *)manager;
```

### Optional

```objc
- (void)update;                 // Timer refresh
- (void)handleClick;            // Click handler
- (NSMenu *)menu;               // Dropdown menu
- (NSImage *)icon;              // 16x16 icon before title
- (void)unload;                 // Cleanup
- (NSInteger)displayPriority;   // Lower = more left (default: 100)
- (void)menuWillOpen;
- (void)menuDidClose;
```

### displayPriority

Lower values appear **leftmost**. Current assignments:

- Brightness: `10`, Sound: `20`, WLAN: `30`, Battery: `40`, Clock: `50`,
  BuildMonitor: `60`, Time: `70`

### Bundle Structure

```
MenuExtras/MyExtra/
├── GNUmakefile
├── Info.plist
├── MyExtra.h
├── MyExtra.m
└── MyExtra.gsmenuextra/ (built)
```

### GNUmakefile

```makefile
include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = MyExtra
BUNDLE_EXTENSION = .gsmenuextra
MyExtra_OBJC_FILES = MyExtra.m
MyExtra_HEADER_FILES = MyExtra.h
MyExtra_RESOURCE_FILES = Info.plist
MyExtra_PRINCIPAL_CLASS = MyExtra
MyExtra_INSTALL_DIR = /System/Library/MenuExtras

include $(GNUSTEP_MAKEFILES)/bundle.make
```

### Info.plist

```xml
<key>NSPrincipalClass</key>
<string>MyExtra</string>
```

Identifier is set by the bundle name, not from Info.plist.

## Available Extras

- **ClockExtra** — Time display
- **BatteryExtra** — Battery level and charging status
- **WLANExtra** — Wireless signal strength
- **SoundExtra** — Volume level
- **BrightnessExtra** — Display brightness
- **BuildMonitorExtra** — Build system monitor
- **TimeDisplay** — Digital clock (TimeExtra)

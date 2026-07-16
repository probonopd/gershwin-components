# Menu Status Items — Developer Guide

This directory contains status item providers for the Menu application.
Items appear on the right side of the menu bar, sorted by priority.

## Protocol: `StatusItemProvider`

Every status item must conform to `StatusItemProvider`
(`../StatusItemProvider.h`).

### Required Methods

```objc
- (NSString *)identifier;       // @"org.gershwin.menu.statusitem.myitem"
- (NSString *)title;            // Displayed text in menu bar
- (CGFloat)width;               // Pixel width (cache at load time)
- (void)loadWithManager:(id)manager;
```

### Optional Methods

```objc
- (void)update;                 // Called on timer tick to refresh state
- (void)handleClick;            // Called when menu item is clicked
- (NSMenu *)menu;               // Submenu shown on click
- (NSImage *)icon;              // 16×16 icon displayed before title
- (NSTimeInterval)updateInterval; // Seconds between updates (default: 1.0, min: 0.5)
- (void)unload;                 // Cleanup on shutdown
- (NSInteger)displayPriority;   // Lower = more left (default: 100)
- (void)menuWillOpen;           // Called before menu appears
- (void)menuDidClose;           // Called after menu dismissed
```

## Key Implementation Notes

### displayPriority
Lower values appear **leftmost** in the menu bar. Current values:
- CPU: `1`, RAM: `2`
- Brightness: `10`, Sound: `20`, WLAN: `30`, Battery: `40`, Clock: `50`
- Default for bundle-loaded items: `0`

### Fixed Width for Percentage Items
If your title contains `%`, the NSMenuItemCell category override ensures the
cell width matches `@"100%"` in the menu bar font. This prevents x-position
jitter when values change. Return a cached `width` computed from `@"100%"`
during `loadWithManager:`.

### Thread Safety
- All protocol methods are called on the **main thread only**.
- DO NOT use `dispatch_async` to a background queue from `tick`/`update`.
  This causes data races when `NSTask waitUntilExit` enters a nested run loop
  and re-enters the timer callback. Read from `/proc` or sysctl directly on
  the main thread; these calls are fast (microseconds).

### loadWithManager:
Set up timers and compute any cached widths here:

```objc
- (void)loadWithManager:(id)manager
{
    _detailMenu = [[NSMenu alloc] initWithTitle:@"MyItem"];
    NSFont *font = [NSFont menuBarFontOfSize:0];
    NSSize size = [@"100%" sizeWithAttributes:@{ NSFontAttributeName: font }];
    _cachedWidth = ceil(size.width) + 16.0;
    [self update];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                              target:self selector:@selector(tick)
                                            userInfo:nil repeats:YES];
}
```

### tick / update
Implement `tick` to refresh data and update the display. Everything must run
on the main thread:

```objc
- (void)tick
{
    [self refreshData];
}
```

### Icons
Return a `16×16` `NSImage`. The manager sizes the icon to 16×16 automatically.

## Example: Minimal Provider

```objc
// In StatusItemManager.m compiled-in fallback, or in a standalone bundle.

- (NSString *)identifier { return @"org.gershwin.menu.statusitem.myitem"; }
- (NSString *)title      { return _title; }
- (CGFloat)width         { return _cachedWidth; }

- (void)loadWithManager:(id)manager
{
    NSFont *font = [NSFont menuBarFontOfSize:0];
    NSSize size = [@"100%" sizeWithAttributes:@{ NSFontAttributeName: font }];
    _cachedWidth = ceil(size.width) + 16.0;
    _title = @"0%";
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                              target:self selector:@selector(tick)
                                            userInfo:nil repeats:YES];
}

- (void)tick
{
    _title = [NSString stringWithFormat:@"%d%%", [self fetchValue]];
}

- (NSImage *)icon { return [NSImage imageNamed:@"myicon"]; }
- (NSMenu *)menu  { return _detailMenu; }
- (NSInteger)displayPriority { return 5; }
```

## Available Providers

- **CPUProvider** — Per-core CPU usage (priority 1)
- **RAMProvider** — Memory usage (priority 2)
- **ClockExtra** — Time display
- **BatteryExtra** — Battery level and charging status
- **WLANExtra** — Wireless signal strength
- **SoundExtra** — Volume level
- **BrightnessExtra** — Display brightness

## Bundle Structure (standalone)

```
StatusItems/MyItem/
├── GNUmakefile
├── Info.plist
├── MyItemProvider.h
├── MyItemProvider.m
└── MyItem.bundle/ (built)
```

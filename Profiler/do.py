#!/usr/bin/env python3
from pathlib import Path
import zipfile

root = Path("/mnt/data/gnustep-profiler")
src = root / "Sources"
src.mkdir(parents=True, exist_ok=True)

files = {
"GNUmakefile": r'''#!/usr/bin/env make
include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = GNUstepProfiler
GNUSTEP_GUI = 1
GNUSTEP_BASE = 1

GNUSTEP_PROFILER_OBJC_FILES = \
    Sources/main.m \
    Sources/AppDelegate.m \
    Sources/ProfilerWindowController.m \
    Sources/ProcessInfo.m \
    Sources/ProcessMonitor.m \
    Sources/GraphView.m \
    Sources/HotspotTableController.m \
    Sources/ProfilerController.m

GNUSTEP_PROFILER_HEADERS = \
    Sources/AppDelegate.h \
    Sources/ProfilerWindowController.h \
    Sources/ProcessInfo.h \
    Sources/ProcessMonitor.h \
    Sources/GraphView.h \
    Sources/HotspotTableController.h \
    Sources/ProfilerController.h

GNUSTEP_PROFILER_RESOURCE_FILES =

ADDITIONAL_OBJCFLAGS = -Wall -Wextra -O2 -g -fno-omit-frame-pointer

include $(GNUSTEP_MAKEFILES)/application.make
''',

"Sources/main.m": r'''#!/usr/bin/env objc
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "AppDelegate.h"

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSApplication *app = [NSApplication sharedApplication];
    AppDelegate *delegate = [[AppDelegate alloc] init];
    [app setDelegate:delegate];
    [app run];
    [delegate release];
    [pool drain];
    return 0;
}
''',

"Sources/AppDelegate.h": r'''#!/usr/bin/env objc
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end
''',

"Sources/AppDelegate.m": r'''#!/usr/bin/env objc
#import "AppDelegate.h"
#import "ProfilerWindowController.h"

@implementation AppDelegate
{
    ProfilerWindowController *_windowController;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    _windowController = [[ProfilerWindowController alloc] init];
    [_windowController showWindow:self];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    (void)sender;
    return YES;
}

- (void)dealloc
{
    [_windowController release];
    [super dealloc];
}
@end
''',

"Sources/ProcessInfo.h": r'''#!/usr/bin/env objc
#import <Foundation/Foundation.h>

@interface ProcessInfo : NSObject
@property(nonatomic, assign) pid_t pid;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *command;
@property(nonatomic, assign) unsigned long long rssBytes;
@property(nonatomic, assign) unsigned long long virtualBytes;
@property(nonatomic, assign) double cpuPercent;
@end
''',

"Sources/ProcessInfo.m": r'''#!/usr/bin/env objc
#import "ProcessInfo.h"

@implementation ProcessInfo
@synthesize pid, name, command, rssBytes, virtualBytes, cpuPercent;

- (void)dealloc
{
    [_name release];
    [_command release];
    [super dealloc];
}
@end
''',

"Sources/ProcessMonitor.h": r'''#!/usr/bin/env objc
#import <Foundation/Foundation.h>

@class ProcessInfo;

@interface ProcessMonitor : NSObject
- (NSArray *)processes;
- (ProcessInfo *)sampleProcess:(pid_t)pid;
- (void)refreshProcessList;
@end
''',

"Sources/ProcessMonitor.m": r'''#!/usr/bin/env objc
#import "ProcessMonitor.h"
#import "ProcessInfo.h"

@implementation ProcessMonitor

- (NSArray *)processes
{
    NSMutableArray *result = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *entries = [fm contentsOfDirectoryAtPath:@"/proc" error:NULL];

    for (NSString *entry in entries) {
        NSScanner *scanner = [NSScanner scannerWithString:entry];
        int pidValue = 0;
        if (![scanner scanInt:&pidValue] || !scanner.isAtEnd || pidValue <= 0)
            continue;

        NSString *statusPath = [NSString stringWithFormat:@"/proc/%d/status", pidValue];
        NSString *status = [NSString stringWithContentsOfFile:statusPath
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
        if (!status)
            continue;

        NSString *name = nil;
        unsigned long long rss = 0, vm = 0;
        for (NSString *line in [status componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"Name:"])
                name = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
            else if ([line hasPrefix:@"VmRSS:"]) {
                NSScanner *s = [NSScanner scannerWithString:line];
                [s scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:NULL];
                unsigned long long kb = 0; [s scanUnsignedLongLong:&kb]; rss = kb * 1024ULL;
            } else if ([line hasPrefix:@"VmSize:"]) {
                NSScanner *s = [NSScanner scannerWithString:line];
                [s scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:NULL];
                unsigned long long kb = 0; [s scanUnsignedLongLong:&kb]; vm = kb * 1024ULL;
            }
        }

        ProcessInfo *info = [[[ProcessInfo alloc] init] autorelease];
        info.pid = (pid_t)pidValue;
        info.name = name ?: @"?";
        info.rssBytes = rss;
        info.virtualBytes = vm;
        info.command = [NSString stringWithContentsOfFile:
                        [NSString stringWithFormat:@"/proc/%d/cmdline", pidValue]
                        encoding:NSUTF8StringEncoding error:NULL] ?: info.name;
        [result addObject:info];
    }

    return [result sortedArrayUsingComparator:
            ^NSComparisonResult(ProcessInfo *a, ProcessInfo *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
}

- (void)refreshProcessList
{
    /* Kept intentionally small: the controller calls -processes when needed. */
}

- (ProcessInfo *)sampleProcess:(pid_t)pid
{
    NSString *statusPath = [NSString stringWithFormat:@"/proc/%d/status", pid];
    NSString *status = [NSString stringWithContentsOfFile:statusPath
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
    if (!status) return nil;

    ProcessInfo *info = [[[ProcessInfo alloc] init] autorelease];
    info.pid = pid;

    for (NSString *line in [status componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"Name:"])
            info.name = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
        else if ([line hasPrefix:@"VmRSS:"]) {
            NSScanner *s = [NSScanner scannerWithString:line];
            [s scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:NULL];
            unsigned long long kb = 0; [s scanUnsignedLongLong:&kb]; info.rssBytes = kb * 1024ULL;
        } else if ([line hasPrefix:@"VmSize:"]) {
            NSScanner *s = [NSScanner scannerWithString:line];
            [s scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:NULL];
            unsigned long long kb = 0; [s scanUnsignedLongLong:&kb]; info.virtualBytes = kb * 1024ULL;
        }
    }
    return info;
}
@end
''',

"Sources/GraphView.h": r'''#!/usr/bin/env objc
#import <AppKit/AppKit.h>

@interface GraphView : NSView
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *unit;
- (void)addValue:(double)value;
- (void)clear;
@end
''',

"Sources/GraphView.m": r'''#!/usr/bin/env objc
#import "GraphView.h"

@implementation GraphView
{
    NSMutableArray *_values;
}

@synthesize title = _title;
@synthesize unit = _unit;

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _values = [[NSMutableArray alloc] init];
        self.title = @"";
        self.unit = @"";
    }
    return self;
}

- (void)addValue:(double)value
{
    [_values addObject:[NSNumber numberWithDouble:value]];
    while ([_values count] > 180)
        [_values removeObjectAtIndex:0];
    [self setNeedsDisplay:YES];
}

- (void)clear
{
    [_values removeAllObjects];
    [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect
{
    [[NSColor controlBackgroundColor] setFill];
    NSRectFill(dirtyRect);

    NSDictionary *attrs = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:12] };
    [_title drawAtPoint:NSMakePoint(10, 8) withAttributes:attrs];

    NSRect r = NSInsetRect([self bounds], 10, 25);
    [[NSColor gridColor] setStroke];
    NSBezierPath *grid = [NSBezierPath bezierPath];
    for (int i = 0; i <= 4; i++) {
        CGFloat y = NSMinY(r) + NSHeight(r) * i / 4.0;
        [grid moveToPoint:NSMakePoint(NSMinX(r), y)];
        [grid lineToPoint:NSMakePoint(NSMaxX(r), y)];
    }
    [grid stroke];

    if ([_values count] < 2) return;

    double maxValue = 1.0;
    for (NSNumber *n in _values)
        maxValue = MAX(maxValue, [n doubleValue]);

    NSBezierPath *path = [NSBezierPath bezierPath];
    NSUInteger count = [_values count];
    for (NSUInteger i = 0; i < count; i++) {
        double v = [_values[i] doubleValue];
        CGFloat x = NSMinX(r) + NSWidth(r) * (double)i / (double)(count - 1);
        CGFloat y = NSMaxY(r) - NSHeight(r) * v / maxValue;
        if (i == 0) [path moveToPoint:NSMakePoint(x, y)];
        else [path lineToPoint:NSMakePoint(x, y)];
    }

    [[NSColor systemBlueColor] setStroke];
    [path setLineWidth:2.0];
    [path stroke];

    NSString *label = [NSString stringWithFormat:@"%.1f %@", maxValue, _unit ?: @""];
    [[NSFont systemFontOfSize:10] set];
    [label drawAtPoint:NSMakePoint(NSMaxX(r) - 90, NSMinY(r))
        withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:10]}];
}

- (void)dealloc
{
    [_values release];
    [_title release];
    [_unit release];
    [super dealloc];
}
@end
''',

"Sources/HotspotTableController.h": r'''#!/usr/bin/env objc
#import <AppKit/AppKit.h>

@interface HotspotTableController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
- (void)setRows:(NSArray *)rows;
- (void)configureTable:(NSTableView *)table;
@end
''',

"Sources/HotspotTableController.m": r'''#!/usr/bin/env objc
#import "HotspotTableController.h"

@implementation HotspotTableController
{
    NSArray *_rows;
}

- (void)setRows:(NSArray *)rows
{
    [_rows release];
    _rows = [rows copy];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    (void)tableView;
    return [_rows count];
}

- (id)tableView:(NSTableView *)tableView
 objectValueForTableColumn:(NSTableColumn *)column
            row:(NSInteger)row
{
    (void)tableView;
    NSDictionary *item = _rows[row];
    return item[column.identifier] ?: @"";
}

- (void)configureTable:(NSTableView *)table
{
    NSTableColumn *name = [[[NSTableColumn alloc] initWithIdentifier:@"name"] autorelease];
    [[name headerCell] setStringValue:@"Function / Method"];
    [name setWidth:360];

    NSTableColumn *percent = [[[NSTableColumn alloc] initWithIdentifier:@"percent"] autorelease];
    [[percent headerCell] setStringValue:@"Samples"];
    [percent setWidth:100];

    [table addTableColumn:name];
    [table addTableColumn:percent];
    table.dataSource = self;
    table.delegate = self;
}

- (void)dealloc
{
    [_rows release];
    [super dealloc];
}
@end
''',

"Sources/ProfilerController.h": r'''#!/usr/bin/env objc
#import <Foundation/Foundation.h>

@interface ProfilerController : NSObject
@property(nonatomic, readonly) BOOL running;
- (void)startPerfForExecutable:(NSString *)executable;
- (void)startHeaptrackForExecutable:(NSString *)executable;
- (void)stop;
@end
''',

"Sources/ProfilerController.m": r'''#!/usr/bin/env objc
#import "ProfilerController.h"

@implementation ProfilerController
{
    NSTask *_task;
    BOOL _running;
}

- (BOOL)running { return _running; }

- (void)startTaskWithLaunchPath:(NSString *)path
                      arguments:(NSArray *)arguments
{
    [self stop];

    _task = [[NSTask alloc] init];
    _task.launchPath = path;
    _task.arguments = arguments;

    NSPipe *pipe = [NSPipe pipe];
    _task.standardOutput = pipe;
    _task.standardError = pipe;

    @try {
        [_task launch];
        _running = YES;
    } @catch (NSException *e) {
        NSLog(@"Unable to launch %@: %@", path, e);
        [_task release];
        _task = nil;
    }
}

- (void)startPerfForExecutable:(NSString *)executable
{
    NSString *output = [NSTemporaryDirectory() stringByAppendingPathComponent:@"gnustep-profiler-perf.data"];
    [self startTaskWithLaunchPath:@"/usr/bin/perf"
                         arguments:@[@"record", @"-F", @"99",
                                     @"--call-graph", @"dwarf",
                                     @"-o", output, @"--", executable]];
}

- (void)startHeaptrackForExecutable:(NSString *)executable
{
    [self startTaskWithLaunchPath:@"/usr/bin/heaptrack"
                         arguments:@[executable]];
}

- (void)stop
{
    if (_task && [_task isRunning])
        [_task terminate];
    [_task release];
    _task = nil;
    _running = NO;
}

- (void)dealloc
{
    [self stop];
    [super dealloc];
}
@end
''',

"Sources/ProfilerWindowController.h": r'''#!/usr/bin/env objc
#import <AppKit/AppKit.h>

@interface ProfilerWindowController : NSWindowController
@end
''',

"Sources/ProfilerWindowController.m": r'''#!/usr/bin/env objc
#import "ProfilerWindowController.h"
#import "ProcessMonitor.h"
#import "ProcessInfo.h"
#import "GraphView.h"
#import "HotspotTableController.h"
#import "ProfilerController.h"

@implementation ProfilerWindowController
{
    NSTableView *_processTable;
    NSTableView *_hotspotTable;
    NSPopUpButton *_processPopup;
    NSTextField *_status;
    GraphView *_cpuGraph;
    GraphView *_ramGraph;
    HotspotTableController *_hotspotController;
    ProcessMonitor *_monitor;
    ProfilerController *_profiler;
    NSArray *_processes;
    NSTimer *_timer;
    pid_t _selectedPID;
}

- (id)init
{
    NSRect frame = NSMakeRect(0, 0, 1100, 760);
    NSWindow *window = [[[NSWindow alloc]
                         initWithContentRect:frame
                         styleMask:(NSWindowStyleMaskTitled |
                                    NSWindowStyleMaskClosable |
                                    NSWindowStyleMaskResizable)
                         backing:NSBackingStoreBuffered defer:NO] autorelease];

    self = [super initWithWindow:window];
    if (self) {
        _monitor = [[ProcessMonitor alloc] init];
        _profiler = [[ProfilerController alloc] init];
        _hotspotController = [[HotspotTableController alloc] init];

        [self buildUI];
        _timer = [[NSTimer scheduledTimerWithTimeInterval:1.0
                                                   target:self
                                                 selector:@selector(tick:)
                                                 userInfo:nil
                                                  repeats:YES] retain];
    }
    return self;
}

- (void)buildUI
{
    NSView *content = self.window.contentView;
    CGFloat w = NSWidth(content.bounds);

    NSTextField *title = [NSTextField labelWithString:@"GNUstep Performance Profiler"];
    title.font = [NSFont boldSystemFontOfSize:20];
    title.frame = NSMakeRect(20, 710, w - 40, 30);
    [content addSubview:title];

    _processPopup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 665, 360, 30)
                                               pullsDown:NO] autorelease];
    [_processPopup setTarget:self];
    [_processPopup setAction:@selector(processChanged:)];
    [content addSubview:_processPopup];

    NSButton *refresh = [NSButton buttonWithTitle:@"Refresh Processes"
                                           target:self
                                           action:@selector(refresh:)];
    refresh.frame = NSMakeRect(390, 665, 150, 30);
    [content addSubview:refresh];

    NSButton *perf = [NSButton buttonWithTitle:@"Record CPU (perf)"
                                        target:self
                                        action:@selector(startPerf:)];
    perf.frame = NSMakeRect(550, 665, 160, 30);
    [content addSubview:perf];

    NSButton *heap = [NSButton buttonWithTitle:@"Record RAM (heaptrack)"
                                        target:self
                                        action:@selector(startHeaptrack:)];
    heap.frame = NSMakeRect(720, 665, 180, 30);
    [content addSubview:heap];

    NSButton *stop = [NSButton buttonWithTitle:@"Stop"
                                        target:self
                                        action:@selector(stopProfiler:)];
    stop.frame = NSMakeRect(910, 665, 80, 30);
    [content addSubview:stop];

    _status = [NSTextField labelWithString:@"Ready"];
    _status.frame = NSMakeRect(20, 635, w - 40, 22);
    [content addSubview:_status];

    _cpuGraph = [[[GraphView alloc] initWithFrame:NSMakeRect(20, 420, (w-60)/2, 195)] autorelease];
    _cpuGraph.title = @"CPU usage";
    _cpuGraph.unit = @"%";
    [content addSubview:_cpuGraph];

    _ramGraph = [[[GraphView alloc] initWithFrame:NSMakeRect(40+(w-60)/2, 420, (w-60)/2, 195)] autorelease];
    _ramGraph.title = @"Resident memory";
    _ramGraph.unit = @"MB";
    [content addSubview:_ramGraph];

    NSTextField *hotTitle = [NSTextField labelWithString:@"CPU Hotspots"];
    hotTitle.font = [NSFont boldSystemFontOfSize:14];
    hotTitle.frame = NSMakeRect(20, 385, w - 40, 25);
    [content addSubview:hotTitle];

    NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(20, 80, w-40, 300)] autorelease];
    scroll.hasVerticalScroller = YES;
    _hotspotTable = [[[NSTableView alloc] initWithFrame:scroll.bounds] autorelease];
    [_hotspotController configureTable:_hotspotTable];
    scroll.documentView = _hotspotTable;
    [content addSubview:scroll];

    NSTextField *flame = [NSTextField labelWithString:
                          @"Flame graph: use the recorded perf.data with perf script + FlameGraph's stackcollapse-perf.pl/flamegraph.pl. A future version can embed the SVG directly."];
    flame.frame = NSMakeRect(20, 35, w-40, 35);
    flame.font = [NSFont systemFontOfSize:11];
    [content addSubview:flame];

    [self refresh:nil];
}

- (void)refresh:(id)sender
{
    (void)sender;
    [_processPopup removeAllItems];
    [_processes release];
    _processes = [[_monitor processes] retain];

    for (ProcessInfo *p in _processes) {
        NSString *label = [NSString stringWithFormat:@"%d  %@  (%.1f MB)",
                           p.pid, p.name, p.rssBytes / 1048576.0];
        [_processPopup addItemWithTitle:label];
        [[_processPopup lastItem] setRepresentedObject:p];
    }
    if ([_processes count])
        [self processChanged:nil];
}

- (void)processChanged:(id)sender
{
    (void)sender;
    ProcessInfo *p = [_processPopup selectedItem].representedObject;
    _selectedPID = p.pid;
    [_cpuGraph clear];
    [_ramGraph clear];
    _status.stringValue = [NSString stringWithFormat:@"Selected PID %d — %@", p.pid, p.name];
}

- (void)tick:(NSTimer *)timer
{
    (void)timer;
    if (_selectedPID <= 0) return;

    ProcessInfo *p = [_monitor sampleProcess:_selectedPID];
    if (!p) {
        _status.stringValue = @"Selected process exited.";
        return;
    }

    [_ramGraph addValue:p.rssBytes / 1048576.0];

    /* CPU sampling is intentionally left at zero until /proc stat deltas
       are implemented; perf remains the authoritative CPU profiler. */
    _status.stringValue = [NSString stringWithFormat:
                           @"PID %d — RSS %.1f MB — Virtual %.1f MB",
                           p.pid,
                           p.rssBytes / 1048576.0,
                           p.virtualBytes / 1048576.0];
}

- (void)startPerf:(id)sender
{
    (void)sender;
    ProcessInfo *p = [_processPopup selectedItem].representedObject;
    if (!p) {
        _status.stringValue = @"Select a process first.";
        return;
    }

    NSString *exe = [NSString stringWithFormat:@"/proc/%d/exe", p.pid];
    [_profiler startPerfForExecutable:exe];
    _status.stringValue = @"perf recording started. Reproduce the CPU problem, then press Stop.";
}

- (void)startHeaptrack:(id)sender
{
    (void)sender;
    ProcessInfo *p = [_processPopup selectedItem].representedObject;
    if (!p) {
        _status.stringValue = @"Select a process first.";
        return;
    }

    NSString *exe = [NSString stringWithFormat:@"/proc/%d/exe", p.pid];
    [_profiler startHeaptrackForExecutable:exe];
    _status.stringValue = @"heaptrack launched a new instance. Reproduce the memory problem there.";
}

- (void)stopProfiler:(id)sender
{
    (void)sender;
    [_profiler stop];
    _status.stringValue = @"Profiler stopped.";
}

- (void)dealloc
{
    [_timer invalidate];
    [_timer release];
    [_processes release];
    [_monitor release];
    [_profiler release];
    [_hotspotController release];
    [super dealloc];
}
@end
''',

"README.md": r'''# GNUstep Profiler

First native GNUstep/Objective-C prototype for profiling Linux GNUstep applications.

## Features

- Native GNUstep/AppKit window
- `/proc` process discovery
- process selection
- live RSS / virtual-memory graph
- CPU graph framework
- `perf record` integration
- Heaptrack integration
- CPU hotspot table framework
- flame-graph workflow documentation
- optimized debug build with symbols and frame pointers

## Build

Install the GNUstep development packages, GNUstep Make, and optionally `perf` and `heaptrack`.

Then:

```bash
make
openapp ./GNUstepProfiler.app

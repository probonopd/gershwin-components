/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ProfilerWindowController.h"
#import "ProcessMonitor.h"
#import "ProcessInfo.h"
#import "GraphView.h"
#import "HotspotTableController.h"
#import "ProfilerController.h"

@implementation ProfilerWindowController
{
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
    [window setTitle:@"Performance Profiler"];

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

    _processPopup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 665, 360, 30)
                                              pullsDown:NO] autorelease];
    [_processPopup setTarget:self];
    [_processPopup setAction:@selector(processChanged:)];
    [content addSubview:_processPopup];

    NSButton *refresh = [[NSButton alloc] initWithFrame:NSMakeRect(390, 665, 150, 30)];
    [refresh setTitle:@"Refresh Processes"];
    [refresh setTarget:self];
    [refresh setAction:@selector(refresh:)];
    [content addSubview:refresh];

    NSButton *perf = [[NSButton alloc] initWithFrame:NSMakeRect(550, 665, 160, 30)];
    [perf setTitle:@"Record CPU (perf)"];
    [perf setTarget:self];
    [perf setAction:@selector(startPerf:)];
    [content addSubview:perf];

    NSButton *heap = [[NSButton alloc] initWithFrame:NSMakeRect(720, 665, 180, 30)];
    [heap setTitle:@"Record RAM (heaptrack)"];
    [heap setTarget:self];
    [heap setAction:@selector(startHeaptrack:)];
    [content addSubview:heap];

    NSButton *stop = [[NSButton alloc] initWithFrame:NSMakeRect(910, 665, 80, 30)];
    [stop setTitle:@"Stop"];
    [stop setTarget:self];
    [stop setAction:@selector(stopProfiler:)];
    [content addSubview:stop];

    _status = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 635, w - 40, 22)] autorelease];
    _status.stringValue = @"Ready";
    _status.editable = NO;
    _status.bordered = NO;
    _status.backgroundColor = [NSColor clearColor];
    [content addSubview:_status];

    _cpuGraph = [[[GraphView alloc] initWithFrame:NSMakeRect(20, 420, (w-60)/2, 195)] autorelease];
    _cpuGraph.title = @"CPU usage";
    _cpuGraph.unit = @"%";
    [content addSubview:_cpuGraph];

    _ramGraph = [[[GraphView alloc] initWithFrame:NSMakeRect(40+(w-60)/2, 420, (w-60)/2, 195)] autorelease];
    _ramGraph.title = @"Resident memory";
    _ramGraph.unit = @"MB";
    [content addSubview:_ramGraph];

    NSTextField *hotTitle = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 385, w - 40, 25)] autorelease];
    hotTitle.stringValue = @"CPU Hotspots";
    hotTitle.font = [NSFont boldSystemFontOfSize:14];
    hotTitle.editable = NO;
    hotTitle.bordered = NO;
    hotTitle.backgroundColor = [NSColor clearColor];
    [content addSubview:hotTitle];

    NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(20, 80, w-40, 300)] autorelease];
    scroll.hasVerticalScroller = YES;
    _hotspotTable = [[[NSTableView alloc] initWithFrame:scroll.bounds] autorelease];
    [_hotspotController configureTable:_hotspotTable];
    scroll.documentView = _hotspotTable;
    [content addSubview:scroll];

    NSTextField *flame = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 35, w-40, 35)] autorelease];
    flame.stringValue = @"Flame graph: use the recorded perf.data with perf script + FlameGraph's stackcollapse-perf.pl/flamegraph.pl. A future version can embed the SVG directly.";
    flame.font = [NSFont systemFontOfSize:11];
    flame.editable = NO;
    flame.bordered = NO;
    flame.backgroundColor = [NSColor clearColor];
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

- (void)showAlertSheet:(NSString *)title message:(NSString *)message
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:title];
    [alert setInformativeText:message];
    [alert setAlertStyle:NSInformationalAlertStyle];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    [alert release];
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

    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/usr/bin/perf"]) {
        [self showAlertSheet:@"perf Not Installed"
                     message:@"Install perf to use CPU profiling."];
        return;
    }

    NSString *exe = nil;
#ifdef __Linux__
    exe = [NSString stringWithFormat:@"/proc/%d/exe", p.pid];
#else
    exe = p.command;
#endif

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

    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/usr/bin/heaptrack"]) {
        [self showAlertSheet:@"heaptrack Not Installed"
                     message:@"Install heaptrack to use memory profiling."];
        return;
    }

    [_profiler startHeaptrackForPID:p.pid];
    _status.stringValue = @"heaptrack recording started. Reproduce the memory problem, then press Stop.";
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

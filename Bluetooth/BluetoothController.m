/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "BluetoothController.h"
#import <dispatch/dispatch.h>

typedef NS_ENUM(NSInteger, BTOperation) {
    BTOperationIdle,
    BTOperationScanning,
    BTOperationPairing,
    BTOperationConnecting,
    BTOperationDisconnecting,
};

@interface BluetoothController ()
- (NSString *)runBluetoothctl:(NSString *)command timeout:(NSTimeInterval)timeout;
- (NSString *)runBluetoothctl:(NSString *)command;
- (BOOL)toolExists;
- (BOOL)bluetoothAvailable;
- (NSArray *)parseDeviceList;
- (NSDictionary *)parseDeviceInfo:(NSString *)address;
- (void)loadPairedDevices;
- (void)applyPower:(BOOL)on discoverable:(BOOL)disc;
- (void)updateDetailForDevice:(NSDictionary *)dev;
- (void)updateButtonStates;
- (void)setOperation:(BTOperation)op status:(NSString *)status;
- (void)updateStatus:(NSString *)message;
@property (assign) BTOperation currentOperation;
@end

@implementation BluetoothController

@synthesize currentOperation = _currentOperation;

- (id)init
{
    self = [super init];
    if (self) {
        isRefreshing = YES;
        _currentOperation = BTOperationIdle;
        pairedDevices = [[NSArray alloc] init];
        discoveredDevices = [[NSArray alloc] init];
        deviceInfoCache = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [mainView release];
    [powerCheckbox release];
    [discoverableCheckbox release];
    [devicesTable release];
    [devicesScrollView release];
    [pairedDevices release];
    [discoveredDevices release];
    [deviceInfoLabel release];
    [detailType release];
    [detailAddress release];
    [detailPaired release];
    [detailConnected release];
    [detailTrusted release];
    [pairButton release];
    [connectButton release];
    [disconnectButton release];
    [trustButton release];
    [removeButton release];
    [scanButton release];
    [scanSpinner release];
    [statusLabel release];
    [deviceInfoCache release];
    [super dealloc];
}

#pragma mark - Command Execution

- (NSString *)runBluetoothctl:(NSString *)command timeout:(NSTimeInterval)timeout
{
    if (![self toolExists]) {
        NSLog(@"Bluetooth: bluetoothctl not found");
        return nil;
    }
    NSDebugLLog(@"gwcomp", @"Bluetooth: run '%@' (timeout %.1fs)", command, timeout);
    /* Split command into separate arguments for bluetoothctl -- */
    NSMutableArray *args = [NSMutableArray arrayWithObject:@"--"];
    NSArray *parts = [command componentsSeparatedByString:@" "];
    for (NSString *p in parts) {
        if ([p length] > 0)
            [args addObject:p];
    }
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/bluetoothctl"];
    [task setArguments:args];
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    [task setStandardOutput:outPipe];
    [task setStandardError:errPipe];

    // Force C locale for consistent tool output
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"C" forKey:@"LC_ALL"];
    [task setEnvironment:env];
    [env release];

    [task launch];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_queue_t bg = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_async(bg, ^{
        [task waitUntilExit];
        dispatch_semaphore_signal(sem);
    });

    NSString *output = nil;
    long wait = dispatch_semaphore_wait(sem,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    if (wait != 0) {
        NSLog(@"Bluetooth: TIMEOUT after %.1fs for '%@'", timeout, command);
        [task terminate];
        [task waitUntilExit];
    } else {
        int exitCode = [task terminationStatus];
        NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
        output = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        output = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (exitCode != 0 && [command hasPrefix:@"pair"] == NO && [command hasPrefix:@"connect"] == NO)
            NSDebugLLog(@"gwcomp", @"Bluetooth: cmd='%@' exit=%d", command, exitCode);
    }
    dispatch_release(sem);
    [task release];
    if (!output) NSLog(@"Bluetooth: command '%@' returned no output", command);
    return output;
}

- (NSString *)runBluetoothctl:(NSString *)command
{
    return [self runBluetoothctl:command timeout:10.0];
}

- (BOOL)toolExists
{
    return [[NSFileManager defaultManager] isExecutableFileAtPath:@"/usr/bin/bluetoothctl"];
}

- (BOOL)bluetoothAvailable
{
#if !defined(__linux__)
    NSDebugLLog(@"gwcomp", @"Bluetooth: platform not supported");
    return NO;
#endif
    if (![self toolExists]) {
        NSDebugLLog(@"gwcomp", @"Bluetooth: tool not available");
        return NO;
    }
    NSString *out = [self runBluetoothctl:@"show" timeout:5.0];
    BOOL avail = (out != nil && [out rangeOfString:@"Controller"].location != NSNotFound);
    NSDebugLLog(@"gwcomp", @"Bluetooth: %@", avail ? @"adapter found" : @"no adapter");
    return avail;
}

#pragma mark - Device List Parsing

- (NSArray *)parseDeviceList
{
    NSString *out = [self runBluetoothctl:@"devices"];
    if (!out) return [NSArray array];
    NSMutableArray *devices = [NSMutableArray array];
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        NSScanner *scanner = [NSScanner scannerWithString:line];
        NSString *tmp = nil;
        [scanner scanString:@"Device" intoString:&tmp];
        if (!tmp) continue;
        NSString *addr = nil;
        [scanner scanUpToString:@" " intoString:&addr];
        if ([addr length] == 0) continue;
        [scanner scanCharactersFromSet:[NSCharacterSet whitespaceCharacterSet]
                           intoString:NULL];
        NSString *name = nil;
        if (![scanner isAtEnd])
            name = [[line substringFromIndex:[scanner scanLocation]]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (name == nil || [name length] == 0) name = addr;
        [devices addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                            addr, @"address", name, @"name", nil]];
    }
    return devices;
}

- (NSDictionary *)parseDeviceInfo:(NSString *)address
{
    if ([address length] == 0) return [NSDictionary dictionary];
    /* Check cache first */
    NSDictionary *cached = [deviceInfoCache objectForKey:address];
    if (cached) return cached;
    /* Fetch from bluetoothd */
    NSString *out = [self runBluetoothctl:[NSString stringWithFormat:@"info %@", address] timeout:8.0];
    if (!out) return [NSDictionary dictionary];
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        NSArray *parts = [trimmed componentsSeparatedByString:@": "];
        if ([parts count] >= 2) {
            NSString *key = [parts[0] stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
            NSString *val = [[parts subarrayWithRange:NSMakeRange(1, [parts count] - 1)]
                             componentsJoinedByString:@": "];
            val = [val stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceCharacterSet]];
            if ([key length] > 0)
                [info setObject:val forKey:key];
        }
    }
    [deviceInfoCache setObject:info forKey:address];
    return info;
}

- (void)cacheAllDeviceInfo
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSMutableArray *allAddrs = [NSMutableArray array];
        for (NSDictionary *d in pairedDevices)
            [allAddrs addObject:[d objectForKey:@"address"]];
        for (NSDictionary *d in discoveredDevices)
            [allAddrs addObject:[d objectForKey:@"address"]];
        for (NSString *addr in allAddrs) {
            if ([deviceInfoCache objectForKey:addr] == nil)
                [self parseDeviceInfo:addr];
        }
    });
}

- (void)loadPairedDevices
{
    NSArray *all = [self parseDeviceList];
    NSMutableArray *paired = [NSMutableArray array];
    NSMutableArray *pairedAddrs = [NSMutableArray array];
    for (NSDictionary *d in all) {
        NSString *addr = [d objectForKey:@"address"];
        NSDictionary *info = [self parseDeviceInfo:addr];
        NSString *pairedStr = [info objectForKey:@"Paired"];
        if (pairedStr && [pairedStr rangeOfString:@"yes" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [paired addObject:d];
            [pairedAddrs addObject:addr];
            NSDebugLLog(@"gwcomp", @"Bluetooth: paired device %@ (%@)", [d objectForKey:@"name"], addr);
            continue;
        }
        NSString *bonded = [info objectForKey:@"Bonded"];
        if (bonded && [bonded rangeOfString:@"yes" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [paired addObject:d];
            [pairedAddrs addObject:addr];
            NSDebugLLog(@"gwcomp", @"Bluetooth: bonded device %@ (%@)", [d objectForKey:@"name"], addr);
        }
    }
    /* Remove discovered devices that are now paired */
    NSMutableArray *filteredDiscovered = [NSMutableArray array];
    for (NSDictionary *d in discoveredDevices) {
        if (![pairedAddrs containsObject:[d objectForKey:@"address"]])
            [filteredDiscovered addObject:d];
    }
    [discoveredDevices release];
    discoveredDevices = [filteredDiscovered retain];

    NSDebugLLog(@"gwcomp", @"Bluetooth: %lu paired/bonded device(s)", (unsigned long)[paired count]);
    [pairedDevices release];
    pairedDevices = [paired retain];
}

#pragma mark - UI

- (NSView *)createMainView
{
    if (mainView) return mainView;

    if (![self bluetoothAvailable]) {
        mainView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 200)];
        NSString *msgText = [self toolExists]
            ? @"Bluetooth controller not found.\nEnsure your adapter is connected."
            : @"Bluetooth utility not found.\nInstall bluez package.";
        NSTextField *msg = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 80, 520, 40)];
        [msg setBezeled:NO];
        [msg setEditable:NO];
        [msg setSelectable:NO];
        [msg setDrawsBackground:NO];
        [msg setStringValue:msgText];
        [msg setAlignment:NSCenterTextAlignment];
        [msg setFont:[NSFont systemFontOfSize:13]];
        [msg setTextColor:[NSColor grayColor]];
        [mainView addSubview:msg];
        [msg release];
        return mainView;
    }

    mainView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 370)];
    CGFloat labelX = 18;
    CGFloat rowH = 22;
    CGFloat y = 348;

    /* Power toggle */
    powerCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX, y, 160, rowH)];
    [powerCheckbox setButtonType:NSSwitchButton];
    [powerCheckbox setTitle:@"On"];
    [powerCheckbox setFont:[NSFont boldSystemFontOfSize:12]];
    [powerCheckbox setTarget:self];
    [powerCheckbox setAction:@selector(settingChanged:)];
    [mainView addSubview:powerCheckbox];

    NSTextField *pwrLbl = [[NSTextField alloc] initWithFrame:NSMakeRect(100, y, 120, rowH)];
    [pwrLbl setBezeled:NO];
    [pwrLbl setEditable:NO];
    [pwrLbl setSelectable:NO];
    [pwrLbl setDrawsBackground:NO];
    [pwrLbl setStringValue:@"Bluetooth"];
    [pwrLbl setFont:[NSFont boldSystemFontOfSize:13]];
    [pwrLbl setTextColor:[NSColor blackColor]];
    [mainView addSubview:pwrLbl];
    [pwrLbl release];
    y -= 28;

    discoverableCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 28, y, 200, rowH)];
    [discoverableCheckbox setButtonType:NSSwitchButton];
    [discoverableCheckbox setTitle:@"Discoverable"];
    [discoverableCheckbox setFont:[NSFont systemFontOfSize:11]];
    [discoverableCheckbox setTarget:self];
    [discoverableCheckbox setAction:@selector(settingChanged:)];
    [mainView addSubview:discoverableCheckbox];
    y -= 8;

    NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(labelX, y, 524, 1)];
    [sep setBoxType:NSBoxSeparator];
    [mainView addSubview:sep];
    [sep release];
    y -= 14;

    /* Device list */
    CGFloat listW = 345;
    CGFloat listTop = y;
    CGFloat listBottom = 40;
    CGFloat listH = listTop - listBottom;

    devicesScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(labelX, listBottom, listW, listH)];
    [devicesScrollView setBorderType:NSBezelBorder];
    [devicesScrollView setHasVerticalScroller:YES];
    [devicesScrollView setAutohidesScrollers:YES];

    devicesTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, listW - 20, listH)];
    [devicesTable setRowHeight:rowH];
    [devicesTable setAllowsEmptySelection:YES];
    [devicesTable setAllowsMultipleSelection:NO];
    [devicesTable setDataSource:self];
    [devicesTable setDelegate:self];
    [devicesTable setHeaderView:nil];

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"device"];
    [col setWidth:listW - 25];
    [col setEditable:NO];
    [devicesTable addTableColumn:col];
    [col release];

    [devicesScrollView setDocumentView:devicesTable];
    [mainView addSubview:devicesScrollView];

    /* Buttons below list */
    CGFloat by = listBottom - 28;

    scanButton = [[NSButton alloc] initWithFrame:NSMakeRect(labelX, by, 75, 24)];
    [scanButton setTitle:@"Scan"];
    [scanButton setTarget:self];
    [scanButton setAction:@selector(startScan:)];
    [mainView addSubview:scanButton];

    scanSpinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(labelX + 78, by + 4, 16, 16)];
    [scanSpinner setStyle:NSProgressIndicatorSpinningStyle];
    [scanSpinner setDisplayedWhenStopped:NO];
    [scanSpinner setControlSize:NSSmallControlSize];
    [mainView addSubview:scanSpinner];

    removeButton = [[NSButton alloc] initWithFrame:NSMakeRect(labelX + 100, by, 75, 24)];
    [removeButton setTitle:@"Remove"];
    [removeButton setTarget:self];
    [removeButton setAction:@selector(removeDevice:)];
    [removeButton setEnabled:NO];
    [mainView addSubview:removeButton];

    /* Detail panel on the right */
    CGFloat detailX = labelX + listW + 14;
    CGFloat detailW = 560 - detailX - labelX;
    CGFloat dy = listTop - 18;

    deviceInfoLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(detailX, dy, detailW, rowH)];
    [deviceInfoLabel setBezeled:NO];
    [deviceInfoLabel setEditable:NO];
    [deviceInfoLabel setSelectable:NO];
    [deviceInfoLabel setDrawsBackground:NO];
    [deviceInfoLabel setFont:[NSFont boldSystemFontOfSize:12]];
    [deviceInfoLabel setStringValue:@"No device selected"];
    [mainView addSubview:deviceInfoLabel];
    dy -= 22;

    /* Detail fields */
    NSArray *keys = [NSArray arrayWithObjects:@"Type:", @"Address:", @"Paired:", @"Connected:", @"Trusted:", nil];
    NSTextField **vals[] = {&detailType, &detailAddress, &detailPaired, &detailConnected, &detailTrusted};

    for (NSUInteger i = 0; i < 5; i++) {
        NSTextField *kl = [[NSTextField alloc] initWithFrame:NSMakeRect(detailX, dy, 80, 16)];
        [kl setBezeled:NO];
        [kl setEditable:NO];
        [kl setSelectable:NO];
        [kl setDrawsBackground:NO];
        [kl setStringValue:[keys objectAtIndex:i]];
        [kl setFont:[NSFont systemFontOfSize:10]];
        [kl setTextColor:[NSColor grayColor]];
        [kl setAlignment:NSRightTextAlignment];
        [mainView addSubview:kl];
        [kl release];

        NSTextField *vl = [[NSTextField alloc] initWithFrame:NSMakeRect(detailX + 85, dy, detailW - 85, 16)];
        [vl setBezeled:NO];
        [vl setEditable:NO];
        [vl setSelectable:NO];
        [vl setDrawsBackground:NO];
        [vl setStringValue:@"-"];
        [vl setFont:[NSFont systemFontOfSize:10]];
        [mainView addSubview:vl];
        *vals[i] = vl;
        dy -= 18;
    }

    dy -= 6;

    pairButton = [[NSButton alloc] initWithFrame:NSMakeRect(detailX, dy, 70, 22)];
    [pairButton setTitle:@"Pair"];
    [pairButton setTarget:self];
    [pairButton setAction:@selector(pairDevice:)];
    [pairButton setEnabled:NO];
    [mainView addSubview:pairButton];

    connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(detailX + 75, dy, 75, 22)];
    [connectButton setTitle:@"Connect"];
    [connectButton setTarget:self];
    [connectButton setAction:@selector(connectDevice:)];
    [connectButton setEnabled:NO];
    [mainView addSubview:connectButton];

    disconnectButton = [[NSButton alloc] initWithFrame:NSMakeRect(detailX + 75, dy, 75, 22)];
    [disconnectButton setTitle:@"Disconnect"];
    [disconnectButton setTarget:self];
    [disconnectButton setAction:@selector(disconnectDevice:)];
    [disconnectButton setEnabled:NO];
    [mainView addSubview:disconnectButton];
    dy -= 24;

    trustButton = [[NSButton alloc] initWithFrame:NSMakeRect(detailX, dy, 70, 22)];
    [trustButton setTitle:@"Trust"];
    [trustButton setTarget:self];
    [trustButton setAction:@selector(trustDevice:)];
    [trustButton setEnabled:NO];
    [mainView addSubview:trustButton];

    /* Status bar */
    statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelX, 2, 524, 14)];
    [statusLabel setBezeled:NO];
    [statusLabel setEditable:NO];
    [statusLabel setSelectable:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setFont:[NSFont systemFontOfSize:9]];
    [statusLabel setTextColor:[NSColor grayColor]];
    [mainView addSubview:statusLabel];

    [self refreshFromSystem];
    return mainView;
}

#pragma mark - Refresh

- (void)refreshFromSystem
{
    NSDebugLLog(@"gwcomp", @"Bluetooth refreshFromSystem: start");
    isRefreshing = YES;

    NSString *show = [self runBluetoothctl:@"show" timeout:5.0];
    BOOL powered = (show != nil && [show rangeOfString:@"Powered: yes"].location != NSNotFound);
    BOOL discoverable = (show != nil && [show rangeOfString:@"Discoverable: yes"].location != NSNotFound);
    NSDebugLLog(@"gwcomp", @"Bluetooth: state: powered=%d discoverable=%d", powered, discoverable);

    [powerCheckbox setState:powered ? NSOnState : NSOffState];
    [discoverableCheckbox setState:discoverable ? NSOnState : NSOffState];

    if (!powered) {
        [pairedDevices release];
        pairedDevices = [[NSArray alloc] init];
        [discoveredDevices release];
        discoveredDevices = [[NSArray alloc] init];
        [devicesTable reloadData];
        [self updateDetailForDevice:nil];
        [self updateButtonStates];
        isRefreshing = NO;
        [self updateStatus:@"Bluetooth off"];
        return;
    }

    [self loadPairedDevices];
    [self cacheAllDeviceInfo];
    [devicesTable reloadData];
    [self updateDetailForDevice:nil];
    [self updateButtonStates];

    isRefreshing = NO;
    [self updateStatus:@"Ready"];
    NSDebugLLog(@"gwcomp", @"Bluetooth refreshFromSystem: done");
}

- (void)pollDevices
{
    if (self.currentOperation != BTOperationIdle) {
        NSDebugLLog(@"gwcomp", @"Bluetooth pollDevices: skip (operation %ld active)", (long)self.currentOperation);
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSString *show = [self runBluetoothctl:@"show" timeout:5.0];
        BOOL powered = (show != nil && [show rangeOfString:@"Powered: yes"].location != NSNotFound);
        BOOL discoverable = (show != nil && [show rangeOfString:@"Discoverable: yes"].location != NSNotFound);
        [self loadPairedDevices];
        [self cacheAllDeviceInfo];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (isRefreshing || self.currentOperation != BTOperationIdle) return;
            if (([powerCheckbox state] == NSOnState) != powered)
                [powerCheckbox setState:powered ? NSOnState : NSOffState];
            if (([discoverableCheckbox state] == NSOnState) != discoverable)
                [discoverableCheckbox setState:discoverable ? NSOnState : NSOffState];
            [discoverableCheckbox setEnabled:powered];
            [scanButton setEnabled:powered];
            [devicesTable reloadData];
        });
    });
}

#pragma mark - Detail & Button State

- (void)updateDetailForDevice:(NSDictionary *)dev
{
    if (!dev) {
        [deviceInfoLabel setStringValue:@"No device selected"];
        [detailType setStringValue:@"-"];
        [detailAddress setStringValue:@"-"];
        [detailPaired setStringValue:@"-"];
        [detailConnected setStringValue:@"-"];
        [detailTrusted setStringValue:@"-"];
        return;
    }
    NSString *addr = [dev objectForKey:@"address"];
    NSString *name = [dev objectForKey:@"name"];
    NSDictionary *info = [self parseDeviceInfo:addr];
    [deviceInfoLabel setStringValue:([name length] > 0) ? name : addr];
    [detailType setStringValue:[self _typeLabelForInfo:info]];
    [detailAddress setStringValue:addr ?: @"-"];
    [detailPaired setStringValue:[info objectForKey:@"Paired"] ?: @"no"];
    [detailConnected setStringValue:[info objectForKey:@"Connected"] ?: @"no"];
    [detailTrusted setStringValue:[info objectForKey:@"Trusted"] ?: @"no"];

    BOOL scanning = (self.currentOperation == BTOperationScanning);
    /* For unpaired discovered devices, show Pair button even when not scanning */
    BOOL idle = (self.currentOperation == BTOperationIdle);
    NSInteger row = [devicesTable selectedRow];
    BOOL isDiscovered = (idle && row >= 0 && (NSUInteger)row >= [pairedDevices count]);

    [pairButton setHidden:!(scanning || isDiscovered)];
    [connectButton setHidden:(scanning || isDiscovered)];
    [disconnectButton setHidden:(scanning || isDiscovered)];
    [trustButton setHidden:(scanning || isDiscovered)];
}

- (void)setUIEnabled:(BOOL)enabled
{
    [powerCheckbox setEnabled:YES]; /* always enabled */
    [discoverableCheckbox setEnabled:enabled];
    [devicesTable setEnabled:enabled];
    [scanButton setEnabled:enabled];
    [removeButton setEnabled:NO];
    [pairButton setEnabled:NO];
    [connectButton setEnabled:NO];
    [disconnectButton setEnabled:NO];
    [trustButton setEnabled:NO];
}

- (void)updateButtonStates
{
    NSDictionary *dev = [self selectedDevice];
    BOOL hasDev = (dev != nil);
    BOOL idle = (self.currentOperation == BTOperationIdle);
    BOOL scanning = (self.currentOperation == BTOperationScanning);
    BOOL powered = ([powerCheckbox state] == NSOnState);

    if (!powered) {
        [self setUIEnabled:NO];
        return;
    }
    [devicesTable setEnabled:YES];
    [discoverableCheckbox setEnabled:YES];
    [scanButton setEnabled:idle];
    [removeButton setEnabled:(hasDev && idle)];

    if (hasDev && idle) {
        NSInteger row = [devicesTable selectedRow];
        BOOL isDiscovered = (row >= 0 && (NSUInteger)row >= [pairedDevices count]);
        [pairButton setHidden:!isDiscovered];
        [pairButton setEnabled:isDiscovered];
    } else {
        [pairButton setHidden:!scanning];
        [pairButton setEnabled:(hasDev && scanning)];
    }

    if (!hasDev || !idle) {
        [connectButton setEnabled:NO];
        [disconnectButton setEnabled:NO];
        [trustButton setEnabled:NO];
        return;
    }

    NSString *addr = [dev objectForKey:@"address"];
    NSDictionary *info = [self parseDeviceInfo:addr];
    BOOL isConnected = ([[info objectForKey:@"Connected"] rangeOfString:@"yes" options:NSCaseInsensitiveSearch].location != NSNotFound);
    BOOL isTrusted = ([[info objectForKey:@"Trusted"] rangeOfString:@"yes" options:NSCaseInsensitiveSearch].location != NSNotFound);

    [connectButton setEnabled:!isConnected];
    [disconnectButton setEnabled:isConnected];
    [trustButton setTitle:isTrusted ? @"Untrust" : @"Trust"];
    [trustButton setEnabled:YES];
}

- (NSDictionary *)selectedDevice
{
    NSInteger row = [devicesTable selectedRow];
    if (row < 0) return nil;
    if (self.currentOperation == BTOperationScanning) {
        if ((NSUInteger)row < [discoveredDevices count])
            return [discoveredDevices objectAtIndex:row];
        return nil;
    }
    NSUInteger urow = (NSUInteger)row;
    if (urow < [pairedDevices count])
        return [pairedDevices objectAtIndex:urow];
    urow -= [pairedDevices count];
    if (urow < [discoveredDevices count])
        return [discoveredDevices objectAtIndex:urow];
    return nil;
}

#pragma mark - Power / Discoverable

- (IBAction)settingChanged:(id)sender
{
    (void)sender;
    if (isRefreshing) return;
    if (self.currentOperation != BTOperationIdle) {
        NSDebugLLog(@"gwcomp", @"Bluetooth: settingChanged blocked (op %ld)", (long)self.currentOperation);
        [self updateStatus:@"Please wait for current operation to complete"];
        return;
    }
    BOOL powerOn = ([powerCheckbox state] == NSOnState);
    BOOL discOn = ([discoverableCheckbox state] == NSOnState);
    NSDebugLLog(@"gwcomp", @"Bluetooth: setting power=%d discoverable=%d", powerOn, discOn);
    self.currentOperation = BTOperationPairing; /* reuse as generic "busy" */
    [self updateStatus:powerOn ? @"Powering on..." : @"Powering off..."];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self applyPower:powerOn discoverable:discOn];
        /* Wait for state to settle — poll up to 5s */
        BOOL actualPower = !powerOn;
        BOOL actualDisc = discOn;
        for (int i = 0; i < 10; i++) {
            [NSThread sleepForTimeInterval:0.5];
            NSString *show = [self runBluetoothctl:@"show" timeout:5.0];
            actualPower = (show != nil && [show rangeOfString:@"Powered: yes"].location != NSNotFound);
            actualDisc = (show != nil && [show rangeOfString:@"Discoverable: yes"].location != NSNotFound);
            if (actualPower == powerOn) break;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"Bluetooth: power state now: powered=%d discoverable=%d (requested: power=%d disc=%d)",
                  actualPower, actualDisc, powerOn, discOn);
            isRefreshing = YES;
            [powerCheckbox setState:actualPower ? NSOnState : NSOffState];
            [discoverableCheckbox setState:actualDisc ? NSOnState : NSOffState];
            isRefreshing = NO;
            self.currentOperation = BTOperationIdle;
            if (!actualPower) {
                /* Clear device lists when powered off */
                [pairedDevices release];
                pairedDevices = [[NSArray alloc] init];
                [discoveredDevices release];
                discoveredDevices = [[NSArray alloc] init];
                [devicesTable reloadData];
                [self updateDetailForDevice:nil];
                [self updateStatus:@"Bluetooth off"];
            } else {
                [self refreshFromSystem];
            }
            [self updateButtonStates];
        });
    });
}

- (void)applyPower:(BOOL)on discoverable:(BOOL)disc
{
    [self runBluetoothctl:on ? @"power on" : @"power off" timeout:10.0];
    if (on) {
        [self runBluetoothctl:disc ? @"discoverable on" : @"discoverable off" timeout:5.0];
    }
}

#pragma mark - Operations

- (void)setOperation:(BTOperation)op status:(NSString *)status
{
    self.currentOperation = op;
    [self updateButtonStates];
    if (status) [self updateStatus:status];
}

- (BOOL)beginOperation:(BTOperation)op status:(NSString *)status
{
    if (self.currentOperation != BTOperationIdle) {
        [self updateStatus:@"Another operation is in progress"];
        return NO;
    }
    self.currentOperation = op;
    [self updateStatus:status ?: @"Working..."];
    [self updateButtonStates];
    return YES;
}

- (void)endOperationWithStatus:(NSString *)status
{
    NSDebugLLog(@"gwcomp", @"Bluetooth: operation ended: %@", status);
    self.currentOperation = BTOperationIdle;
    [self updateStatus:status ?: @"Ready"];
    [self updateButtonStates];
    /* Free discovered devices 30s after scan ends so user can still pair */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30LL * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (self.currentOperation == BTOperationIdle) {
            NSDebugLLog(@"gwcomp", @"Bluetooth: freeing discovered devices list");
            [discoveredDevices release];
            discoveredDevices = [[NSArray alloc] init];
            [devicesTable reloadData];
        }
    });
    [devicesTable reloadData];
}

- (void)endOperationWithError:(NSString *)error
{
    NSLog(@"Bluetooth: OPERATION FAILED: %@", error);
    self.currentOperation = BTOperationIdle;
    [self updateStatus:error ?: @"Failed"];
    [self updateButtonStates];
}

#pragma mark - Actions

- (NSString *)promptForPIN:(NSString *)deviceName
{
    __block NSString *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        /* Build a simple PIN entry panel */
        NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 320, 140)
                                                   styleMask:NSTitledWindowMask | NSClosableWindowMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
        [panel setTitle:[NSString stringWithFormat:@"Pair with %@", deviceName ?: @"Device"]];
        [panel center];

        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 95, 280, 20)];
        [label setBezeled:NO];
        [label setEditable:NO];
        [label setSelectable:NO];
        [label setDrawsBackground:NO];
        [label setStringValue:@"Enter the PIN shown on the device:"];
        [label setFont:[NSFont systemFontOfSize:12]];
        [[panel contentView] addSubview:label];
        [label release];

        NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 55, 280, 24)];
        [input setPlaceholderString:@"PIN code"];
        [[panel contentView] addSubview:input];

        NSButton *okButton = [[NSButton alloc] initWithFrame:NSMakeRect(130, 10, 80, 28)];
        [okButton setTitle:@"Pair"];
        [okButton setBezelStyle:NSRoundedBezelStyle];
        [okButton setKeyEquivalent:@"\r"];
        [okButton setTarget:NSApp];
        [okButton setAction:@selector(stopModalWithCode:)];
        [okButton setTag:NSModalResponseOK];
        [[panel contentView] addSubview:okButton];

        NSButton *cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(215, 10, 80, 28)];
        [cancelButton setTitle:@"Cancel"];
        [cancelButton setBezelStyle:NSRoundedBezelStyle];
        [cancelButton setTarget:NSApp];
        [cancelButton setAction:@selector(stopModalWithCode:)];
        [cancelButton setTag:NSModalResponseCancel];
        [[panel contentView] addSubview:cancelButton];

        [panel setInitialFirstResponder:input];
        NSInteger code = [NSApp runModalForWindow:panel];
        [panel orderOut:nil];

        if (code == NSModalResponseOK) {
            result = [[input stringValue] copy];
        }
        [input release];
        [okButton release];
        [cancelButton release];
        [panel release];
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    dispatch_release(sem);
    return [result autorelease];
}

- (IBAction)pairDevice:(id)sender
{
    (void)sender;
    NSDictionary *dev = [self selectedDevice];
    if (!dev) return;

    NSString *addr = [dev objectForKey:@"address"];
    NSString *name = [dev objectForKey:@"name"];
    NSLog(@"Bluetooth: user initiated PAIR with %@ (%@)", name, addr);
    if (![self beginOperation:BTOperationPairing status:[NSString stringWithFormat:@"Pairing with %@...", addr]])
        return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        /* Three attempts: Just Works, Confirm, then ask for PIN */
        BOOL ok = NO;
        int strategy;

        for (strategy = 0; strategy < 3 && !ok; strategy++) {
            NSTask *task = [[NSTask alloc] init];
            [task setLaunchPath:@"/usr/bin/bluetoothctl"];
            NSPipe *inPipe = [NSPipe pipe];
            NSPipe *outPipe = [NSPipe pipe];
            [task setStandardInput:inPipe];
            [task setStandardOutput:outPipe];
            [task setStandardError:[NSPipe pipe]];
            [task launch];

            NSFileHandle *inWrite = [inPipe fileHandleForWriting];

            if (strategy == 0) {
                [inWrite writeData:[@"agent NoInputNoOutput\n" dataUsingEncoding:NSUTF8StringEncoding]];
                [NSThread sleepForTimeInterval:0.3];
                [inWrite writeData:[[NSString stringWithFormat:@"pair %@\n", addr] dataUsingEncoding:NSUTF8StringEncoding]];
                [NSThread sleepForTimeInterval:5.0];
            } else if (strategy == 1) {
                [inWrite writeData:[@"agent DisplayYesNo\n" dataUsingEncoding:NSUTF8StringEncoding]];
                [NSThread sleepForTimeInterval:0.3];
                [inWrite writeData:[[NSString stringWithFormat:@"pair %@\n", addr] dataUsingEncoding:NSUTF8StringEncoding]];
                [NSThread sleepForTimeInterval:3.0];
                [inWrite writeData:[@"yes\n" dataUsingEncoding:NSUTF8StringEncoding]];
                [NSThread sleepForTimeInterval:2.0];
            } else {
                /* Ask user for PIN via dialog */
                NSString *pin = [self promptForPIN:name];
                if ([pin length] == 0) break;

                [inWrite writeData:[@"agent KeyboardDisplay\n" dataUsingEncoding:NSUTF8StringEncoding]];
                [NSThread sleepForTimeInterval:0.3];
                [inWrite writeData:[[NSString stringWithFormat:@"pair %@\n", addr] dataUsingEncoding:NSUTF8StringEncoding]];
                [NSThread sleepForTimeInterval:3.0];
                [inWrite writeData:[[NSString stringWithFormat:@"%@\n", pin] dataUsingEncoding:NSUTF8StringEncoding]];
                [NSThread sleepForTimeInterval:1.0];
                [inWrite writeData:[@"yes\n" dataUsingEncoding:NSUTF8StringEncoding]];
                [NSThread sleepForTimeInterval:1.0];
            }

            [inWrite writeData:[[NSString stringWithFormat:@"trust %@\n", addr] dataUsingEncoding:NSUTF8StringEncoding]];
            [NSThread sleepForTimeInterval:0.3];
            [inWrite writeData:[@"quit\n" dataUsingEncoding:NSUTF8StringEncoding]];
            [inWrite closeFile];

            NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
            [task waitUntilExit];
            [task release];

            NSString *output = [[[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] autorelease];
            ok = (output != nil &&
                  [output rangeOfString:@"Failed" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                  [output rangeOfString:@"Error" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                  [output rangeOfString:@"Invalid" options:NSCaseInsensitiveSearch].location == NSNotFound);
            NSLog(@"Bluetooth: pair strategy %d %s", strategy, ok ? "OK" : "FAIL");
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                NSLog(@"Bluetooth: paired successfully with %@ (%@)", name, addr);
                [self endOperationWithStatus:@"Paired successfully"];
                self.currentOperation = BTOperationIdle;
                [self refreshFromSystem];
            } else {
                NSLog(@"Bluetooth: PAIRING FAILED for %@ (%@)", name, addr);
                [self endOperationWithError:@"Pairing failed"];
            }
        });
    });
}

- (IBAction)connectDevice:(id)sender
{
    (void)sender;
    NSDictionary *dev = [self selectedDevice];
    if (!dev) return;

    NSString *addr = [dev objectForKey:@"address"];
    NSString *name = [dev objectForKey:@"name"];
    NSLog(@"Bluetooth: user initiated CONNECT to %@ (%@)", name, addr);
    if (![self beginOperation:BTOperationConnecting status:[NSString stringWithFormat:@"Connecting to %@...", addr]])
        return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *result = [self runBluetoothctl:[NSString stringWithFormat:@"connect %@", addr] timeout:30.0];
        BOOL ok = (result != nil && [result rangeOfString:@"Failed" options:NSCaseInsensitiveSearch].location == NSNotFound
                   && [result rangeOfString:@"Unable" options:NSCaseInsensitiveSearch].location == NSNotFound);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                NSLog(@"Bluetooth: connected to %@ (%@)", name, addr);
                [self endOperationWithStatus:@"Connected"];
            } else {
                NSLog(@"Bluetooth: CONNECTION FAILED to %@ (%@) — %@", name, addr, result ?: @"no output");
                [self endOperationWithError:@"Connection failed"];
            }
        });
    });
}

- (IBAction)disconnectDevice:(id)sender
{
    (void)sender;
    NSDictionary *dev = [self selectedDevice];
    if (!dev) return;

    NSString *addr = [dev objectForKey:@"address"];
    NSString *name = [dev objectForKey:@"name"];
    NSLog(@"Bluetooth: user initiated DISCONNECT from %@ (%@)", name, addr);
    if (![self beginOperation:BTOperationDisconnecting status:[NSString stringWithFormat:@"Disconnecting %@...", addr]])
        return;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self runBluetoothctl:[NSString stringWithFormat:@"disconnect %@", addr] timeout:10.0];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"Bluetooth: disconnected from %@ (%@)", name, addr);
            [self endOperationWithStatus:@"Disconnected"];
        });
    });
}

- (IBAction)trustDevice:(id)sender
{
    (void)sender;
    NSDictionary *dev = [self selectedDevice];
    if (!dev || self.currentOperation != BTOperationIdle) return;

    NSString *addr = [dev objectForKey:@"address"];
    NSString *name = [dev objectForKey:@"name"];
    NSDictionary *info = [self parseDeviceInfo:addr];
    BOOL trusted = ([[info objectForKey:@"Trusted"] rangeOfString:@"yes" options:NSCaseInsensitiveSearch].location != NSNotFound);
    NSLog(@"Bluetooth: user initiated %@ %@ (%@)", trusted ? @"UNTRUST" : @"TRUST", name, addr);

    [self updateStatus:trusted ? @"Untrusting..." : @"Trusting..."];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self runBluetoothctl:trusted ? [NSString stringWithFormat:@"untrust %@", addr] : [NSString stringWithFormat:@"trust %@", addr] timeout:5.0];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDebugLLog(@"gwcomp", @"Bluetooth: %@ %@", trusted ? @"untrusted" : @"trusted", addr);
            [self updateDetailForDevice:[self selectedDevice]];
            [self updateButtonStates];
            [self updateStatus:trusted ? @"Untrusted" : @"Trusted"];
        });
    });
}

- (IBAction)removeDevice:(id)sender
{
    (void)sender;
    NSDictionary *dev = [self selectedDevice];
    if (!dev || self.currentOperation != BTOperationIdle) return;

    NSString *addr = [dev objectForKey:@"address"];
    NSString *name = [dev objectForKey:@"name"];
    NSLog(@"Bluetooth: user initiated REMOVE of %@ (%@)", name, addr);
    [self updateStatus:[NSString stringWithFormat:@"Removing %@...", addr]];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self runBluetoothctl:[NSString stringWithFormat:@"remove %@", addr] timeout:10.0];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"Bluetooth: removed %@ (%@)", name, addr);
            [self refreshFromSystem];
        });
    });
}

- (IBAction)startScan:(id)sender
{
    (void)sender;
    if (self.currentOperation != BTOperationIdle) {
        NSDebugLLog(@"gwcomp", @"Bluetooth: scan blocked (op %ld)", (long)self.currentOperation);
        [self updateStatus:@"Please wait for current operation to complete"];
        return;
    }
    NSLog(@"Bluetooth: starting scan for 12 seconds");
    self.currentOperation = BTOperationScanning;
    [scanButton setEnabled:NO];
    [scanSpinner startAnimation:nil];
    [discoveredDevices release];
    discoveredDevices = [[NSArray alloc] init];
    [devicesTable reloadData];
    [self updateButtonStates];
    [self updateDetailForDevice:nil];
    [self updateStatus:@"Scanning for 12 seconds..."];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        /* Use interactive bluetoothctl with stdin pipe to keep D-Bus alive during scan */
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:@"/usr/bin/bluetoothctl"];
        NSPipe *inPipe = [NSPipe pipe];
        NSPipe *outPipe = [NSPipe pipe];
        [task setStandardInput:inPipe];
        [task setStandardOutput:outPipe];
        [task setStandardError:[NSPipe pipe]];
        [task launch];

        /* Send scan command, wait 12s, then stop */
        NSFileHandle *inWrite = [inPipe fileHandleForWriting];
        [inWrite writeData:[@"scan on\n" dataUsingEncoding:NSUTF8StringEncoding]];
        NSDebugLLog(@"gwcomp", @"Bluetooth: scan: scan on sent, waiting 12s...");
        [NSThread sleepForTimeInterval:12.0];
        [inWrite writeData:[@"devices\nscan off\nquit\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [inWrite closeFile];

        /* Read all output */
        NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
        [task release];

        /* Parse output for devices */
        NSString *output = [[[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] autorelease];
        NSDebugLLog(@"gwcomp", @"Bluetooth: scan raw output (%.2000s)", [output UTF8String]);

        /* Strip ANSI escape codes and parse Device lines */
        NSMutableString *clean = [NSMutableString stringWithString:output ?: @""];
        NSRange r;
        while ((r = [clean rangeOfString:@"\033[" options:NSLiteralSearch]).location != NSNotFound) {
            NSRange end = [clean rangeOfString:@"m" options:NSLiteralSearch
                                        range:NSMakeRange(r.location, [clean length] - r.location)];
            if (end.location != NSNotFound)
                [clean deleteCharactersInRange:NSMakeRange(r.location, end.location - r.location + 1)];
            else
                break;
        }
        /* Also strip cursor movement escapes like [19P, [K */
        while ((r = [clean rangeOfString:@"\033[" options:NSLiteralSearch]).location != NSNotFound) {
            NSRange end = [clean rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]
                                                 options:NSLiteralSearch
                                                   range:NSMakeRange(r.location, [clean length] - r.location)];
            if (end.location != NSNotFound)
                [clean deleteCharactersInRange:NSMakeRange(r.location, end.location - r.location + 1)];
            else
                break;
        }

        /* Parse all known devices from output */
        NSMutableArray *found = [NSMutableArray array];
        for (NSString *line in [clean componentsSeparatedByString:@"\n"]) {
            NSScanner *sc = [NSScanner scannerWithString:line];
            NSString *deviceTag = nil;
            [sc scanString:@"Device" intoString:&deviceTag];
            if (!deviceTag) continue;
            NSString *addr = nil;
            [sc scanUpToString:@" " intoString:&addr];
            if ([addr length] == 0) continue;
            [sc scanCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:NULL];
            NSString *name = nil;
            if (![sc isAtEnd])
                name = [[line substringFromIndex:[sc scanLocation]]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (name == nil || [name length] == 0) name = addr;
            [found addObject:[NSDictionary dictionaryWithObjectsAndKeys:addr, @"address", name, @"name", nil]];
        }

        /* Load current paired list to find new devices */
        [self loadPairedDevices];
        NSMutableArray *newDevices = [NSMutableArray array];
        for (NSDictionary *d in found) {
            BOOL alreadyPaired = NO;
            for (NSDictionary *p in pairedDevices) {
                if ([[d objectForKey:@"address"] isEqualToString:[p objectForKey:@"address"]]) {
                    alreadyPaired = YES;
                    break;
                }
            }
            if (!alreadyPaired) {
                [newDevices addObject:d];
                /* Pre-fetch device info while still on background thread */
                [self parseDeviceInfo:[d objectForKey:@"address"]];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [scanSpinner stopAnimation:nil];
            [discoveredDevices release];
            discoveredDevices = [newDevices retain];
            NSLog(@"Bluetooth: scan found %lu new, %lu total known",
                  (unsigned long)[newDevices count], (unsigned long)[found count]);
            [devicesTable reloadData];
            [self updateButtonStates];
            self.currentOperation = BTOperationIdle;
            [self updateStatus:@"Scan complete"];
        });
    });
}

#pragma mark - NSTableView

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    (void)tableView;
    if (self.currentOperation == BTOperationScanning)
        return [discoveredDevices count];
    return [pairedDevices count] + [discoveredDevices count];
}

- (NSString *)_typeLabelForInfo:(NSDictionary *)info
{
    NSString *classStr = [info objectForKey:@"Class"];
    if ([classStr length] > 0) {
        NSScanner *sc = [NSScanner scannerWithString:classStr];
        unsigned int classVal = 0;
        [sc scanHexInt:&classVal];
        unsigned int major = (classVal >> 8) & 0x1F;
        NSString *type;
        switch (major) {
            case 0x01: type = @"Computer"; break;
            case 0x02: type = @"Phone"; break;
            case 0x03: type = @"Network"; break;
            case 0x04: type = @"Audio"; break;
            case 0x05: type = @"Peripheral"; break;
            case 0x06: type = @"Imaging"; break;
            case 0x07: type = @"Wearable"; break;
            case 0x08: type = @"Toy"; break;
            case 0x09: type = @"Health"; break;
            default: type = [NSString stringWithFormat:@"Other(%d)", major]; break;
        }
        return type;
    }
    return @"Unknown";
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    (void)tableView;
    (void)tableColumn;
    if (self.currentOperation == BTOperationScanning) {
        if (row < 0 || (NSUInteger)row >= [discoveredDevices count]) return @"";
        NSDictionary *d = [discoveredDevices objectAtIndex:row];
        NSString *n = [d objectForKey:@"name"];
        NSString *a = [d objectForKey:@"address"];
        return [NSString stringWithFormat:@"%@ (%@)", n ?: a, a];
    }
    /* Show paired devices first, then discovered unpaired devices */
    if ((NSUInteger)row < [pairedDevices count]) {
        NSDictionary *d = [pairedDevices objectAtIndex:row];
        NSString *addr = [d objectForKey:@"address"];
        NSString *name = [d objectForKey:@"name"];
        NSDictionary *info = [self parseDeviceInfo:addr];
        BOOL connected = ([[info objectForKey:@"Connected"] rangeOfString:@"yes" options:NSCaseInsensitiveSearch].location != NSNotFound);
        NSString *icon = [self _typeLabelForInfo:info];
        if ([icon length] > 0) icon = [icon stringByAppendingString:@" "];
        return [NSString stringWithFormat:@"%@%@ %@ (%@)", icon, connected ? @"●" : @"○", name ?: addr, addr];
    }
    /* Discovered (unpaired) devices */
    NSUInteger idx = row - [pairedDevices count];
    if (idx >= [discoveredDevices count]) return @"";
    NSDictionary *d = [discoveredDevices objectAtIndex:idx];
    NSString *n = [d objectForKey:@"name"];
    NSString *a = [d objectForKey:@"address"];
    NSDictionary *info = [self parseDeviceInfo:a];
    NSString *icon = [self _typeLabelForInfo:info];
    if ([icon length] > 0) icon = [icon stringByAppendingString:@" "];
    return [NSString stringWithFormat:@"%@+ %@ (%@)", icon, n ?: a, a];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    (void)notification;
    [self updateDetailForDevice:[self selectedDevice]];
    [self updateButtonStates];
}

#pragma mark - Helpers

- (void)updateStatus:(NSString *)message
{
    [statusLabel setStringValue:(message ? message : @"")];
}

@end

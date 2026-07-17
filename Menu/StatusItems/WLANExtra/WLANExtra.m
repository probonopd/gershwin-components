/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WLANExtra.h"
#import "NMBackend.h"
#import "GSMenuExtraContext.h"
#import "AppearanceMetrics.h"

static const BOOL kShowTextInMenuBar = NO;

@interface WLANExtra ()
@end

@implementation WLANExtra
{
    NMBackend *_backend;
    BOOL _wlanEnabled;
    WLAN *_connectedWLAN;
    int _signalStrength;
    NSArray<WLAN *> *_networkList;
    GSMenuExtraContext *_context;
}

static NSString *findTool(NSString *name)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bundleDir = [[NSBundle mainBundle] resourcePath];
    NSString *candidate = [bundleDir stringByAppendingPathComponent:name];
    if ([fm isExecutableFileAtPath:candidate]) return candidate;
    candidate = [[NSBundle mainBundle] pathForAuxiliaryExecutable:name];
    if ([fm isExecutableFileAtPath:candidate]) return candidate;
    NSArray *dirs = @[@"/usr/local/bin", @"/usr/bin", @"/bin",
                       @"/usr/local/sbin", @"/usr/sbin", @"/sbin"];
    for (NSString *dir in dirs) {
        candidate = [dir stringByAppendingPathComponent:name];
        if ([fm isExecutableFileAtPath:candidate]) return candidate;
    }
    return nil;
}

- (void)dealloc
{
    [self menuExtraWillUnload];
}

- (void)setContext:(GSMenuExtraContext *)context
{
    _context = context;
}

- (void)updateState
{
    if (![_backend isAvailable]) {
        _wlanEnabled = NO;
        _connectedWLAN = nil;
        _signalStrength = 0;
        _networkList = @[];
        [_context invalidatePresentation];
        return;
    }

    BOOL wasEnabled = _wlanEnabled;
    WLAN *oldConnected = _connectedWLAN;

    _wlanEnabled = [_backend isWLANEnabled];
    if (!_wlanEnabled) {
        _connectedWLAN = nil;
        _signalStrength = 0;
        _networkList = @[];
    } else {
        _networkList = [_backend scanForWLANs];
        _connectedWLAN = [_backend connectedWLAN];
        _signalStrength = _connectedWLAN ? [_connectedWLAN signalStrength] : 0;
    }

    if (wasEnabled != _wlanEnabled ||
        (!oldConnected && _connectedWLAN) ||
        (oldConnected && !_connectedWLAN) ||
        (oldConnected && _connectedWLAN && ![[oldConnected ssid] isEqualToString:[_connectedWLAN ssid]])) {
        [_context invalidatePresentation];
    }
}

#pragma mark - Actions

- (void)turnWLANOn:(id)sender
{
    (void)sender;
    NSLog(@"WLANExtra: turnWLANOn sender=%@ backend=%@", sender, _backend);
    [_backend setWLANEnabled:YES];
    [self updateState];
}

- (void)turnWLANOff:(id)sender
{
    (void)sender;
    NSLog(@"WLANExtra: turnWLANOff sender=%@ backend=%@", sender, _backend);
    [_backend setWLANEnabled:NO];
    [self updateState];
}

- (void)disconnectNetwork:(id)sender
{
    (void)sender;
    NSLog(@"WLANExtra: disconnectNetwork sender=%@ backend=%@", sender, _backend);
    [_backend disconnectFromWLAN];
    [self updateState];
}

- (NSString *)runPasswordPanelForSSID:(NSString *)ssid
{
    NSString *toolPath = findTool(@"wlanauth");
    if (!toolPath) return nil;

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:toolPath];
    [task setArguments:@[ssid]];
    NSPipe *outPipe = [NSPipe pipe];
    [task setStandardOutput:outPipe];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        return nil;
    }
    if ([task terminationStatus] != 0) return nil;
    NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSString *password = [[NSString alloc] initWithData:data
                                               encoding:NSUTF8StringEncoding];
    password = [password stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return ([password length] > 0) ? password : nil;
}

- (void)connectToNetwork:(id)sender
{
    NSString *ssid = [sender representedObject];
    NSString *security = [sender toolTip];
    if ([ssid length] == 0) return;

    WLAN *target = nil;
    for (WLAN *net in _networkList) {
        if ([[net ssid] isEqualToString:ssid]) {
            target = net;
            break;
        }
    }
    if (!target) return;

    NSString *password = nil;
    if ([security length] > 0) {
        password = [self runPasswordPanelForSSID:ssid];
        if (!password) return;
    }

    [_backend connectToWLAN:target withPassword:password];
    [self updateState];
}

#pragma mark - GSMenuExtra

- (NSMenu *)menu
{
    NSLog(@"WLANExtra: LAZY LOAD — reading fresh state from backend");
    BOOL wlanOn = [_backend isWLANEnabled];
    NSArray *nets = wlanOn ? [_backend scanForWLANs] : @[];
    WLAN *connected = wlanOn ? [_backend connectedWLAN] : nil;
    int signal = [connected signalStrength];
    NSString *connectedSSID = [connected ssid];
    NSLog(@"WLANExtra: menu building — wlanOn=%d connected=%@ signal=%d nets=%lu",
          wlanOn, connectedSSID, signal, (unsigned long)[nets count]);
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"WLAN"];

    if (![_backend isAvailable]) {
        NSMenuItem *na = [[NSMenuItem alloc] initWithTitle:@"WLAN: Unavailable"
                                                     action:NULL
                                              keyEquivalent:@""];
        [na setEnabled:NO];
        [m addItem:na];
        return m;
    }

    if (!wlanOn) {
        NSMenuItem *off = [[NSMenuItem alloc] initWithTitle:@"WLAN: Off"
                                                     action:NULL
                                              keyEquivalent:@""];
        [off setEnabled:NO];
        [m addItem:off];
        [m addItem:[NSMenuItem separatorItem]];
        NSMenuItem *on = [[NSMenuItem alloc] initWithTitle:@"Turn WLAN On"
                                                    action:@selector(turnWLANOn:)
                                             keyEquivalent:@""];
        [on setTarget:self];
        [m addItem:on];
        return m;
    }

    if (connectedSSID) {
        NSString *label = [NSString stringWithFormat:@"Connected: %@", connectedSSID];
        NSMenuItem *conn = [[NSMenuItem alloc] initWithTitle:label
                                                       action:NULL
                                                keyEquivalent:@""];
        [conn setEnabled:NO];
        [m addItem:conn];

        NSString *sigLabel = [NSString stringWithFormat:@"Signal: %d dBm", signal];
        NSMenuItem *sig = [[NSMenuItem alloc] initWithTitle:sigLabel
                                                     action:NULL
                                              keyEquivalent:@""];
        [sig setEnabled:NO];
        [m addItem:sig];

        [m addItem:[NSMenuItem separatorItem]];

        NSMenuItem *disconn = [[NSMenuItem alloc] initWithTitle:@"Disconnect"
                                                         action:@selector(disconnectNetwork:)
                                                  keyEquivalent:@""];
        [disconn setTarget:self];
        [m addItem:disconn];
    } else {
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"Not Connected"
                                                      action:NULL
                                               keyEquivalent:@""];
        [none setEnabled:NO];
        [m addItem:none];
    }

    [m addItem:[NSMenuItem separatorItem]];

    int count = 0;
    for (WLAN *net in nets) {
        if (count++ >= 20) break;
        NSString *ssid = [net ssid];
        if ([ssid length] == 0) continue;

        WLANSecurityType secType = [net security];
        BOOL isSecure = (secType != WLANSecurityNone);
        int signal = [net signalStrength];
        int bars;
        if (signal >= -50) bars = 4;
        else if (signal >= -60) bars = 3;
        else if (signal >= -70) bars = 2;
        else if (signal >= -80) bars = 1;
        else bars = 0;

        NSString *indicator = [@"\u25A0\u25A0\u25A0\u25A0" substringToIndex:bars];
        NSString *secSuffix = isSecure ? @" \u26BF" : @"";
        NSString *title = [NSString stringWithFormat:@"%@%@  %@", indicator, secSuffix, ssid];

        NSMenuItem *netItem = [[NSMenuItem alloc] initWithTitle:title
                                                         action:@selector(connectToNetwork:)
                                                  keyEquivalent:@""];
        [netItem setTarget:self];
        [netItem setRepresentedObject:ssid];
        [netItem setToolTip:isSecure ? @"WPA" : @""];
        if ([ssid isEqualToString:connectedSSID]) {
            [netItem setState:NSOnState];
        }

        [m addItem:netItem];
    }

    [m addItem:[NSMenuItem separatorItem]];
    NSMenuItem *off = [[NSMenuItem alloc] initWithTitle:@"Turn WLAN Off"
                                                 action:@selector(turnWLANOff:)
                                          keyEquivalent:@""];
    [off setTarget:self];
    [m addItem:off];

    return m;
}

- (NSImage *)image
{
    NSString *name;
    if (![_backend isAvailable]) {
        name = @"wlan-disabled";
    } else if (!_wlanEnabled) {
        name = @"wlan-off";
    } else if (_signalStrength >= -50) {
        name = @"wlan";
    } else if (_signalStrength >= -60) {
        name = @"wlan-good";
    } else if (_signalStrength >= -70) {
        name = @"wlan-ok";
    } else if (_connectedWLAN) {
        name = @"wlan-weak";
    } else {
        name = @"wlan-disabled";
    }
    NSImage *img = [NSImage imageNamed:name];
    if (!img) img = [NSImage imageNamed:@"wlan-disabled"];
    return img;
}

- (NSString *)title
{
    if (!kShowTextInMenuBar) return @"";
    if (![_backend isAvailable]) return @"--";
    if (!_wlanEnabled) return @"Off";
    if (_connectedWLAN) return [NSString stringWithFormat:@"%d", _signalStrength];
    return @"--";
}

- (void)menuExtraDidLoad
{
    _backend = [[NMBackend alloc] init];
    [self updateState];
}

- (void)menuExtraWillOpenMenu
{
    [self updateState];
}

- (void)refreshMenuItems:(NSMenu *)submenu
{
    NSString *connectedSSID = [[_backend connectedWLAN] ssid];
    for (NSMenuItem *item in [submenu itemArray]) {
        NSString *ssid = [item representedObject];
        if ([ssid isKindOfClass:[NSString class]]) {
            [item setState:[ssid isEqualToString:connectedSSID] ? NSOnState : NSOffState];
        }
    }
}

- (void)menuExtraWillUnload
{
}

@end

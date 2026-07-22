/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WLANExtra.h"
#import "NMBackend.h"
#import "BSDBackend.h"
#import "NetworkBackend.h"
#import "CaptivePortalDetector.h"
#import "GSMenuExtraContext.h"
#import "AppearanceMetrics.h"
#include <sys/utsname.h>
#include <string.h>
#if defined(__FreeBSD__) || defined(__DragonFly__)
#include <sys/sysctl.h>
#endif

static const BOOL kShowTextInMenuBar = NO;

static BOOL ShouldUseBSDNetworkBackend(void)
{
#if defined(__OpenBSD__) || defined(__NetBSD__)
    return YES;
#elif defined(__FreeBSD__) || defined(__DragonFly__)
    BOOL isBSD = NO;
    {
        char ostype[64] = {0};
        size_t len = sizeof(ostype) - 1;
        if (sysctlbyname("kern.ostype", ostype, &len, NULL, 0) == 0) {
            if (strcmp(ostype, "FreeBSD") == 0 ||
                strcmp(ostype, "DragonFly") == 0) {
                isBSD = YES;
            }
        }
    }
    if (!isBSD) {
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm isExecutableFileAtPath:@"/usr/sbin/sysrc"]) {
            isBSD = YES;
        }
    }
    if (!isBSD) {
        struct utsname uts;
        if (uname(&uts) == 0 &&
            (strcmp(uts.sysname, "FreeBSD") == 0 ||
             strcmp(uts.sysname, "DragonFly") == 0)) {
            isBSD = YES;
        }
    }
    return isBSD;
#else
    return NO;
#endif
}

static id<NetworkBackend> CreateNetworkBackend(void)
{
    if (ShouldUseBSDNetworkBackend()) {
        return [[BSDBackend alloc] init];
    }
    return [[NMBackend alloc] init];
}

@interface WLANExtra ()
@end

@implementation WLANExtra
{
    id<NetworkBackend> _backend;
    BOOL _backendAvailable;
    BOOL _wlanEnabled;
    WLAN *_connectedWLAN;
    int _signalStrength;
    NSArray<WLAN *> *_networkList;
    GSMenuExtraContext *_context;
    NSTimer *_timer;
    NSString *_previousConnectedSSID;
    BOOL _hasInternetAccess;
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
    BOOL wasEnabled = _wlanEnabled;
    BOOL wasAvailable = _backendAvailable;
    WLAN *oldConnected = _connectedWLAN;
    int oldSignalStrength = _signalStrength;
    NSUInteger oldNetworkCount = [_networkList count];

    _backendAvailable = [_backend isAvailable];
    if (!_backendAvailable) {
        _wlanEnabled = NO;
        _connectedWLAN = nil;
        _signalStrength = 0;
        _networkList = @[];
        if (wasAvailable || wasEnabled || oldConnected || oldSignalStrength != 0 || oldNetworkCount != 0) {
            [_context invalidatePresentation];
        }
        return;
    }

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
        oldSignalStrength != _signalStrength ||
        oldNetworkCount != [_networkList count] ||
        (!oldConnected && _connectedWLAN) ||
        (oldConnected && !_connectedWLAN) ||
        (oldConnected && _connectedWLAN && ![[oldConnected ssid] isEqualToString:[_connectedWLAN ssid]])) {
        [_context invalidatePresentation];
    }

    // Captive portal / internet connectivity check on WLAN SSID change
    NSString *currentSSID = [_connectedWLAN ssid];
    if (currentSSID && ![currentSSID isEqualToString:_previousConnectedSSID]) {
        _previousConnectedSSID = currentSSID;
        _hasInternetAccess = NO;
        [_context invalidatePresentation];
        [CaptivePortalDetector checkForCaptivePortalWithCompletion:^(BOOL isCaptive, NSString *redirectURL) {
            _hasInternetAccess = !isCaptive;
            [_context invalidatePresentation];
            if (isCaptive && redirectURL) {
                [self showCaptivePortalAlert:redirectURL];
            }
        }];
    } else if (!currentSSID) {
        _previousConnectedSSID = nil;
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
    BOOL wlanOn = _wlanEnabled;
    NSArray *nets = _networkList ?: @[];
    WLAN *connected = _connectedWLAN;
    int signal = _signalStrength;

    // If the cache is empty but the backend reports we are connected,
    // do a live fetch.  This handles the case where the initial scan
    // in updateState hasn't completed yet or returned transiently empty.
    if ([nets count] == 0 && !connected && wlanOn && _backendAvailable) {
        nets = [_backend scanForWLANs] ?: @[];
        connected = [_backend connectedWLAN];
        signal = [connected signalStrength];
        if ([nets count] > 0 || connected) {
            _networkList = nets;
            _connectedWLAN = connected;
            _signalStrength = signal;
        }
    }

    NSString *connectedSSID = [connected ssid];
    NSLog(@"WLANExtra: menu building — wlanOn=%d connected=%@ signal=%d nets=%lu",
          wlanOn, connectedSSID, signal, (unsigned long)[nets count]);
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"WLAN"];

    if (!_backendAvailable) {
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
        NSString *label;
        if (_hasInternetAccess) {
            label = [NSString stringWithFormat:@"Connected: %@", connectedSSID];
        } else {
            label = [NSString stringWithFormat:@"Connected: %@ (No Internet)", connectedSSID];
        }
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
    if (!_backendAvailable) {
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
    if (!_backendAvailable) return @"--";
    if (!_wlanEnabled) return @"Off";
    if (_connectedWLAN) return [NSString stringWithFormat:@"%d", _signalStrength];
    return @"--";
}

- (void)menuExtraDidLoad
{
    _backend = CreateNetworkBackend();
    [self updateState];
    _timer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                              target:self
                                            selector:@selector(refreshTimerFired:)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)menuExtraWillOpenMenu
{
    _backendAvailable = [_backend isAvailable];
    if (_backendAvailable) {
        _wlanEnabled = [_backend isWLANEnabled];
        if (_wlanEnabled) {
            NSArray *nets = [_backend scanForWLANs];
            WLAN *connected = [_backend connectedWLAN];
            int signal = [connected signalStrength];
            // Only update cached values if backend returned valid data.
            // A failing scan (nil/empty) should not erase a known connection.
            if ([nets count] > 0 || connected) {
                _networkList = nets;
                _connectedWLAN = connected;
                _signalStrength = signal;
            }
            // Re-check internet / captive portal status when menu opens
            if ([_connectedWLAN ssid]) {
                _hasInternetAccess = NO;
                [CaptivePortalDetector checkForCaptivePortalWithCompletion:^(BOOL isCaptive, NSString *redirectURL) {
                    _hasInternetAccess = !isCaptive;
                    [_context invalidatePresentation];
                }];
            }
        } else {
            _networkList = @[];
            _connectedWLAN = nil;
            _signalStrength = 0;
        }
    } else {
        _wlanEnabled = NO;
        _networkList = @[];
        _connectedWLAN = nil;
        _signalStrength = 0;
    }
}

- (void)refreshMenuItems:(NSMenu *)submenu
{
    NSString *connectedSSID = [_connectedWLAN ssid];
    for (NSMenuItem *item in [submenu itemArray]) {
        NSString *ssid = [item representedObject];
        if ([ssid isKindOfClass:[NSString class]]) {
            [item setState:[ssid isEqualToString:connectedSSID] ? NSOnState : NSOffState];
        }
    }
}

- (void)menuExtraWillUnload
{
    [_timer invalidate];
    _timer = nil;
    _backend = nil;
}

- (void)refreshTimerFired:(NSTimer *)timer
{
    (void)timer;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL wasAvailable = _backendAvailable;
        BOOL available = [_backend isAvailable];
        if (!available) {
            dispatch_async(dispatch_get_main_queue(), ^{
                _backendAvailable = NO;
                _signalStrength = 0;
                _networkList = @[];
                _connectedWLAN = nil;
                if (wasAvailable) {
                    [_context invalidatePresentation];
                }
            });
            return;
        }
        if (!_wlanEnabled) return;
        int oldSignal = _signalStrength;
        WLAN *oldConnected = _connectedWLAN;
        NSUInteger oldCount = [_networkList count];
        NSArray *nets = [_backend scanForWLANs];
        WLAN *connected = [_backend connectedWLAN];
        int signal = connected ? [connected signalStrength] : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            _backendAvailable = YES;
            if ([nets count] > 0 || connected) {
                _networkList = nets;
                _connectedWLAN = connected;
                _signalStrength = signal;
            }
            if (oldSignal != _signalStrength || oldCount != [_networkList count] ||
                (!oldConnected && _connectedWLAN) || (oldConnected && !_connectedWLAN)) {
                [_context invalidatePresentation];
            }
        });
    });
}

#pragma mark - Captive Portal

- (void)showCaptivePortalAlert:(NSString *)redirectURL
{
    if (!redirectURL || [redirectURL length] == 0) return;

    NSDebugLLog(@"gwcomp", @"[WLANExtra] Captive portal detected, redirect to: %@", redirectURL);

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Captive Portal Detected"];
    [alert setInformativeText:@"The WLAN network requires you to sign in "
        @"before accessing the internet. Would you like to open "
        @"the login page in your browser?"];
    [alert setAlertStyle:NSInformationalAlertStyle];
    [alert addButtonWithTitle:@"Open in Browser"];
    [alert addButtonWithTitle:@"Cancel"];

    NSInteger result = [alert runModal];

    if (result == NSAlertFirstButtonReturn) {
        NSURL *url = [NSURL URLWithString:redirectURL];
        if (url) {
            [[NSWorkspace sharedWorkspace] openURL:url];
        }
    }
}

@end

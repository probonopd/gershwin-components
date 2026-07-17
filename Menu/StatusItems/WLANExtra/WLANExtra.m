/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WLANExtra.h"
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#ifdef __linux__
#define NMCLI_PATH @"/usr/bin/nmcli"
#else
#define NMCLI_PATH @"/usr/local/bin/nmcli"
#endif

static const BOOL kShowTextInMenuBar = NO;

@implementation WLANExtra
{
    NSTimer *_timer;
    BOOL _wlanEnabled;
    NSString *_connectedSSID;
    int _signalStrength;
    NSMutableArray *_networkList;
}

- (void)dealloc
{
    [self menuExtraWillUnload];
}

#pragma mark - nmcli helpers (reuse from NMBackend)

- (NSString *)runCommand:(NSString *)cmd args:(NSArray *)args
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:cmd];
    if (args) [task setArguments:args];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        return nil;
    }
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)updateWLAN
{
    _wlanEnabled = NO;
    _connectedSSID = nil;
    _signalStrength = 0;

    NSString *radio = [self runCommand:NMCLI_PATH args:@[@"radio", @"wifi"]];
    _wlanEnabled = [radio isEqualToString:@"enabled"];
    if (!_wlanEnabled) return;

    NSString *devStatus = [self runCommand:NMCLI_PATH
                                      args:@[@"-t", @"-f", @"DEVICE,TYPE,STATE",
                                             @"device", @"status"]];
    NSString *wifiDev = nil;
    for (NSString *line in [devStatus componentsSeparatedByString:@"\n"]) {
        NSArray *parts = [line componentsSeparatedByString:@":"];
        if ([parts count] >= 3 && [[parts objectAtIndex:1] isEqualToString:@"wifi"]) {
            wifiDev = [parts objectAtIndex:0];
            break;
        }
    }
    if (!wifiDev) return;

    NSString *conn = [self runCommand:NMCLI_PATH
                                 args:@[@"-t", @"-f", @"NAME,DEVICE",
                                        @"connection", @"show", @"--active"]];
    for (NSString *line in [conn componentsSeparatedByString:@"\n"]) {
        NSArray *parts = [line componentsSeparatedByString:@":"];
        if ([parts count] >= 2 && [[parts objectAtIndex:1] isEqualToString:wifiDev]) {
            _connectedSSID = [parts objectAtIndex:0];
            break;
        }
    }

    NSString *sig = [self runCommand:NMCLI_PATH
                                args:@[@"-t", @"-f", @"IN-USE,SSID,SIGNAL",
                                       @"device", @"wifi", @"list"]];
    for (NSString *line in [sig componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"*:"]) {
            NSArray *parts = [line componentsSeparatedByString:@":"];
            if ([parts count] >= 3) {
                _signalStrength = [[parts objectAtIndex:2] intValue];
            }
            break;
        }
    }

    NSString *scan = [self runCommand:NMCLI_PATH
                                 args:@[@"-t", @"-f", @"SSID,SIGNAL,SECURITY",
                                        @"device", @"wifi", @"list"]];
    _networkList = [NSMutableArray array];
    for (NSString *line in [scan componentsSeparatedByString:@"\n"]) {
        if ([line length] > 0) {
            [_networkList addObject:line];
        }
    }
}

- (void)turnWLANOn:(id)sender
{
    (void)sender;
    [self runCommand:NMCLI_PATH args:@[@"radio", @"wifi", @"on"]];
    [self updateWLAN];
}

- (void)turnWLANOff:(id)sender
{
    (void)sender;
    [self runCommand:NMCLI_PATH args:@[@"radio", @"wifi", @"off"]];
    [self updateWLAN];
}

- (void)connectToNetwork:(id)sender
{
    NSString *ssid = [sender representedObject];
    if ([ssid length] > 0) {
        [self runCommand:NMCLI_PATH args:@[@"device", @"wifi", @"connect", ssid]];
        [self updateWLAN];
    }
}

- (void)disconnectNetwork:(id)sender
{
    (void)sender;
    NSString *ssid = _connectedSSID;
    if ([ssid length] > 0) {
        [self runCommand:NMCLI_PATH args:@[@"connection", @"down", @"id", ssid]];
        [self updateWLAN];
    }
}

#pragma mark - GSMenuExtra

- (NSMenu *)menu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"WLAN"];

    if (!_wlanEnabled) {
        NSMenuItem *off = [[NSMenuItem alloc] initWithTitle:@"WLAN: Off"
                                                     action:NULL
                                              keyEquivalent:@""];
        [off setEnabled:NO];
        [m addItem:off];
        [m addItem:[NSMenuItem separatorItem]];
        NSMenuItem *on = [[NSMenuItem alloc] initWithTitle:@"Turn WLAN On…"
                                                    action:@selector(turnWLANOn:)
                                             keyEquivalent:@""];
        [on setTarget:self];
        [m addItem:on];
        return m;
    }

    if (_connectedSSID) {
        NSString *connLabel = [NSString stringWithFormat:@"Connected: %@", _connectedSSID];
        NSMenuItem *conn = [[NSMenuItem alloc] initWithTitle:connLabel
                                                      action:NULL
                                               keyEquivalent:@""];
        [conn setEnabled:NO];
        [conn setState:NSOnState];
        [m addItem:conn];

        NSString *sigLabel = [NSString stringWithFormat:@"Signal: %d%%", _signalStrength];
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
    for (NSString *net in _networkList) {
        if (count++ >= 15) break;
        NSArray *parts = [net componentsSeparatedByString:@":"];
        NSString *ssid = [parts count] > 0 ? [parts objectAtIndex:0] : net;
        if ([ssid length] == 0) continue;

        NSMenuItem *netItem = [[NSMenuItem alloc] initWithTitle:ssid
                                                         action:@selector(connectToNetwork:)
                                                  keyEquivalent:@""];
        [netItem setTarget:self];
        [netItem setRepresentedObject:ssid];
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
    if (!_wlanEnabled) {
        name = @"wlan-disabled";
    } else if (_signalStrength >= 75) {
        name = @"wlan";
    } else if (_signalStrength >= 50) {
        name = @"wlan-good";
    } else if (_signalStrength >= 25) {
        name = @"wlan-ok";
    } else if (_connectedSSID) {
        name = @"wlan-weak";
    } else {
        name = @"wlan-disabled";
    }
    return [NSImage imageNamed:name];
}

- (NSString *)title
{
    if (!kShowTextInMenuBar) return @"";
    if (!_wlanEnabled) return @"Off";
    if (_connectedSSID) return [NSString stringWithFormat:@"%d%%", _signalStrength];
    return @"--";
}

- (void)menuExtraDidLoad
{
    [self updateWLAN];
    _timer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                              target:self
                                            selector:@selector(updateWLAN)
                                            userInfo:nil
                                             repeats:YES];
}

- (void)menuExtraWillUnload
{
    [_timer invalidate];
    _timer = nil;
}

@end

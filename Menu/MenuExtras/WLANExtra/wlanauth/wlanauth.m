/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@interface PasswordPanel : NSPanel
@end

@implementation PasswordPanel
- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    NSString *chars = [event charactersIgnoringModifiers];
    if ([chars length] > 0) {
        unichar c = [chars characterAtIndex:0];
        if (c == '\r' || c == '\n') {
            [NSApp stopModalWithCode:1];
            return YES;
        }
        if (c == 27) {
            [NSApp stopModalWithCode:0];
            return YES;
        }
    }
    return [super performKeyEquivalent:event];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
{
    NSString *_ssid;
}
@end

@implementation AppDelegate
- (void)setSSID:(NSString *)ssid
{
    _ssid = ssid;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notif
{
    (void)notif;

    CGFloat w = 310, h = 119;
    NSRect r = NSMakeRect(0, 0, w, h);
    PasswordPanel *panel = [[PasswordPanel alloc] initWithContentRect:r
                                                           styleMask:NSTitledWindowMask
                                                             backing:NSBackingStoreBuffered
                                                               defer:YES];
    [panel setTitle:[NSString stringWithFormat:@"Connect to \"%@\"", _ssid]];
    [panel setHidesOnDeactivate:NO];
    [panel center];

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 86, 262, 18)];
    [label setStringValue:@"Enter the network password:"];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setFont:[NSFont systemFontOfSize:13]];
    [[panel contentView] addSubview:label];

    NSSecureTextField *field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(24, 56, 262, 22)];
    [field setTarget:self];
    [field setAction:@selector(doConnect:)];
    [[panel contentView] addSubview:field];

    float btnX = w - 24 - 100;
    NSButton *connectBtn = [[NSButton alloc] initWithFrame:NSMakeRect(btnX, 20, 100, 20)];
    [connectBtn setTitle:@"Connect"];
    [connectBtn setBezelStyle:NSRoundedBezelStyle];
    [connectBtn setTarget:self];
    [connectBtn setAction:@selector(doConnect:)];
    [[panel contentView] addSubview:connectBtn];

    btnX -= 10 + 100;
    NSButton *cancelBtn = [[NSButton alloc] initWithFrame:NSMakeRect(btnX, 20, 100, 20)];
    [cancelBtn setTitle:@"Cancel"];
    [cancelBtn setBezelStyle:NSRoundedBezelStyle];
    [cancelBtn setTarget:self];
    [cancelBtn setAction:@selector(doCancel:)];
    [[panel contentView] addSubview:cancelBtn];

    [panel setInitialFirstResponder:field];
    [panel makeKeyAndOrderFront:nil];
    [panel makeFirstResponder:field];

    NSInteger code = [NSApp runModalForWindow:panel];

    if (code == 1) {
        NSString *password = [field stringValue];
        if (password) {
            printf("%s", [password UTF8String]);
        }
    }
    [panel orderOut:nil];
    [NSApp terminate:nil];
}

- (void)doConnect:(id)sender
{
    (void)sender;
    [NSApp stopModalWithCode:1];
}

- (void)doCancel:(id)sender
{
    (void)sender;
    [NSApp stopModalWithCode:0];
}
@end

int main(int argc, const char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "Usage: wlanauth <SSID>\n");
        return 1;
    }
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *del = [[AppDelegate alloc] init];
        [del setSSID:[NSString stringWithUTF8String:argv[1]]];
        [app setDelegate:del];
        [app run];
    }
    return 0;
}

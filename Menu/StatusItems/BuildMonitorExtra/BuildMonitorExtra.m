#import "BuildMonitorExtra.h"
#import "GSMenuExtraContext.h"

#define POLL_INTERVAL 60.0
#define CONFIG_PREFIX @"BuildMonitor."

static NSString *ConfigKey(NSString *key)
{
    return [CONFIG_PREFIX stringByAppendingString: key];
}

@interface BuildMonitorExtra () <NSWindowDelegate>
{
    NSTimer *_timer;
    GSMenuExtraContext *_context;

    NSString *_owner;
    NSString *_repo;
    NSString *_token;
    NSString *_lastFailureIDs;

    NSArray *_recentRuns;
    BOOL _hasFailure;
    BOOL _hasRunning;
    BOOL _fetchError;

    NSWindow *_configPanel;
    NSTextField *_ownerField;
    NSTextField *_repoField;
    NSTextField *_tokenField;
}
@end

@implementation BuildMonitorExtra

- (void)dealloc
{
    [self menuExtraWillUnload];
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

#pragma mark - Configuration

- (void)loadConfig
{
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    _owner = [defs stringForKey: ConfigKey(@"owner")];
    _repo = [defs stringForKey: ConfigKey(@"repo")];
    _token = [defs stringForKey: ConfigKey(@"token")];
    _lastFailureIDs = [defs stringForKey: ConfigKey(@"lastFailureIDs")];
}

- (void)saveConfig
{
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    if (_owner) [defs setObject: _owner forKey: ConfigKey(@"owner")];
    else [defs removeObjectForKey: ConfigKey(@"owner")];
    if (_repo) [defs setObject: _repo forKey: ConfigKey(@"repo")];
    else [defs removeObjectForKey: ConfigKey(@"repo")];
    if (_token) [defs setObject: _token forKey: ConfigKey(@"token")];
    else [defs removeObjectForKey: ConfigKey(@"token")];
    if (_lastFailureIDs) [defs setObject: _lastFailureIDs forKey: ConfigKey(@"lastFailureIDs")];
    else [defs removeObjectForKey: ConfigKey(@"lastFailureIDs")];
}

#pragma mark - GitHub API

- (NSString *)fetchRunsJSON
{
    if ([_owner length] == 0 || [_repo length] == 0) return nil;

    NSString *urlStr = [NSString stringWithFormat: @"https://api.github.com/repos/%@/%@/actions/runs?per_page=10",
                         _owner, _repo];

    NSMutableArray *args = [NSMutableArray array];
    [args addObject: @"-sL"];
    [args addObject: urlStr];

    if ([_token length] > 0) {
        [args addObject: @"-H"];
        [args addObject: [NSString stringWithFormat: @"Authorization: token %@", _token]];
    }
    [args addObject: @"-H"];
    [args addObject: @"User-Agent: BuildMonitorExtra/1.0"];

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath: @"/usr/bin/curl"];
    [task setArguments: args];

    NSPipe *outPipe = [NSPipe pipe];
    [task setStandardOutput: outPipe];
    [task setStandardError: [NSFileHandle fileHandleWithNullDevice]];

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        return nil;
    }

    if ([task terminationStatus] != 0) return nil;

    NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
    return [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
}

- (void)pollGitHub
{
    NSString *json = [self fetchRunsJSON];
    if (!json) {
        _fetchError = YES;
        [_context invalidatePresentation];
        return;
    }

    _fetchError = NO;

    NSData *data = [json dataUsingEncoding: NSUTF8StringEncoding];
    NSError *err = nil;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData: data options: 0 error: &err];
    if (!dict || ![dict isKindOfClass: [NSDictionary class]]) {
        _fetchError = YES;
        [_context invalidatePresentation];
        return;
    }

    NSArray *runs = [dict objectForKey: @"workflow_runs"];
    if (!runs) {
        _fetchError = YES;
        [_context invalidatePresentation];
        return;
    }

    _recentRuns = runs;

    NSMutableArray *currentFailureIDs = [NSMutableArray array];
    _hasRunning = NO;

    for (NSDictionary *run in runs) {
        NSString *status = [run objectForKey: @"status"];
        NSString *conclusion = [run objectForKey: @"conclusion"];
        NSNumber *runID = [run objectForKey: @"id"];

        if ([status isEqualToString: @"in_progress"] || [status isEqualToString: @"queued"]) {
            _hasRunning = YES;
        } else if ([status isEqualToString: @"completed"]
                   && [conclusion isEqualToString: @"failure"]) {
            [currentFailureIDs addObject: [runID stringValue]];
        }
    }

    _hasFailure = [currentFailureIDs count] > 0;

    BOOL newFailure = NO;
    NSArray *prevIDs = [_lastFailureIDs componentsSeparatedByString: @";"];

    for (NSString *fid in currentFailureIDs) {
        if (![prevIDs containsObject: fid]) {
            newFailure = YES;
            break;
        }
    }

    if (_hasFailure) {
        _lastFailureIDs = [currentFailureIDs componentsJoinedByString: @";"];
    } else {
        _lastFailureIDs = @"";
    }
    [self saveConfig];

    [_context invalidatePresentation];

    if (newFailure) {
        [self performSelectorOnMainThread: @selector(showFailureAlert)
                               withObject: nil
                            waitUntilDone: NO];
    }
}

- (void)showFailureAlert
{
    if ([_owner length] == 0 || [_repo length] == 0) return;

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText: @"Build Failed"];
    [alert setInformativeText: [NSString stringWithFormat:
        @"Repository %@/%@ has failing builds.", _owner, _repo]];
    [alert addButtonWithTitle: @"View on GitHub"];
    [alert addButtonWithTitle: @"Dismiss"];

    NSInteger result = [alert runModal];
    if (result == NSAlertFirstButtonReturn) {
        NSString *urlStr = [NSString stringWithFormat:
            @"https://github.com/%@/%@/actions", _owner, _repo];
        [[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: urlStr]];
    }
}

#pragma mark - Config Panel

- (void)showConfigPanel
{
    if (_configPanel) {
        [_configPanel makeKeyAndOrderFront: nil];
        [NSApp activateIgnoringOtherApps: YES];
        return;
    }

    const CGFloat w = 360;
    const CGFloat h = 200;
    const CGFloat pad = 12;
    const CGFloat lw = 80;
    const CGFloat fw = w - lw - pad * 3;

    NSRect contentRect = NSMakeRect(0, 0, w, h);
    _configPanel = [[NSWindow alloc] initWithContentRect: contentRect
                                               styleMask: NSTitledWindowMask | NSClosableWindowMask
                                                 backing: NSBackingStoreRetained
                                                   defer: NO];
    [_configPanel setTitle: @"Build Monitor Configuration"];
    [_configPanel setDelegate: self];

    NSView *content = [[NSView alloc] initWithFrame: contentRect];

    CGFloat y = h - 28;
    NSTextField *label;

    label = [[NSTextField alloc] initWithFrame: NSMakeRect(pad, y, w - pad * 2, 18)];
    [label setStringValue: @"GitHub repository to monitor:"];
    [label setBezeled: NO];
    [label setDrawsBackground: NO];
    [label setEditable: NO];
    [label setSelectable: NO];
    [content addSubview: label];

    y -= 24;

    NSTextField *ol = [[NSTextField alloc] initWithFrame: NSMakeRect(pad, y, lw, 22)];
    [ol setStringValue: @"Owner:"];
    [ol setBezeled: NO];
    [ol setDrawsBackground: NO];
    [ol setEditable: NO];
    [ol setSelectable: NO];
    [content addSubview: ol];

    _ownerField = [[NSTextField alloc] initWithFrame: NSMakeRect(pad + lw, y, fw, 22)];
    [_ownerField setStringValue: _owner ?: @""];
    [content addSubview: _ownerField];

    y -= 26;

    NSTextField *rl = [[NSTextField alloc] initWithFrame: NSMakeRect(pad, y, lw, 22)];
    [rl setStringValue: @"Repo:"];
    [rl setBezeled: NO];
    [rl setDrawsBackground: NO];
    [rl setEditable: NO];
    [rl setSelectable: NO];
    [content addSubview: rl];

    _repoField = [[NSTextField alloc] initWithFrame: NSMakeRect(pad + lw, y, fw, 22)];
    [_repoField setStringValue: _repo ?: @""];
    [content addSubview: _repoField];

    y -= 30;

    label = [[NSTextField alloc] initWithFrame: NSMakeRect(pad, y, w - pad * 2, 18)];
    [label setStringValue: @"Token (optional, for private repos):"];
    [label setBezeled: NO];
    [label setDrawsBackground: NO];
    [label setEditable: NO];
    [label setSelectable: NO];
    [content addSubview: label];

    y -= 24;

    _tokenField = [[NSTextField alloc] initWithFrame: NSMakeRect(pad, y, w - pad * 2, 22)];
    [_tokenField setStringValue: _token ?: @""];
    [content addSubview: _tokenField];

    y -= 36;

    NSButton *saveBtn = [[NSButton alloc] initWithFrame: NSMakeRect(w - 102, y, 90, 24)];
    [saveBtn setTitle: @"Save"];
    [saveBtn setButtonType: NSMomentaryPushInButton];
    [saveBtn setBezelStyle: NSRoundedBezelStyle];
    [saveBtn setTarget: self];
    [saveBtn setAction: @selector(saveConfigPanel:)];
    [content addSubview: saveBtn];

    NSButton *cancelBtn = [[NSButton alloc] initWithFrame: NSMakeRect(w - 200, y, 90, 24)];
    [cancelBtn setTitle: @"Cancel"];
    [cancelBtn setButtonType: NSMomentaryPushInButton];
    [cancelBtn setBezelStyle: NSRoundedBezelStyle];
    [cancelBtn setTarget: self];
    [cancelBtn setAction: @selector(closeConfigPanel:)];
    [content addSubview: cancelBtn];

    [_configPanel setContentView: content];
    [_configPanel center];
    [_configPanel makeKeyAndOrderFront: nil];
    [NSApp activateIgnoringOtherApps: YES];
}

- (void)saveConfigPanel:(id)sender
{
    _owner = [_ownerField stringValue];
    _repo = [_repoField stringValue];
    _token = [_tokenField stringValue];
    [self saveConfig];
    [_configPanel close];
    _configPanel = nil;

    [self pollGitHub];
    if (!_timer) {
        _timer = [NSTimer scheduledTimerWithTimeInterval: POLL_INTERVAL
                                                  target: self
                                                selector: @selector(pollGitHub)
                                                userInfo: nil
                                                 repeats: YES];
    }
}

- (void)closeConfigPanel:(id)sender
{
    [_configPanel close];
    _configPanel = nil;
}

- (void)windowWillClose:(NSNotification *)notification
{
    if ([notification object] == _configPanel) {
        _configPanel = nil;
    }
}

#pragma mark - Icon

- (NSImage *)statusImage
{
    static NSDictionary *colorMap = nil;
    if (!colorMap) {
        colorMap = @{
            @"green":  [NSColor colorWithCalibratedRed: 0.2 green: 0.8 blue: 0.2 alpha: 1.0],
            @"yellow": [NSColor colorWithCalibratedRed: 0.9 green: 0.7 blue: 0.0 alpha: 1.0],
            @"red":    [NSColor colorWithCalibratedRed: 0.9 green: 0.1 blue: 0.1 alpha: 1.0],
            @"gray":   [NSColor colorWithCalibratedRed: 0.5 green: 0.5 blue: 0.5 alpha: 1.0],
        };
    }

    NSString *colorKey = @"gray";
    if (_fetchError) colorKey = @"gray";
    else if (_hasFailure) colorKey = @"red";
    else if (_hasRunning) colorKey = @"yellow";
    else if ([_owner length] > 0 && [_repo length] > 0) colorKey = @"green";

    NSColor *color = [colorMap objectForKey: colorKey];

    NSSize size = NSMakeSize(16, 16);
    NSImage *img = [[NSImage alloc] initWithSize: size];

    [img lockFocus];
    [color set];
    NSBezierPath *path = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect(2, 2, 12, 12)];
    [path fill];

    [[NSColor whiteColor] set];
    NSString *letter = @"B";
    NSDictionary *attrs = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize: 9] };
    NSSize ts = [letter sizeWithAttributes: attrs];
    NSPoint tp = NSMakePoint((size.width - ts.width) / 2, (size.height - ts.height) / 2 - 0.5);
    [letter drawAtPoint: tp withAttributes: attrs];

    [img unlockFocus];
    return img;
}

#pragma mark - GSMenuExtra

- (void)setContext:(GSMenuExtraContext *)context
{
    _context = context;
}

- (void)menuExtraDidLoad
{
    [self loadConfig];

    if ([_owner length] > 0 && [_repo length] > 0) {
        [self pollGitHub];
        _timer = [NSTimer scheduledTimerWithTimeInterval: POLL_INTERVAL
                                                  target: self
                                                selector: @selector(pollGitHub)
                                                userInfo: nil
                                                 repeats: YES];
    } else {
        [self performSelector: @selector(showConfigPanel)
                   withObject: nil
                   afterDelay: 0.5];
    }
}

- (void)menuExtraWillUnload
{
    [_timer invalidate];
    _timer = nil;
}

- (NSMenu *)menu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle: @"BuildMonitor"];

    if ([_owner length] == 0 || [_repo length] == 0) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle: @"Not configured"
                                                      action: NULL
                                               keyEquivalent: @""];
        [item setEnabled: NO];
        [m addItem: item];
        [m addItem: [NSMenuItem separatorItem]];
        NSMenuItem *cfg = [[NSMenuItem alloc] initWithTitle: @"Configure..."
                                                     action: @selector(showConfigPanel)
                                              keyEquivalent: @""];
        [cfg setTarget: self];
        [m addItem: cfg];
        return m;
    }

    if (_fetchError) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle: @"Error fetching build status"
                                                      action: NULL
                                               keyEquivalent: @""];
        [item setEnabled: NO];
        [m addItem: item];
    }

    for (NSDictionary *run in _recentRuns) {
        NSString *name = [run objectForKey: @"name"];
        NSString *branch = [run objectForKey: @"head_branch"];
        NSString *status = [run objectForKey: @"status"];
        NSString *conclusion = [run objectForKey: @"conclusion"];
        NSString *htmlURL = [run objectForKey: @"html_url"];

        NSString *icon;
        if ([status isEqualToString: @"in_progress"] || [status isEqualToString: @"queued"]) {
            icon = [NSString stringWithUTF8String: "\xE2\x97\x8B"]; // ○
        } else if ([conclusion isEqualToString: @"success"]) {
            icon = [NSString stringWithUTF8String: "\xE2\x9C\x93"]; // ✓
        } else if ([conclusion isEqualToString: @"failure"]) {
            icon = [NSString stringWithUTF8String: "\xE2\x9C\x98"]; // ✘
        } else {
            icon = @"-";
        }

        NSString *title = [NSString stringWithFormat: @"%@ %@ (%@)", icon, name, branch];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle: title
                                                      action: @selector(openRunURL:)
                                               keyEquivalent: @""];
        [item setTarget: self];
        if (htmlURL) {
            [item setRepresentedObject: htmlURL];
        } else {
            [item setEnabled: NO];
        }
        [m addItem: item];
    }

    [m addItem: [NSMenuItem separatorItem]];

    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle: @"Refresh Now"
                                                         action: @selector(pollGitHub)
                                                  keyEquivalent: @"r"];
    [refreshItem setTarget: self];
    [m addItem: refreshItem];

    NSMenuItem *configureItem = [[NSMenuItem alloc] initWithTitle: @"Configure..."
                                                          action: @selector(showConfigPanel)
                                                   keyEquivalent: @""];
    [configureItem setTarget: self];
    [m addItem: configureItem];

    [m addItem: [NSMenuItem separatorItem]];

    NSString *ownerRepo = [NSString stringWithFormat: @"%@/%@ on GitHub", _owner, _repo];
    NSMenuItem *githubItem = [[NSMenuItem alloc] initWithTitle: ownerRepo
                                                        action: @selector(openGitHub:)
                                                 keyEquivalent: @""];
    [githubItem setTarget: self];
    [m addItem: githubItem];

    return m;
}

- (NSImage *)image
{
    return [self statusImage];
}

- (NSString *)title
{
    return @"";
}

- (void)openRunURL:(id)sender
{
    NSString *url = [sender representedObject];
    if (url) {
        [[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: url]];
    }
}

- (void)openGitHub:(id)sender
{
    if ([_owner length] > 0 && [_repo length] > 0) {
        NSString *urlStr = [NSString stringWithFormat: @"https://github.com/%@/%@/actions",
                             _owner, _repo];
        [[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: urlStr]];
    }
}

@end

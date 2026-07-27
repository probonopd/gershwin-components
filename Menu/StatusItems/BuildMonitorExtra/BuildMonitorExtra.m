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

    NSArray *_repos;
    NSString *_token;
    NSMutableDictionary *_lastFailures;

    NSMutableDictionary *_repoStatuses;
    BOOL _hasAnyFailure;
    BOOL _hasAnyRunning;
    BOOL _fetchError;

    NSWindow *_configPanel;
    NSTextView *_reposTextView;
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
    _repos = [defs arrayForKey: ConfigKey(@"repos")] ?: @[];
    _token = [defs stringForKey: ConfigKey(@"token")];
    NSDictionary *failures = [defs dictionaryForKey: ConfigKey(@"lastFailures")];
    _lastFailures = failures ? [failures mutableCopy] : [NSMutableDictionary dictionary];
}

- (void)saveConfig
{
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    [defs setObject: _repos forKey: ConfigKey(@"repos")];
    if (_token) [defs setObject: _token forKey: ConfigKey(@"token")];
    else [defs removeObjectForKey: ConfigKey(@"token")];
    [defs setObject: _lastFailures forKey: ConfigKey(@"lastFailures")];
}

#pragma mark - GitHub API

- (NSString *)fetchRunsJSONForOwner:(NSString *)owner repo:(NSString *)repo
{
    NSString *urlStr = [NSString stringWithFormat: @"https://api.github.com/repos/%@/%@/actions/runs?per_page=5",
                         owner, repo];

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
    _hasAnyFailure = NO;
    _hasAnyRunning = NO;
    _fetchError = NO;

    if ([_repos count] == 0) {
        [_context invalidatePresentation];
        return;
    }

    if (!_repoStatuses) _repoStatuses = [NSMutableDictionary dictionary];

    BOOL anyNewFailure = NO;

    for (NSString *repoStr in _repos) {
        NSArray *parts = [repoStr componentsSeparatedByString: @"/"];
        if ([parts count] != 2) continue;
        NSString *owner = parts[0];
        NSString *repo = parts[1];

        NSString *json = [self fetchRunsJSONForOwner: owner repo: repo];
        if (!json) {
            [_repoStatuses setObject: @"error" forKey: repoStr];
            _fetchError = YES;
            continue;
        }

        NSData *data = [json dataUsingEncoding: NSUTF8StringEncoding];
        NSError *err = nil;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData: data options: 0 error: &err];
        if (!dict || ![dict isKindOfClass: [NSDictionary class]]) {
            [_repoStatuses setObject: @"error" forKey: repoStr];
            _fetchError = YES;
            continue;
        }

        NSArray *runs = [dict objectForKey: @"workflow_runs"];
        if (!runs) {
            [_repoStatuses setObject: @"error" forKey: repoStr];
            _fetchError = YES;
            continue;
        }

        BOOL repoHasRunning = NO;
        BOOL repoHasFailure = NO;
        BOOL repoHasSuccess = NO;
        NSMutableArray *currentFailureIDs = [NSMutableArray array];

        for (NSDictionary *run in runs) {
            NSString *status = [run objectForKey: @"status"];
            NSString *conclusion = [run objectForKey: @"conclusion"];

            if ([status isEqualToString: @"in_progress"] || [status isEqualToString: @"queued"]) {
                repoHasRunning = YES;
            } else if ([status isEqualToString: @"completed"]) {
                if ([conclusion isEqualToString: @"failure"]) {
                    repoHasFailure = YES;
                    NSNumber *runID = [run objectForKey: @"id"];
                    [currentFailureIDs addObject: [runID stringValue]];
                } else if ([conclusion isEqualToString: @"success"]) {
                    repoHasSuccess = YES;
                }
            }
        }

        if (repoHasRunning) _hasAnyRunning = YES;
        if (repoHasFailure) _hasAnyFailure = YES;

        NSString *status;
        if (repoHasFailure) status = @"failure";
        else if (repoHasRunning) status = @"running";
        else if (repoHasSuccess) status = @"success";
        else status = @"unknown";
        [_repoStatuses setObject: status forKey: repoStr];

        NSString *prevIDs = [_lastFailures objectForKey: repoStr] ?: @"";
        NSArray *prevIDList = [prevIDs length] > 0 ? [prevIDs componentsSeparatedByString: @";"] : @[];
        for (NSString *fid in currentFailureIDs) {
            if (![prevIDList containsObject: fid]) {
                anyNewFailure = YES;
                break;
            }
        }

        NSString *joined = [currentFailureIDs componentsJoinedByString: @";"];
        if ([joined length] > 0) {
            [_lastFailures setObject: joined forKey: repoStr];
        } else {
            [_lastFailures removeObjectForKey: repoStr];
        }
    }

    [self saveConfig];
    [_context invalidatePresentation];

    if (anyNewFailure) {
        [self showFailureAlert];
    }
}

- (void)showFailureAlert
{
    NSMutableArray *failedRepos = [NSMutableArray array];
    for (NSString *repoStr in _repos) {
        NSString *status = [_repoStatuses objectForKey: repoStr];
        if ([status isEqualToString: @"failure"]) {
            [failedRepos addObject: repoStr];
        }
    }
    if ([failedRepos count] == 0) return;

    NSString *msg;
    if ([failedRepos count] == 1) {
        msg = [NSString stringWithFormat: @"Repository %@ has failing builds.", failedRepos[0]];
    } else {
        msg = [NSString stringWithFormat: @"%ld repositories have failing builds:\n%@",
                (long)[failedRepos count], [failedRepos componentsJoinedByString: @"\n"]];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText: @"Build Failed"];
    [alert setInformativeText: msg];
    [alert addButtonWithTitle: @"View on GitHub"];
    [alert addButtonWithTitle: @"Dismiss"];

    NSInteger result = [alert runModal];
    if (result == NSAlertFirstButtonReturn) {
        NSString *first = failedRepos[0];
        NSArray *parts = [first componentsSeparatedByString: @"/"];
        if ([parts count] == 2) {
            NSString *urlStr = [NSString stringWithFormat:
                @"https://github.com/%@/%@/actions", parts[0], parts[1]];
            [[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: urlStr]];
        }
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

    const CGFloat w = 380;
    const CGFloat h = 340;
    const CGFloat pad = 12;
    const CGFloat sw = w - pad * 2;

    NSRect contentRect = NSMakeRect(0, 0, w, h);
    _configPanel = [[NSWindow alloc] initWithContentRect: contentRect
                                               styleMask: NSTitledWindowMask | NSClosableWindowMask
                                                 backing: NSBackingStoreRetained
                                                   defer: NO];
    [_configPanel setTitle: @"Build Monitor Configuration"];
    [_configPanel setDelegate: self];

    NSView *content = [[NSView alloc] initWithFrame: contentRect];

    NSTextField *label;

    label = [[NSTextField alloc] initWithFrame: NSMakeRect(pad, h - 24, sw, 18)];
    [label setStringValue: @"Repositories (one per line, format: owner/repo):"];
    [label setBezeled: NO];
    [label setDrawsBackground: NO];
    [label setEditable: NO];
    [label setSelectable: NO];
    [content addSubview: label];

    NSRect scrollFrame = NSMakeRect(pad, 104, sw, h - 140);
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame: scrollFrame];
    [scrollView setHasVerticalScroller: YES];
    [scrollView setBorderType: NSBezelBorder];
    [scrollView setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];

    _reposTextView = [[NSTextView alloc] initWithFrame: NSMakeRect(0, 0, sw, h - 140)];
    [_reposTextView setMinSize: NSMakeSize(0, h - 140)];
    [_reposTextView setMaxSize: NSMakeSize(FLT_MAX, FLT_MAX)];
    [_reposTextView setVerticallyResizable: YES];
    [_reposTextView setAutoresizingMask: NSViewWidthSizable];
    [_reposTextView setFont: [NSFont userFixedPitchFontOfSize: 12]];
    [scrollView setDocumentView: _reposTextView];
    [content addSubview: scrollView];

    if ([_repos count] > 0) {
        [_reposTextView setString: [_repos componentsJoinedByString: @"\n"]];
    }

    label = [[NSTextField alloc] initWithFrame: NSMakeRect(pad, 80, sw, 18)];
    [label setStringValue: @"Token (optional, for private repos):"];
    [label setBezeled: NO];
    [label setDrawsBackground: NO];
    [label setEditable: NO];
    [label setSelectable: NO];
    [content addSubview: label];

    _tokenField = [[NSTextField alloc] initWithFrame: NSMakeRect(pad, 52, sw, 22)];
    [_tokenField setStringValue: _token ?: @""];
    [content addSubview: _tokenField];

    NSButton *saveBtn = [[NSButton alloc] initWithFrame: NSMakeRect(w - 102, 15, 80, 24)];
    [saveBtn setTitle: @"Save"];
    [saveBtn setButtonType: NSMomentaryPushInButton];
    [saveBtn setBezelStyle: NSRoundedBezelStyle];
    [saveBtn setTarget: self];
    [saveBtn setAction: @selector(saveConfigPanel:)];
    [content addSubview: saveBtn];

    NSButton *cancelBtn = [[NSButton alloc] initWithFrame: NSMakeRect(w - 190, 15, 80, 24)];
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
    NSString *text = [[_reposTextView textStorage] string];
    NSArray *lines = [text componentsSeparatedByString: @"\n"];
    NSMutableArray *repos = [NSMutableArray array];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed length] > 0) {
            [repos addObject: trimmed];
        }
    }
    _repos = [repos copy];
    _token = [_tokenField stringValue];

    NSMutableDictionary *newFailures = [NSMutableDictionary dictionary];
    for (NSString *repoStr in _repos) {
        NSString *old = [_lastFailures objectForKey: repoStr];
        if (old) {
            [newFailures setObject: old forKey: repoStr];
        }
    }
    _lastFailures = newFailures;

    [self saveConfig];
    [_configPanel close];
    _configPanel = nil;

    [_repoStatuses removeAllObjects];
    _hasAnyFailure = NO;
    _hasAnyRunning = NO;
    _fetchError = NO;

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


#pragma mark - GSMenuExtra

- (void)setContext:(GSMenuExtraContext *)context
{
    _context = context;
}

- (void)menuExtraDidLoad
{
    [self loadConfig];

    if ([_repos count] > 0) {
        [self pollGitHub];
        _timer = [NSTimer scheduledTimerWithTimeInterval: POLL_INTERVAL
                                                  target: self
                                                selector: @selector(pollGitHub)
                                                userInfo: nil
                                                 repeats: YES];
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

    if ([_repos count] == 0) {
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
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle: @"Some repos unreachable"
                                                      action: NULL
                                               keyEquivalent: @""];
        [item setEnabled: NO];
        [m addItem: item];
    }

    for (NSString *repoStr in _repos) {
        NSString *status = [_repoStatuses objectForKey: repoStr] ?: @"unknown";
        NSString *icon;
        if ([status isEqualToString: @"failure"]) {
            icon = [NSString stringWithUTF8String: "\xE2\x9C\x98"]; // ✘
        } else if ([status isEqualToString: @"running"]) {
            icon = [NSString stringWithUTF8String: "\xE2\x97\x8B"]; // ○
        } else if ([status isEqualToString: @"success"]) {
            icon = [NSString stringWithUTF8String: "\xE2\x9C\x93"]; // ✓
        } else if ([status isEqualToString: @"error"]) {
            icon = @"!";
        } else {
            icon = @"-";
        }

        NSString *title = [NSString stringWithFormat: @"%@ %@", icon, repoStr];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle: title
                                                      action: @selector(openRepoActions:)
                                               keyEquivalent: @""];
        [item setTarget: self];
        [item setRepresentedObject: repoStr];
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

    return m;
}

- (NSImage *)image { return nil; }

- (NSString *)title
{
    if ([_repos count] == 0) return @"?";
    if (_fetchError) return @"?";
    if (_hasAnyFailure) return [NSString stringWithUTF8String: "\xE2\x9C\x98"]; // ✘
    if (_hasAnyRunning) return [NSString stringWithUTF8String: "\xE2\x97\x8B"]; // ○
    return [NSString stringWithUTF8String: "\xE2\x9C\x93"]; // ✓
}

- (void)openRepoActions:(id)sender
{
    NSString *repoStr = [sender representedObject];
    NSArray *parts = [repoStr componentsSeparatedByString: @"/"];
    if ([parts count] == 2) {
        NSString *urlStr = [NSString stringWithFormat: @"https://github.com/%@/%@/actions",
                             parts[0], parts[1]];
        [[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: urlStr]];
    }
}

@end

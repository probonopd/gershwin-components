#import "BuildMonitorExtra.h"
#import "GSMenuExtraContext.h"

#import <objc/runtime.h>

static const char kRepoKey;
static const char kDataKey;
static const char kStatusCodeKey;

#define POLL_INTERVAL 60.0
#define CONFIG_PREFIX @"BuildMonitor."

static NSString *ConfigKey(NSString *key)
{
    return [CONFIG_PREFIX stringByAppendingString: key];
}

@interface BuildMonitorExtra () <NSWindowDelegate, NSURLConnectionDelegate>
{
    GSMenuExtraContext *_context;

    NSArray *_repos;
    int _repoCount;
    NSString *_token;
    NSMutableDictionary *_lastFailures;

    NSMutableDictionary *_repoStatuses;
    BOOL _hasAnyFailure;
    BOOL _hasAnyRunning;
    BOOL _fetchError;
    BOOL _anyNewFailure;
    BOOL _rateLimited;

    NSPanel *_configPanel;
    NSTextView *_reposTextView;
    NSTextField *_tokenField;

    NSMutableDictionary *_pendingRepos;
    BOOL _running;
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
    _repoCount = (int)[_repos count];
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

- (void)pollGitHub
{
    @try {
        if (!_running) return;
        _hasAnyFailure = NO;
        _hasAnyRunning = NO;
        _fetchError = NO;
        _anyNewFailure = NO;
        _rateLimited = NO;

        if (_repoCount == 0) {
            [_context invalidatePresentation];
            return;
        }

        if (!_repoStatuses) _repoStatuses = [NSMutableDictionary dictionary];
        if (!_pendingRepos) _pendingRepos = [NSMutableDictionary dictionary];

        [_pendingRepos removeAllObjects];

        for (NSString *repoStr in _repos) {
            NSArray *parts = [repoStr componentsSeparatedByString: @"/"];
            if ([parts count] != 2) continue;
            [_pendingRepos setObject: repoStr forKey: repoStr];

            NSString *urlStr = [NSString stringWithFormat: @"https://api.github.com/repos/%@/%@/actions/runs?per_page=5",
                                 parts[0], parts[1]];

            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL: [NSURL URLWithString: urlStr]];
            if ([_token length] > 0) {
                [req setValue: [NSString stringWithFormat: @"token %@", _token] forHTTPHeaderField: @"Authorization"];
            }
            [req setValue: @"BuildMonitorExtra/1.0" forHTTPHeaderField: @"User-Agent"];

            NSURLConnection *conn = [NSURLConnection connectionWithRequest: req delegate: self];
            objc_setAssociatedObject(conn, &kRepoKey, repoStr, OBJC_ASSOCIATION_RETAIN);
            objc_setAssociatedObject(conn, &kDataKey, [NSMutableData data], OBJC_ASSOCIATION_RETAIN);
        }
    } @catch (NSException *e) {
        NSLog(@"BuildMonitorExtra: exception in pollGitHub: %@", e);
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
    NSMutableData *data = objc_getAssociatedObject(connection, &kDataKey);
    [data setLength: 0];
    NSInteger statusCode = 0;
    if ([response isKindOfClass: [NSHTTPURLResponse class]]) {
        statusCode = [(NSHTTPURLResponse *)response statusCode];
    }
    objc_setAssociatedObject(connection, &kStatusCodeKey, @(statusCode), OBJC_ASSOCIATION_RETAIN);
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
    NSMutableData *existing = objc_getAssociatedObject(connection, &kDataKey);
    [existing appendData: data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
    NSString *repoStr = objc_getAssociatedObject(connection, &kRepoKey);
    NSMutableData *responseData = objc_getAssociatedObject(connection, &kDataKey);
    NSString *json = [[NSString alloc] initWithData: responseData encoding: NSUTF8StringEncoding];

    if (json) {
        NSData *data = [json dataUsingEncoding: NSUTF8StringEncoding];
        NSError *err = nil;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData: data options: 0 error: &err];
        if (dict && [dict isKindOfClass: [NSDictionary class]]) {
            NSArray *runs = [dict objectForKey: @"workflow_runs"];
            if (runs) {
                BOOL repoHasRunning = NO;
                BOOL repoHasFailure = NO;
                BOOL repoHasSuccess = NO;
                NSMutableArray *currentFailureIDs = [NSMutableArray array];
                NSMutableSet *seenWorkflows = [NSMutableSet set];

                for (NSDictionary *run in runs) {
                    NSNumber *wfID = [run objectForKey: @"workflow_id"];
                    if (wfID) {
                        if ([seenWorkflows containsObject: wfID]) continue;
                        [seenWorkflows addObject: wfID];
                    }

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
                        _anyNewFailure = YES;
                        break;
                    }
                }

                NSString *joined = [currentFailureIDs componentsJoinedByString: @";"];
                if ([joined length] > 0) {
                    [_lastFailures setObject: joined forKey: repoStr];
                } else {
                    [_lastFailures removeObjectForKey: repoStr];
                }

                [_pendingRepos removeObjectForKey: repoStr];
                if ([_pendingRepos count] == 0) {
                    [self finishPoll];
                }
                return;
            }

            NSNumber *statusCodeNum = objc_getAssociatedObject(connection, &kStatusCodeKey);
            NSInteger statusCode = [statusCodeNum integerValue];
            if ((statusCode == 403 || statusCode == 429) &&
                [[dict objectForKey: @"message"] rangeOfString: @"rate limit"].location != NSNotFound) {
                _rateLimited = YES;
            }
        }
    }

    [_repoStatuses setObject: @"error" forKey: repoStr];
    _fetchError = YES;
    [_pendingRepos removeObjectForKey: repoStr];
    if ([_pendingRepos count] == 0) {
        [self finishPoll];
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
    NSString *repoStr = objc_getAssociatedObject(connection, &kRepoKey);
    [_repoStatuses setObject: @"error" forKey: repoStr];
    _fetchError = YES;

    [_pendingRepos removeObjectForKey: repoStr];
    if ([_pendingRepos count] == 0) {
        [self finishPoll];
    }
}

- (void)finishPoll
{
    @try {
        if (!_running) return;
        [self saveConfig];
        [_context invalidatePresentation];

        if (_anyNewFailure) {
            [self showFailureAlert];
        }
        if (_rateLimited) {
            [self showRateLimitAlert];
        }
    } @catch (NSException *e) {
        NSLog(@"BuildMonitorExtra: exception in finishPoll: %@", e);
    }
}

- (void)showFailureAlert
{
    /* Commented out: no dialog on build failure.
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
    */
}

- (void)showRateLimitAlert
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText: @"GitHub API rate limit exceeded"];
    [alert setInformativeText: @"The GitHub API rate limit has been reached. Build status updates will resume when the rate limit resets. Consider adding a personal access token in the Build Monitor configuration for a higher rate limit."];
    [alert addButtonWithTitle: @"Configure"];
    [alert addButtonWithTitle: @"Dismiss"];

    NSInteger result = [alert runModal];
    if (result == NSAlertFirstButtonReturn) {
        [self showConfigPanel];
    }
}

#pragma mark - Config Panel

- (void)showConfigPanel
{
    if (_configPanel) {
        [_configPanel setInitialFirstResponder: _reposTextView];
        [_configPanel makeKeyAndOrderFront: nil];
        [NSApp activateIgnoringOtherApps: YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self->_configPanel makeKeyWindow];
            [self->_configPanel makeFirstResponder: self->_reposTextView];
        });
        return;
    }

    const CGFloat w = 380;
    const CGFloat h = 340;
    const CGFloat pad = 12;
    const CGFloat sw = w - pad * 2;

    NSRect contentRect = NSMakeRect(0, 0, w, h);
    _configPanel = [[NSPanel alloc] initWithContentRect: contentRect
                                             styleMask: NSTitledWindowMask | NSClosableWindowMask
                                               backing: NSBackingStoreBuffered
                                                 defer: NO];
    [_configPanel setTitle: @"Build Monitor Configuration"];
    [_configPanel setBecomesKeyOnlyIfNeeded: NO];
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
    [_reposTextView setEditable: YES];
    [_reposTextView setSelectable: YES];
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
    [_configPanel recalculateKeyViewLoop];
    [_configPanel setInitialFirstResponder: _reposTextView];
    [_configPanel center];
    [_configPanel makeKeyAndOrderFront: nil];
    [NSApp activateIgnoringOtherApps: YES];

    [self performSelector:@selector(focusConfigPanel)
               withObject:nil
               afterDelay:0.05
                  inModes:@[NSDefaultRunLoopMode, NSModalPanelRunLoopMode]];
    [self performSelector:@selector(focusConfigPanel)
               withObject:nil
               afterDelay:0.2
                  inModes:@[NSDefaultRunLoopMode, NSModalPanelRunLoopMode]];
}

- (void)focusConfigPanel
{
    if (_configPanel) {
        [_configPanel makeKeyWindow];
        [_configPanel makeFirstResponder: _reposTextView];
    }
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
    _repoCount = (int)[_repos count];
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
    @try {
        _running = YES;
        NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
        [defs registerDefaults: @{
            ConfigKey(@"repos"): @[@"gershwin-desktop/gershwin-desktop",
                                    @"gershwin-desktop/gershwin-components",
                                    @"gershwin-desktop/gershwin-developer",
                                    @"gershwin-desktop/gershwin-workspace",
                                    @"gershwin-desktop/gershwin-eau-theme",
                                    @"gershwin-desktop/gershwin-windowmanager",
                                    @"gershwin-desktop/gershwin-textedit",
                                    @"gershwin-desktop/gershwin-systempreferences",
                                    @"gershwin-desktop/gershwin-terminal",
                                    @"gershwin-desktop/gershwin-system"]
        }];

        [self loadConfig];

        if ([_repos count] > 0) {
            [self pollGitHub];
        }
    } @catch (NSException *e) {
        NSLog(@"BuildMonitorExtra: exception in menuExtraDidLoad: %@", e);
        _running = NO;
        _context = nil;
        _repos = nil;
        _repoCount = 0;
        _token = nil;
        _lastFailures = nil;
        _repoStatuses = nil;
        _pendingRepos = nil;
        _configPanel = nil;
        _reposTextView = nil;
        _tokenField = nil;
    }
}

- (void)menuExtraWillUnload
{
    _running = NO;
}

- (NSMenu *)menu
{
    NSMenu *m = [[NSMenu alloc] initWithTitle: @"BuildMonitor"];

    if (_repoCount == 0) {
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
            icon = @"!";
        } else if ([status isEqualToString: @"running"]) {
            icon = [NSString stringWithUTF8String: "\xE2\x97\x8B"]; // ○
        } else if ([status isEqualToString: @"success"]) {
            icon = [NSString stringWithUTF8String: "\xE2\x9C\x93"]; // ✓
        } else if ([status isEqualToString: @"error"]) {
            icon = @"?";
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
                                                  keyEquivalent: @""];
    [refreshItem setTarget: self];
    [m addItem: refreshItem];

    NSMenuItem *configureItem = [[NSMenuItem alloc] initWithTitle: @"Configure..."
                                                          action: @selector(showConfigPanel)
                                                   keyEquivalent: @""];
    [configureItem setTarget: self];
    [m addItem: configureItem];

    return m;
}

- (NSString *)statusSymbol
{
    if (_repoCount == 0) return @"?";
    if (_fetchError) return @"?";
    if (_hasAnyFailure) return @"!";
    if (_hasAnyRunning) return [NSString stringWithUTF8String: "\xE2\x97\x8B"]; // ○
    return [NSString stringWithUTF8String: "\xE2\x9C\x93"]; // ✓
}

- (NSImage *)image
{
    NSString *symbol = [self statusSymbol];
    NSSize size = NSMakeSize(14, 14);
    NSImage *img = [[NSImage alloc] initWithSize: size];
    [img lockFocus];
    [[NSColor clearColor] set];
    NSRectFill(NSMakeRect(0, 0, size.width, size.height));
    [[NSColor blackColor] set];
    NSDictionary *attrs = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize: 11] };
    NSSize ts = [symbol sizeWithAttributes: attrs];
    NSPoint tp = NSMakePoint((size.width - ts.width) / 2, (size.height - ts.height) / 2 - 0.5);
    [symbol drawAtPoint: tp withAttributes: attrs];
    [img unlockFocus];
    return img;
}

- (NSString *)title
{
    return @"";
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

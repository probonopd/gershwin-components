#import "GSUTMMainWindowController.h"
#import "GSUTMConfiguration.h"
#import "GSUTMAssistant.h"
#import "AppearanceMetrics.h"

@interface VMTableView : NSTableView @end
@implementation VMTableView
- (void)keyDown:(NSEvent *)event
{
    NSString *chars = [event characters];
    if ([chars length] == 1) {
        unichar c = [chars characterAtIndex:0];
        if (c == NSDeleteCharacter || c == 0x7F) {
            id del = [self delegate];
            if ([del respondsToSelector:@selector(_ctxRemove:)])
                [del performSelector:@selector(_ctxRemove:) withObject:self];
            return;
        }
    }
    [super keyDown:event];
}
@end

@interface GSUTMMainWindowController () <NSTableViewDataSource, NSTableViewDelegate>
{
    GSUTMConfiguration *_configuration;
    GSUTMVirtualMachine *_virtualMachine;
    GSUTMConsoleController *_consoleController;
    NSString *_configPath;
    NSButton *_startStopButton;
    NSTextField *_statusLabel;
    NSMutableArray *_vmEntries;
    NSTableView *_tableView;
    BOOL _vmLoaded;
}

@end

@implementation GSUTMMainWindowController

- (instancetype)init
{
    self = [super initWithWindow:nil];
    if (self) {
        _configuration = [[GSUTMConfiguration alloc] init];
        _vmEntries = [[NSMutableArray alloc] init];
        _consoleController = [[GSUTMConsoleController alloc] init];
        [_consoleController retain];
        [self loadWindow];
        [self windowDidLoad];
    }
    return self;
}

- (GSUTMVirtualMachine *)virtualMachine { return _virtualMachine; }
- (GSUTMConsoleController *)consoleController { return _consoleController; }

- (NSButton *)buttonWithTitle:(NSString *)title
                        frame:(NSRect)frame
                       action:(SEL)action
{
    NSButton *btn = [[NSButton alloc] initWithFrame:frame];
    [btn setTitle:title];
    [btn setBezelStyle:NSRoundedBezelStyle];
    [btn setButtonType:NSMomentaryPushInButton];
    [btn setTarget:self];
    [btn setAction:action];
    [btn setFont:[NSFont systemFontOfSize:12]];
    return btn;
}

- (NSTextField *)labelWithTitle:(NSString *)title frame:(NSRect)frame
{
    NSTextField *lbl = [[NSTextField alloc] initWithFrame:frame];
    [lbl setStringValue:title];
    [lbl setBezeled:NO];
    [lbl setEditable:NO];
    [lbl setSelectable:NO];
    [lbl setBordered:NO];
    [lbl setDrawsBackground:NO];
    [lbl setFont:[NSFont systemFontOfSize:11]];
    [lbl setAlignment:NSRightTextAlignment];
    [lbl setTextColor:[NSColor controlTextColor]];
    return lbl;
}

- (NSTextField *)fieldWithFrame:(NSRect)frame
{
    NSTextField *tf = [[NSTextField alloc] initWithFrame:frame];
    [tf setBezeled:YES];
    [tf setBordered:YES];
    [tf setEditable:YES];
    [tf setSelectable:YES];
    [tf setFont:[NSFont systemFontOfSize:11]];
    return tf;
}

/* Add a labeled row to a box content view */
- (void)addRowWithLabel:(NSString *)label
                  field:(NSTextField *)field
                   ypos:(CGFloat *)y
                 toView:(NSView *)parent
                  width:(CGFloat)w
{
    CGFloat lw = 55, gap = 5, fw = w - lw - gap - 10;
    [self labelWithTitle:label frame:NSMakeRect(8, *y, lw, 18)];
    /* Actually add the label we just created */
    NSTextField *lbl = [self labelWithTitle:label frame:NSMakeRect(8, *y - 1, lw, 20)];
    [lbl setAlignment:NSLeftTextAlignment];
    [parent addSubview:lbl];
    if (field) {
        NSRect fr = NSMakeRect(lw + gap, *y - 1, fw, 22);
        [field setFrame:fr];
        [parent addSubview:field];
    }
    *y -= 26;
}

- (NSBox *)sectionBoxWithTitle:(NSString *)title
                         frame:(NSRect)frame
                        inView:(NSView *)parent
{
    NSBox *box = [[NSBox alloc] initWithFrame:frame];
    [box setTitle:title];
    [box setBoxType:NSBoxPrimary];
    [box setTitlePosition:NSAtTop];
    [box setBorderType:NSLineBorder];
    [box setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [parent addSubview:box];
    return box;
}

- (void)loadWindow
{
    NSRect screenRect = [[NSScreen mainScreen] frame];
    CGFloat winW = 500, winH = 300;
    NSRect winRect = NSMakeRect(
        (screenRect.size.width - winW) / 2,
        (screenRect.size.height - winH) / 2,
        winW, winH);

    NSUInteger style = NSTitledWindowMask | NSClosableWindowMask |
                       NSMiniaturizableWindowMask | NSResizableWindowMask;

    NSWindow *window = [[NSWindow alloc] initWithContentRect:winRect
                                                   styleMask:style
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setTitle:@"SystemEmulator"];
    [window setMinSize:NSMakeSize(400, 200)];
    [[window contentView] setAutoresizesSubviews:YES];

    NSView *content = [window contentView];

    CGFloat bottomH = METRICS_BUTTON_HEIGHT + METRICS_SPACE_16;
    CGFloat by = (bottomH - METRICS_BUTTON_HEIGHT) / 2;

    /* VM List */
    _tableView = [[VMTableView alloc] initWithFrame:NSMakeRect(0, bottomH, winW, winH - bottomH)];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [[col headerCell] setStringValue:@"Virtual Machines"];
    [col setWidth:winW - 20];
    [col setEditable:NO];

    /* Use NSButtonCell for image + text display */
    NSButtonCell *btnCell = [[NSButtonCell alloc] init];
    [btnCell setBordered:NO];
    [btnCell setImagePosition:NSImageLeft];
    [btnCell setFont:[NSFont systemFontOfSize:12]];
    [col setDataCell:btnCell];

    [_tableView addTableColumn:col];
    [_tableView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_tableView setHeaderView:nil];
    [_tableView setRowHeight:40];
    [_tableView setDataSource:self];
    [_tableView setDelegate:self];
    [_tableView setTarget:self];
    [_tableView setAction:@selector(_selectionChanged)];
    [_tableView setDoubleAction:@selector(_ctxStart:)];

    /* Context menu for the table */
    NSMenu *ctxMenu = [[NSMenu alloc] init];
    [ctxMenu setAutoenablesItems:NO];
    NSMenuItem *mi;
    mi = [[NSMenuItem alloc] initWithTitle:@"Start" action:@selector(_ctxStart:) keyEquivalent:@""];
    [mi setTarget:self]; [mi setEnabled:YES]; [ctxMenu addItem:mi];
    mi = [[NSMenuItem alloc] initWithTitle:@"Edit Configuration..." action:@selector(_ctxEdit:) keyEquivalent:@""];
    [mi setTarget:self]; [mi setEnabled:YES]; [ctxMenu addItem:mi];
    [ctxMenu addItem:[NSMenuItem separatorItem]];
    mi = [[NSMenuItem alloc] initWithTitle:@"Remove from List" action:@selector(_ctxRemove:) keyEquivalent:@""];
    [mi setTarget:self]; [mi setEnabled:YES]; [ctxMenu addItem:mi];
    mi = [[NSMenuItem alloc] initWithTitle:@"Copy Command Line" action:@selector(_ctxCopyCommand:) keyEquivalent:@""];
    [mi setTarget:self]; [mi setEnabled:YES]; [ctxMenu addItem:mi];
    [_tableView setMenu:ctxMenu];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, bottomH, winW, winH - bottomH)];
    [scroll setDocumentView:_tableView];
    [scroll setHasVerticalScroller:YES];
    [scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [content addSubview:scroll];

    /* Bottom bar — stays at bottom when window resizes */
    NSView *bottomBar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, winW, bottomH)];
    [bottomBar setAutoresizingMask:NSViewWidthSizable];

    CGFloat bx = METRICS_CONTENT_SIDE_MARGIN;
    _startStopButton = [self buttonWithTitle:@"Start VM"
                                       frame:NSMakeRect(bx, by, 100, METRICS_BUTTON_HEIGHT)
                                      action:@selector(toggleVM:)];
    [bottomBar addSubview:_startStopButton];
    bx += 108;

    NSButton *consoleBtn = [self buttonWithTitle:@"Console"
                                           frame:NSMakeRect(bx, by, 90, METRICS_BUTTON_HEIGHT)
                                          action:@selector(openConsole:)];
    [bottomBar addSubview:consoleBtn];

    [_startStopButton setEnabled:NO];

    _statusLabel = [self labelWithTitle:@"Status: Stopped"
                                  frame:NSMakeRect(winW - 200, by, 190, METRICS_BUTTON_HEIGHT)];
    [_statusLabel setAlignment:NSRightTextAlignment];
    [_statusLabel setAutoresizingMask:NSViewMinXMargin];
    [bottomBar addSubview:_statusLabel];

    [content addSubview:bottomBar];

    [self setWindow:window];
}

- (void)syncConfigFromUI
{
    /* Name is from the config or window title */
}

- (void)_selectionChanged
{
    BOOL hasSelection = ([_tableView selectedRow] >= 0);
    [_startStopButton setEnabled:hasSelection];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv
{
    return [_vmEntries count];
}

- (NSImage *)_iconForName:(NSString *)name
{
    if ([name length] == 0) return nil;
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *exact = [bundle pathForResource:name ofType:@"png" inDirectory:@"Icons"];
    if ([exact length] > 0) {
        NSImage *image = [[[NSImage alloc] initWithContentsOfFile:exact] autorelease];
        if (image) return image;
    }
    /* The shipped icon set uses mixed-case filenames (e.g. SUSE.png), so
       fall back to a case-insensitive match. */
    NSString *iconsDir = [bundle pathForResource:@"Icons" ofType:nil];
    if ([iconsDir length] > 0) {
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:iconsDir error:NULL];
        NSString *wanted = [name lowercaseString];
        for (NSString *file in files) {
            if ([[[file stringByDeletingPathExtension] lowercaseString] isEqualToString:wanted]) {
                NSImage *image = [[[NSImage alloc]
                    initWithContentsOfFile:[iconsDir stringByAppendingPathComponent:file]] autorelease];
                if (image) return image;
            }
        }
    }
    return nil;
}

/* Pick the most specific icon from the shipped set whose words all appear
   in the VM name (e.g. "Windows 11" -> windows-11.png, "gershwin on debian"
   -> debian.png). Icon names containing hyphens are treated word-wise so
   that "mac" does not trump "macos" for a macOS guest. */
- (NSString *)_guessIconNameForName:(NSString *)name
{
    if ([name length] == 0) return nil;
    NSCharacterSet *nonWord = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSString *normalizedName = [[name lowercaseString]
        stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    normalizedName = [normalizedName stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    NSArray *nameTokens = [normalizedName componentsSeparatedByCharactersInSet:nonWord];
    NSMutableSet *nameWords = [NSMutableSet setWithCapacity:[nameTokens count]];
    for (NSString *token in nameTokens) {
        if ([token length] > 0) [nameWords addObject:token];
    }

    NSString *iconsDir = [[NSBundle mainBundle] pathForResource:@"Icons" ofType:nil];
    if ([iconsDir length] == 0) return nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:iconsDir error:NULL];

    NSString *best = nil;
    NSUInteger bestLength = 0;
    for (NSString *file in files) {
        if (![[file pathExtension] isEqualToString:@"png"]) continue;
        NSString *base = [[file stringByDeletingPathExtension] lowercaseString];
        base = [base stringByReplacingOccurrencesOfString:@"-" withString:@" "];
        base = [base stringByReplacingOccurrencesOfString:@"_" withString:@" "];
        NSArray *iconTokens = [base componentsSeparatedByCharactersInSet:nonWord];
        BOOL allPresent = YES;
        for (NSString *token in iconTokens) {
            if ([token length] > 0 && ![nameWords containsObject:token]) {
                allPresent = NO;
                break;
            }
        }
        if (allPresent && [base length] > bestLength) {
            best = [file stringByDeletingPathExtension];
            bestLength = [base length];
        }
    }
    return best;
}

- (NSImage *)_iconForConfig:(GSUTMConfiguration *)cfg
{
    NSString *iconName = cfg.iconName;
    /* AppIcon.icns is the generic placeholder; only honour a real asset. */
    if ([iconName length] > 0 && ![iconName isEqualToString:@"AppIcon.icns"]) {
        NSImage *icon = [self _iconForName:iconName];
        if (icon) return icon;
    }
    NSString *guessed = [self _guessIconNameForName:cfg.name];
    if ([guessed length] > 0) {
        NSImage *icon = [self _iconForName:guessed];
        if (icon) return icon;
    }
    return nil;
}

- (void)tableView:(NSTableView *)tv willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)col row:(NSInteger)row
{
    GSUTMConfiguration *cfg = [_vmEntries objectAtIndex:row];
    if ([cell respondsToSelector:@selector(setImage:)]) {
        NSImage *icon = [self _iconForConfig:cfg];
        if (!icon) {
            icon = [NSImage imageNamed:@"NSApplicationIcon"];
        }
        [icon setSize:NSMakeSize(32, 32)];
        [cell setImage:icon];
    }
    if ([cell respondsToSelector:@selector(setTitle:)]) {
        GSUTMConfiguration *cfg = [_vmEntries objectAtIndex:row];
        NSString *arch = cfg.architecture ?: @"x86_64";
        NSString *drives = [NSString stringWithFormat:@"%lu drive(s)", (unsigned long)[cfg.drives count]];
        [cell setTitle:[NSString stringWithFormat:@"  %@\n  %@, %lu MB, %@",
                        cfg.name, arch, (unsigned long)cfg.memorySize, drives]];
    }
}

- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row
{
    return @"";
}

#pragma mark - NSTableViewDelegate

- (void)tableViewSelectionDidChange:(NSNotification *)note
{
    [self _selectionChanged];
}

- (NSMenu *)tableView:(NSTableView *)tv menuForTableColumn:(NSTableColumn *)col row:(NSInteger)row
{
    NSMenu *menu = [[NSMenu alloc] init];
    [menu setAutoenablesItems:NO];
    NSMenuItem *mi;

    mi = [[NSMenuItem alloc] initWithTitle:@"Start" action:@selector(_ctxStart:) keyEquivalent:@""];
    [mi setTarget:self]; [mi setEnabled:YES]; [mi setRepresentedObject:[NSNumber numberWithInteger:row]]; [menu addItem:mi];
    mi = [[NSMenuItem alloc] initWithTitle:@"Copy Command Line" action:@selector(_ctxCopyCommand:) keyEquivalent:@""];
    [mi setTarget:self]; [mi setEnabled:YES]; [menu addItem:mi];
    mi = [[NSMenuItem alloc] initWithTitle:@"Edit Configuration..." action:@selector(_ctxEdit:) keyEquivalent:@""];
    [mi setTarget:self]; [mi setEnabled:YES]; [mi setRepresentedObject:[NSNumber numberWithInteger:row]]; [menu addItem:mi];
    [menu addItem:[NSMenuItem separatorItem]];
    mi = [[NSMenuItem alloc] initWithTitle:@"Remove from List" action:@selector(_ctxRemove:) keyEquivalent:@""];
    [mi setTarget:self]; [mi setEnabled:YES]; [mi setRepresentedObject:[NSNumber numberWithInteger:row]]; [menu addItem:mi];

    return [menu autorelease];
}

- (void)syncUIToConfig
{
}

- (void)toggleVM:(id)sender
{
    if (_virtualMachine && _virtualMachine.state != GSUTMMachineStateStopped) {
        [self stopVM];
    } else {
        [self startVM];
    }
}

- (void)startVM
{
    if (!_vmLoaded) return;
    NSInteger sel = [_tableView selectedRow];
    if (sel < 0) return;
    GSUTMConfiguration *cfg = [_vmEntries objectAtIndex:sel];
    if (_virtualMachine && _virtualMachine.state != GSUTMMachineStateStopped) return;

    /* Show notes dialog if the config has notes */
    if ([cfg.notes length] > 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:cfg.name];
        [alert setInformativeText:cfg.notes];
        [alert addButtonWithTitle:@"Continue"];
        [alert addButtonWithTitle:@"Cancel"];
        NSInteger result = [alert runModal];
        [alert release];
        if (result != NSAlertFirstButtonReturn) return;
    }

    /* Resolve relative drive paths against the config's base URL */
    if (cfg.baseURL) {
        [cfg resolveDrivePathsWithBaseURL:cfg.baseURL];
    }

    _virtualMachine = [[GSUTMVirtualMachine alloc] initWithConfiguration:cfg];

    __unsafe_unretained GSUTMMainWindowController *weakSelf = self;
    _virtualMachine.onStateChange = ^(GSUTMMachineState state) {
        GSUTMMainWindowController *strong = weakSelf;
        if (strong) {
            [strong performSelectorOnMainThread:@selector(handleStateChange:)
                                    withObject:[NSNumber numberWithInt:state]
                                 waitUntilDone:NO];
        }
    };
    _virtualMachine.onConsoleOutput = ^(NSData *data) {
        GSUTMMainWindowController *strong = weakSelf;
        if (strong) {
            [strong->_consoleController appendData:data];
        }
    };

    NSError *error = nil;
    if (![_virtualMachine startWithError:&error]) {
        NSString *errMsg = [error localizedDescription] ?: @"Unknown error";
        NSString *binPath = [_configuration qemuBinary];
        NSString *msg = [NSString stringWithFormat:@"%@\n\nBinary: %@", errMsg, binPath];
        NSLog(@"ERROR: Failed to start VM: %@", errMsg);
        NSRunAlertPanel(@"Error Starting VM", msg, @"OK", nil, nil);
        _virtualMachine = nil;
        return;
    }

    [self saveConfig];
}

- (void)stopVM
{
    if (!_virtualMachine || _virtualMachine.state == GSUTMMachineStateStopped) return;
    [_virtualMachine stop];
    _virtualMachine = nil;
    [self updateUIForState:GSUTMMachineStateStopped];
}

- (void)handleStateChange:(NSNumber *)num
{
    [self updateUIForState:(GSUTMMachineState)[num intValue]];
}

- (void)updateUIForState:(GSUTMMachineState)state
{
    switch (state) {
        case GSUTMMachineStateStopped:
            [_statusLabel setStringValue:@"Status: Stopped"];
            [_startStopButton setTitle:@"Start VM"];
            [_startStopButton setEnabled:YES];
            break;
        case GSUTMMachineStateStarting:
            [_statusLabel setStringValue:@"Status: Starting..."];
            [_startStopButton setTitle:@"Starting..."];
            [_startStopButton setEnabled:NO];
            break;
        case GSUTMMachineStateStarted:
            [_statusLabel setStringValue:@"Status: Running"];
            [_startStopButton setTitle:@"Stop VM"];
            [_startStopButton setEnabled:YES];
            break;
        case GSUTMMachineStateStopping:
            [_statusLabel setStringValue:@"Status: Stopping..."];
            [_startStopButton setTitle:@"Stopping..."];
            [_startStopButton setEnabled:NO];
            break;
        case GSUTMMachineStateError:
            [_statusLabel setStringValue:@"Status: Error"];
            [_startStopButton setTitle:@"Start VM"];
            [_startStopButton setEnabled:YES];
            break;
    }
}

- (void)openConsole:(id)sender
{
    if (!_consoleController) {
        _consoleController = [[GSUTMConsoleController alloc] init];
    }
    [_consoleController showWindow:sender];
}

/* ============== Config persistence ============== */

- (void)saveConfig
{
    [self syncConfigFromUI];
    if (!_configPath) {
        NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
        NSString *dir = [appSupport stringByAppendingPathComponent:@"SystemEmulator"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        }
        _configPath = [[dir stringByAppendingPathComponent:@"config.plist"] retain];
    }
    if (_configPath) {
        [_configuration saveToURL:[NSURL fileURLWithPath:_configPath] error:NULL];
    }
}

- (void)_deriveNameForConfig:(GSUTMConfiguration *)cfg fromURL:(NSURL *)url
{
    if ([[cfg.name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] == 0
        || [cfg.name isEqualToString:@"Virtual Machine"]) {
        NSString *dirName = [[url path] lastPathComponent];
        if ([dirName isEqualToString:@"config.plist"])
            dirName = [[[url URLByDeletingLastPathComponent] path] lastPathComponent];
        if ([dirName hasSuffix:@".utm"])
            dirName = [dirName substringToIndex:[dirName length] - 4];
        if ([dirName length] > 0)
            cfg.name = dirName;
    }
}

- (BOOL)_vmListContainsURL:(NSString *)path
{
    NSString *bundleDir = path;
    if ([[path lastPathComponent] isEqualToString:@"config.plist"])
        bundleDir = [path stringByDeletingLastPathComponent];
    for (GSUTMConfiguration *cfg in _vmEntries) {
        if ([cfg.baseURL.path isEqualToString:bundleDir]) return YES;
    }
    return NO;
}

- (void)loadConfigFromURL:(NSURL *)url
{
    NSURL *configURL = url;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;

    /* If it's a directory (.utm bundle), look for config.plist inside */
    if ([fm fileExistsAtPath:[url path] isDirectory:&isDir] && isDir) {
        NSURL *plistURL = [url URLByAppendingPathComponent:@"config.plist"];
        if ([fm fileExistsAtPath:[plistURL path]]) {
            configURL = plistURL;
        }
    }

    GSUTMConfiguration *loaded = [GSUTMConfiguration loadFromURL:configURL error:NULL];
    if (loaded) {
        if (_virtualMachine) {
            [_virtualMachine stop];
            _virtualMachine = nil;
        }
        _configuration = loaded;
        _configPath = [[configURL path] retain];
        _vmLoaded = YES;
        [_configuration retain];
        [self _deriveNameForConfig:_configuration fromURL:configURL];
        if (![self _vmListContainsURL:_configPath]) {
            [_vmEntries addObject:_configuration];
        }
        [_tableView reloadData];
        NSUInteger idx = [_vmEntries indexOfObject:_configuration];
        if (idx != NSNotFound)
            [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:idx] byExtendingSelection:NO];
        [self syncUIToConfig];
        [self _saveVMList];
    }
}

- (void)_saveVMList
{
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:[_vmEntries count]];
    for (GSUTMConfiguration *cfg in _vmEntries) {
        if (cfg.baseURL) [paths addObject:[cfg.baseURL path]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:paths forKey:@"VMList"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)_loadVMList
{
    NSArray *paths = [[NSUserDefaults standardUserDefaults] arrayForKey:@"VMList"];
    for (NSString *path in paths) {
        NSURL *url = [NSURL fileURLWithPath:path];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            GSUTMConfiguration *cfg = [GSUTMConfiguration loadFromURL:[url URLByAppendingPathComponent:@"config.plist"] error:NULL];
            if (cfg) {
                [self _deriveNameForConfig:cfg fromURL:[url URLByAppendingPathComponent:@"config.plist"]];
                [_vmEntries addObject:cfg];
            }
        }
    }
    if ([_vmEntries count] > 0) {
        _vmLoaded = YES;
        [_configuration release];
        _configuration = [[_vmEntries objectAtIndex:0] retain];
        [_tableView reloadData];
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self syncUIToConfig];
    }
}

- (void)loadConfig
{
    if (!_configPath) {
        NSString *appSupport = [NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
        _configPath = [[[appSupport stringByAppendingPathComponent:@"SystemEmulator"]
                        stringByAppendingPathComponent:@"config.plist"] retain];
    }
    GSUTMConfiguration *loaded = [GSUTMConfiguration loadFromURL:
                                  [NSURL fileURLWithPath:_configPath] error:NULL];
    if (loaded) {
        _configuration = loaded;
        [self syncUIToConfig];
    }
}

- (void)resetConfig
{
    if (_virtualMachine) {
        [_virtualMachine stop];
        _virtualMachine = nil;
    }
    [_configuration release];
    _configuration = [[GSUTMConfiguration alloc] init];
    [self syncUIToConfig];
    [self updateUIForState:GSUTMMachineStateStopped];
}

#pragma mark - Context menu actions

- (NSInteger)_rowFromSender:(id)sender
{
    if ([sender respondsToSelector:@selector(representedObject)]) {
        id obj = [sender representedObject];
        if (obj) return [obj integerValue];
    }
    if (sender == _tableView) {
        return [_tableView selectedRow];
    }
    return [_tableView clickedRow];
}

- (void)_ctxStart:(id)sender
{
    NSInteger row = [self _rowFromSender:sender];
    if (row >= 0) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [self startVM];
    }
}

- (NSString *)_formatQEMUArg:(NSString *)arg
{
    if ([arg rangeOfString:@" "].location != NSNotFound || [arg length] == 0)
        return [NSString stringWithFormat:@"'%@'", arg];
    return arg;
}

- (NSString *)_qemuCommandLineForConfig:(GSUTMConfiguration *)cfg
{
    if (cfg.baseURL) [cfg resolveDrivePathsWithBaseURL:cfg.baseURL];
    NSString *binary = [cfg qemuBinary];
    NSMutableArray *quoted = [NSMutableArray array];
    [quoted addObject:binary];
    for (NSString *arg in [cfg qemuArguments])
        [quoted addObject:[self _formatQEMUArg:arg]];
    return [quoted componentsJoinedByString:@" "];
}

- (void)_ctxCopyCommand:(id)sender
{
    NSInteger row = [self _rowFromSender:sender];
    if (row < 0) return;
    GSUTMConfiguration *cfg = [_vmEntries objectAtIndex:row];
    NSString *cmd = [self _qemuCommandLineForConfig:cfg];
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb declareTypes:@[NSStringPboardType] owner:nil];
    [pb setString:cmd forType:NSStringPboardType];
}

- (void)_ctxEdit:(id)sender
{
    NSInteger row = [self _rowFromSender:sender];
    if (row >= 0) {
        GSUTMConfiguration *cfg = [_vmEntries objectAtIndex:row];
        GSUTMAssistant *asst = [[GSUTMAssistant alloc] initWithOwner:self];
        [asst editConfiguration:cfg];
    }
}

- (void)_ctxRemove:(id)sender
{
    NSInteger row = [self _rowFromSender:sender];
    if (row < 0) return;
    GSUTMConfiguration *cfg = [_vmEntries objectAtIndex:row];

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:[NSString stringWithFormat:@"Remove \"%@\"?", cfg.name]];
    [alert setInformativeText:@"Remove it from the list only, or also delete the virtual machine files from disk?"];
    NSButton *listButton = [alert addButtonWithTitle:@"Remove from List"];
    NSButton *deleteButton = [alert addButtonWithTitle:@"Delete Files"];
    [alert addButtonWithTitle:@"Cancel"];
    [listButton setKeyEquivalent:@"\r"];
    [deleteButton setKeyEquivalent:@""];
    [alert setAlertStyle:NSWarningAlertStyle];
    NSInteger choice = [alert runModal];
    [alert release];
    if (choice == NSAlertThirdButtonReturn) return;

    /* Delete only the VM's own bundle directory; disk images stored outside
       the bundle are left untouched. */
    if (choice == NSAlertSecondButtonReturn && cfg.baseURL) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *bundlePath = [cfg.baseURL path];
        if ([bundlePath length] > 0 && [fm fileExistsAtPath:bundlePath]) {
            if ([fm isDeletableFileAtPath:bundlePath]) {
                [fm removeItemAtPath:bundlePath error:NULL];
            } else {
                NSLog(@"WARNING: VM bundle not deletable: %@", bundlePath);
            }
        }
    }

    [_vmEntries removeObjectAtIndex:row];
    [self _saveVMList];
    [_tableView reloadData];
    [_startStopButton setEnabled:NO];
    [_statusLabel setStringValue:@"Status: Stopped"];
    if ([_vmEntries count] > 0) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    }
}

/* ============== Window lifecycle ============== */

- (void)windowDidLoad
{
    [super windowDidLoad];
    [self _loadVMList];
    [[self window] setDelegate:self];
}

- (void)windowWillClose:(NSNotification *)note
{
    [self cleanupVM];
    [_consoleController close];
    exit(0);
}

- (void)cleanupVM
{
    if (_virtualMachine) {
        pid_t pid = _virtualMachine.qemuPID;
        if (pid > 0) {
            kill(pid, SIGKILL);
        }
        _virtualMachine = nil;
    }
}

- (void)close
{
    [self cleanupVM];
    [super close];
}

- (void)dealloc
{
    [self cleanupVM];
    [_consoleController release];
    [_configuration release];
    [_configPath release];
    [_vmEntries release];
    [super dealloc];
}

@end

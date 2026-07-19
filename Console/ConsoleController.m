/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "ConsoleController.h"
#import <stdarg.h>
#import <sys/stat.h>

#define ConsoleDebugLog(...) ((void)0)

static ConsoleController *sharedInstance = nil;

@implementation ConsoleController

+ (ConsoleController *)sharedController
{
    if (!sharedInstance) {
        sharedInstance = [[ConsoleController alloc] init];
    }
    return sharedInstance;
}

- (id)init
{
    self = [super init];
    if (self) {
        _logSources = [[NSMutableArray alloc] init];
        _allLogEntries = [[NSMutableArray alloc] init];
        _filteredLogEntries = [[NSMutableArray alloc] init];
        _queries = [[NSMutableArray alloc] init];
        _currentQuery = nil;
        _currentSourceName = nil;
        _currentSourcePrefix = nil;
        
        _maxLogEntries = 10000;
        _refreshInterval = 1.0;
        
        _logEntriesLock = [[NSLock alloc] init];
        _showingLogList = YES;
        
        [self loadConfiguration];
        [self initializeLogSources];
        [self createDefaultQueries];
    }
    return self;
}

- (void)dealloc
{
    [self stopMonitoring];
    [_logSources release];
    [_allLogEntries release];
    [_filteredLogEntries release];
    [_queries release];
    [_currentQuery release];
    [_currentSourceName release];
    [_currentSourcePrefix release];
    [_logEntriesLock release];
    [super dealloc];
}

- (void)awakeFromNib
{
    // Configure table view
    if (_logTableView) {
        [_logTableView setTarget:self];
        [_logTableView setDoubleAction:@selector(showDetailForSelectedLog:)];
    }
    
    // Configure split view
    if (_splitView) {
        [_splitView setPosition:200 ofDividerAtIndex:0];
    }
    
    // Start monitoring
    [self startMonitoring];
    
    // Update UI
    [self updateLogList];
    [self updateLogTable];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    // If no nib/gorm loaded, create programmatic UI
    if (!_mainWindow) {
        [self createMenu];
        [self createProgrammaticUI];
    }
    
    [self relaunchWithSudoIfNeeded];
    if (_mainWindow == nil) {
        return;
    }
    
    // Start monitoring
    [self startMonitoring];
}

- (BOOL)hasReadableSystemLogs
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *paths = @[
        @"/var/log/syslog",
        @"/var/log/messages",
        @"/var/log/system.log",
        @"/var/log/auth.log",
        @"/var/log/secure"
    ];
    for (NSString *path in paths) {
        if ([fm fileExistsAtPath:path] && [fm isReadableFileAtPath:path]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)hasUnreadableSystemLogs
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *paths = @[
        @"/var/log/syslog",
        @"/var/log/messages",
        @"/var/log/system.log",
        @"/var/log/auth.log",
        @"/var/log/secure"
    ];
    for (NSString *path in paths) {
        if ([fm fileExistsAtPath:path] && ![fm isReadableFileAtPath:path]) {
            return YES;
        }
    }
    return NO;
}

- (void)relaunchWithSudoIfNeeded
{
    NSDictionary *env = [[NSProcessInfo processInfo] environment];
    if ([env objectForKey:@"CONSOLE_ELEVATED"]) {
        return;
    }
    
    if ([self hasReadableSystemLogs] || ![self hasUnreadableSystemLogs]) {
        return;
    }
    
    NSString *sudoPath = @"/usr/bin/sudo";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:sudoPath]) {
        return;
    }

    NSString *askpassPath = [env objectForKey:@"SUDO_ASKPASS"];
    if (!askpassPath || ![[NSFileManager defaultManager] isExecutableFileAtPath:askpassPath]) {
        return;
    }
    
    NSString *exePath = [[NSBundle mainBundle] executablePath];
    if (!exePath) {
        return;
    }
    
    NSMutableDictionary *newEnv = [NSMutableDictionary dictionaryWithDictionary:env];
    [newEnv setObject:@"1" forKey:@"CONSOLE_ELEVATED"];
    [newEnv setObject:NSHomeDirectory() forKey:@"CONSOLE_ORIGINAL_HOME"];
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:sudoPath];
    [task setArguments:@[@"-A", @"-E", exePath]];
    [task setEnvironment:newEnv];
    
    @try {
        [task launch];
        [NSApp terminate:nil];
    } @catch (NSException *exception) {
        NSDebugLLog(@"gwcomp", @"Failed to relaunch with sudo: %@", exception);
    }
    
    [task release];
}

- (void)createMenu
{
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    
    // App menu
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"Console" action:NULL keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Console"];
    
    [appMenu addItemWithTitle:@"About Console" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Preferences..." action:NULL keyEquivalent:@","];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide Console" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Quit Console" action:@selector(terminate:) keyEquivalent:@"q"];
    
    [appMenuItem setSubmenu:appMenu];
    [mainMenu addItem:appMenuItem];
    [appMenuItem release];
    [appMenu release];
    
    // File menu
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"File" action:NULL keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    
        NSMenuItem *newQueryItem = (NSMenuItem *)[fileMenu addItemWithTitle:@"New System Log Query" 
                                         action:@selector(newQuery:) 
                                     keyEquivalent:@"n"];
    [newQueryItem setTarget:self];
    
    [fileMenu addItem:[NSMenuItem separatorItem]];
    
        NSMenuItem *saveItem = (NSMenuItem *)[fileMenu addItemWithTitle:@"Save Log to File..." 
                                        action:@selector(saveLogToFile:) 
                                    keyEquivalent:@"s"];
    [saveItem setTarget:self];
    
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    
    [fileMenuItem setSubmenu:fileMenu];
    [mainMenu addItem:fileMenuItem];
    [fileMenuItem release];
    [fileMenu release];
    
    // Edit menu
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    
        NSMenuItem *copyItem = (NSMenuItem *)[editMenu addItemWithTitle:@"Copy" 
                                        action:@selector(copyLogEntry:) 
                                    keyEquivalent:@"c"];
    [copyItem setTarget:self];
    
    [editMenu addItem:[NSMenuItem separatorItem]];
    
        NSMenuItem *clearItem = (NSMenuItem *)[editMenu addItemWithTitle:@"Clear Log Entries" 
                                         action:@selector(clearLogs:) 
                                     keyEquivalent:@"k"];
    [clearItem setTarget:self];
    
    [editMenuItem setSubmenu:editMenu];
    [mainMenu addItem:editMenuItem];
    [editMenuItem release];
    [editMenu release];
    
    // View menu
    NSMenuItem *viewMenuItem = [[NSMenuItem alloc] initWithTitle:@"View" action:NULL keyEquivalent:@""];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    
        NSMenuItem *toggleListItem = (NSMenuItem *)[viewMenu addItemWithTitle:@"Show Log List" 
                                           action:@selector(toggleLogList:) 
                                       keyEquivalent:@"l"];
    [toggleListItem setTarget:self];
    
    [viewMenuItem setSubmenu:viewMenu];
    [mainMenu addItem:viewMenuItem];
    [viewMenuItem release];
    [viewMenu release];
    
    // Window menu
    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:NULL keyEquivalent:@""];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    
    [windowMenuItem setSubmenu:windowMenu];
    [mainMenu addItem:windowMenuItem];
    [windowMenuItem release];
    [windowMenu release];
    
    [NSApp setMainMenu:mainMenu];
    [mainMenu release];
}

- (void)createProgrammaticUI
{
    // Create main window
    NSRect windowRect = NSMakeRect(100, 100, 800, 600);
    _mainWindow = [[NSWindow alloc] initWithContentRect:windowRect
                                              styleMask:NSTitledWindowMask | 
                                                       NSClosableWindowMask |
                                                       NSMiniaturizableWindowMask |
                                                       NSResizableWindowMask
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [_mainWindow setTitle:@"Console"];
    [_mainWindow setDelegate:self];
    
    // Create split view
    _splitView = [[NSSplitView alloc] initWithFrame:[[_mainWindow contentView] bounds]];
    [_splitView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_splitView setVertical:YES];
    [[_mainWindow contentView] addSubview:_splitView];
    
    // Left panel - Log list
    NSScrollView *leftScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, 600)];
    [leftScroll setHasVerticalScroller:YES];
    [leftScroll setAutoresizingMask:NSViewHeightSizable];
    
    _logListView = [[NSOutlineView alloc] initWithFrame:[[leftScroll contentView] bounds]];
    [_logListView setDataSource:self];
    [_logListView setDelegate:self];
    
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [[nameColumn headerCell] setStringValue:@"Log Sources"];
    [nameColumn setWidth:180];
    [_logListView addTableColumn:nameColumn];
    [nameColumn release];
    
    [_logListView setOutlineTableColumn:[_logListView tableColumnWithIdentifier:@"name"]];
    [leftScroll setDocumentView:_logListView];
    [_splitView addSubview:leftScroll];
    [leftScroll release];
    
    // Right panel - Split between table and detail
    NSView *rightPanel = [[NSView alloc] initWithFrame:NSMakeRect(200, 0, 600, 600)];
    [rightPanel setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    NSSplitView *rightSplit = [[NSSplitView alloc] initWithFrame:[rightPanel bounds]];
    [rightSplit setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [rightSplit setVertical:NO];
    [rightPanel addSubview:rightSplit];
    
    // Top area: search + log table
    NSView *topPanel = [[NSView alloc] initWithFrame:NSMakeRect(0, 200, 600, 400)];
    [topPanel setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    CGFloat topHeight = [topPanel bounds].size.height;
    CGFloat topWidth = [topPanel bounds].size.width;
    CGFloat searchHeight = 26.0;
    CGFloat searchMargin = 6.0;
    BOOL themeSearch = [NSSearchFieldCell instancesRespondToSelector:@selector(EAUsearchButtonRectForBounds:)];
    if (themeSearch)
      {
        _searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(8, topHeight - searchHeight - searchMargin, topWidth - 16, searchHeight)];
      }
    else
      {
        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(8, topHeight - searchHeight - searchMargin, topWidth - 16, searchHeight)];
        [tf setBezeled:YES];
        [tf setBezelStyle:NSTextFieldRoundedBezel];
        [tf setEditable:YES];
        [tf setSelectable:YES];
        _searchField = (NSTextField *)tf;
      }
    [_searchField setTarget:self];
    [_searchField setAction:@selector(search:)];
    [_searchField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [(id)_searchField setPlaceholderString:@"Search"];
    [[_searchField cell] setSendsActionOnEndEditing:NO];
    [topPanel addSubview:_searchField];
    
    NSScrollView *tableScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, topWidth, topHeight - (searchHeight + searchMargin))];
    [tableScroll setHasVerticalScroller:YES];
    [tableScroll setHasHorizontalScroller:YES];
    [tableScroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    _logTableView = [[NSTableView alloc] initWithFrame:[[tableScroll contentView] bounds]];
    [_logTableView setDataSource:self];
    [_logTableView setDelegate:self];
    [_logTableView setTarget:self];
    [_logTableView setDoubleAction:@selector(showDetailForSelectedLog:)];
    [_logTableView setUsesAlternatingRowBackgroundColors:YES];
    
    // Add columns
    NSTableColumn *timeColumn = [[NSTableColumn alloc] initWithIdentifier:@"timestamp"];
    [[timeColumn headerCell] setStringValue:@"Time"];
    [timeColumn setWidth:120];
    [_logTableView addTableColumn:timeColumn];
    [timeColumn release];
    
    NSTableColumn *processColumn = [[NSTableColumn alloc] initWithIdentifier:@"process"];
    [[processColumn headerCell] setStringValue:@"Process"];
    [processColumn setWidth:150];
    [_logTableView addTableColumn:processColumn];
    [processColumn release];
    
    NSTableColumn *priorityColumn = [[NSTableColumn alloc] initWithIdentifier:@"priority"];
    [[priorityColumn headerCell] setStringValue:@"Level"];
    [priorityColumn setWidth:80];
    [_logTableView addTableColumn:priorityColumn];
    [priorityColumn release];
    
    NSTableColumn *messageColumn = [[NSTableColumn alloc] initWithIdentifier:@"message"];
    [[messageColumn headerCell] setStringValue:@"Message"];
    [messageColumn setWidth:300];
    [_logTableView addTableColumn:messageColumn];
    [messageColumn release];
    
    [tableScroll setDocumentView:_logTableView];
    [topPanel addSubview:tableScroll];
    [tableScroll release];
    
    // Bottom area: detail view
    NSView *bottomPanel = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 200)];
    [bottomPanel setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    NSScrollView *detailScroll = [[NSScrollView alloc] initWithFrame:[bottomPanel bounds]];
    [detailScroll setHasVerticalScroller:YES];
    [detailScroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    
    _detailTextView = [[NSTextView alloc] initWithFrame:[[detailScroll contentView] bounds]];
    [_detailTextView setEditable:NO];
    [_detailTextView setSelectable:YES];
    [detailScroll setDocumentView:_detailTextView];
    [bottomPanel addSubview:detailScroll];
    [detailScroll release];
    
    [rightSplit addSubview:topPanel];
    [rightSplit addSubview:bottomPanel];
    [rightSplit setPosition:400 ofDividerAtIndex:0];
    
    [topPanel release];
    [bottomPanel release];
    [rightSplit release];
    
    [_splitView addSubview:rightPanel];
    [rightPanel release];
    
    [_mainWindow makeKeyAndOrderFront:nil];
}

// MARK: - Log Source Management

- (void)initializeLogSources
{
    ConsoleDebugLog(@"Initializing log sources...");
    // Try systemd first
    SystemdLogSource *systemdSource = [[SystemdLogSource alloc] initWithName:@"systemd journal"];
    if ([systemdSource isAvailable]) {
        [systemdSource setDelegate:self];
        [_logSources addObject:systemdSource];
        ConsoleDebugLog(@"Enabled systemd journal source");
    }
    [systemdSource release];
    
    // Traditional syslog files
    NSArray *syslogPaths = @[
        @"/var/log/syslog",
        @"/var/log/messages",
        @"/var/log/system.log"
    ];
    
    for (NSString *path in syslogPaths) {
        SyslogLogSource *source = [[SyslogLogSource alloc] initWithLogFilePath:path];
        if ([source isAvailable]) {
            [source setDelegate:self];
            [_logSources addObject:source];
            ConsoleDebugLog(@"Enabled syslog source: %@", path);
            break;  // Only need one system log
        }
        [source release];
    }
    
    // Authentication logs
    NSArray *authPaths = @[
        @"/var/log/auth.log",
        @"/var/log/secure"
    ];
    
    for (NSString *path in authPaths) {
        SyslogLogSource *source = [[SyslogLogSource alloc] initWithLogFilePath:path];
        if ([source isAvailable]) {
            [source setDelegate:self];
            [_logSources addObject:source];
            ConsoleDebugLog(@"Enabled auth log source: %@", path);
            break;
        }
        [source release];
    }
    
    // Kernel log
    KernelLogSource *kernelSource = [[KernelLogSource alloc] initWithName:@"Kernel"];
    [kernelSource setDelegate:self];
    [_logSources addObject:kernelSource];
    ConsoleDebugLog(@"Enabled kernel log source");
    [kernelSource release];
    
    // Application logs
    NSArray *appLogDirs = @[
        [self userLogsDirectory],
        @"/var/log",
        @"/tmp"
    ];
    
    for (NSString *dir in appLogDirs) {
        ApplicationLogSource *source = [[ApplicationLogSource alloc] initWithLogDirectory:dir];
        if ([source isAvailable]) {
            [source setDelegate:self];
            [_logSources addObject:source];
            ConsoleDebugLog(@"Enabled application log dir: %@", dir);
        }
        [source release];
    }
}

- (void)startMonitoring
{
    ConsoleDebugLog(@"Starting monitoring (%lu sources)", (unsigned long)[_logSources count]);
    for (LogSource *source in _logSources) {
        [source start];
    }
}

- (void)stopMonitoring
{
    for (LogSource *source in _logSources) {
        [source stop];
    }
}

- (NSArray *)logSources
{
    return _logSources;
}

// MARK: - Log Entry Management

- (void)addLogEntry:(LogEntry *)entry
{
    [_logEntriesLock lock];
    
    // Add to all entries
    [_allLogEntries addObject:entry];
    
    // Enforce maximum size (circular buffer)
    while ([_allLogEntries count] > _maxLogEntries) {
        [_allLogEntries removeObjectAtIndex:0];
    }
    
    // Check if entry matches current filter
    BOOL matchesQuery = (!_currentQuery || [_currentQuery matchesLogEntry:entry]);
    BOOL matchesSource = (!_currentSourceName || [[entry sourceName] isEqualToString:_currentSourceName]);
    BOOL matchesPrefix = (!_currentSourcePrefix || ([[entry sourceName] hasPrefix:_currentSourcePrefix]));
    if (matchesQuery && matchesSource && matchesPrefix) {
        [_filteredLogEntries addObject:entry];
        
        // Enforce maximum size for filtered entries too
        while ([_filteredLogEntries count] > _maxLogEntries) {
            [_filteredLogEntries removeObjectAtIndex:0];
        }
        
        // Update UI on main thread
        [self performSelectorOnMainThread:@selector(updateLogTable)
                               withObject:nil
                            waitUntilDone:NO];
    }
    
    // Check for alerts
    if (_currentQuery && [_currentQuery alertOnMatch] && [_currentQuery matchesLogEntry:entry]) {
        [self performSelectorOnMainThread:@selector(showAlertForLogEntry:)
                               withObject:entry
                            waitUntilDone:NO];
    }
    
    [_logEntriesLock unlock];
}

- (void)addLogEntries:(NSArray *)entries
{
    if ([entries count] == 0) {
        return;
    }

    ConsoleDebugLog(@"Adding %lu log entries", (unsigned long)[entries count]);

    [_logEntriesLock lock];

    for (LogEntry *entry in entries) {
        [_allLogEntries addObject:entry];
    }

    while ([_allLogEntries count] > _maxLogEntries) {
        [_allLogEntries removeObjectAtIndex:0];
    }

    if (_currentQuery || _currentSourceName || _currentSourcePrefix) {
        for (LogEntry *entry in entries) {
            BOOL matchesQuery = (!_currentQuery || [_currentQuery matchesLogEntry:entry]);
            BOOL matchesSource = (!_currentSourceName || [[entry sourceName] isEqualToString:_currentSourceName]);
            BOOL matchesPrefix = (!_currentSourcePrefix || ([[entry sourceName] hasPrefix:_currentSourcePrefix]));
            if (matchesQuery && matchesSource && matchesPrefix) {
                [_filteredLogEntries addObject:entry];
            }
        }
    } else {
        [_filteredLogEntries addObjectsFromArray:entries];
    }

    while ([_filteredLogEntries count] > _maxLogEntries) {
        [_filteredLogEntries removeObjectAtIndex:0];
    }

    [self performSelectorOnMainThread:@selector(updateLogTable)
                           withObject:nil
                        waitUntilDone:NO];

    [_logEntriesLock unlock];
}

- (NSArray *)allLogEntries
{
    return _allLogEntries;
}

- (NSArray *)filteredLogEntries
{
    return _filteredLogEntries;
}

- (void)clearLogEntries
{
    [_logEntriesLock lock];
    [_allLogEntries removeAllObjects];
    [_filteredLogEntries removeAllObjects];
    [_logEntriesLock unlock];
    
    [self updateLogTable];
}

// MARK: - Query Management

- (void)createDefaultQueries
{
    // All Messages query
    LogQuery *allQuery = [[LogQuery alloc] initWithName:@"All Messages"];
    [self addQuery:allQuery];
    [allQuery release];
    
    // Errors and warnings
    LogQuery *errorsQuery = [[LogQuery alloc] initWithName:@"Errors & Warnings"];
    [errorsQuery setPriorityLevels:@[
        [NSNumber numberWithInt:LogPriorityEmergency],
        [NSNumber numberWithInt:LogPriorityAlert],
        [NSNumber numberWithInt:LogPriorityCritical],
        [NSNumber numberWithInt:LogPriorityError],
        [NSNumber numberWithInt:LogPriorityWarning]
    ]];
    [self addQuery:errorsQuery];
    [errorsQuery release];
    
    // System events
    LogQuery *systemQuery = [[LogQuery alloc] initWithName:@"System Events"];
    [systemQuery setProcessPattern:@"(systemd|kernel|init|syslog|rsyslog|daemon|klogd|dmesg)"];
    [self addQuery:systemQuery];
    [systemQuery release];
    
    // Set default query
    [self setCurrentQuery:allQuery];
}

- (NSArray *)logFilesList
{
    NSMutableArray *files = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // Directories to scan for system log files
    NSArray *logDirs = @[
        @"/var/log",
        @"/tmp"
    ];
    
    for (NSString *dir in logDirs) {
        NSArray *entries = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *name in entries) {
            NSString *path = [dir stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:path isDirectory:&isDir] && !isDir && [fm isReadableFileAtPath:path]) {
                // Check if it's a log file or FIFO
                NSString *ext = [[name pathExtension] lowercaseString];
                if ([ext isEqualToString:@"log"] || [ext isEqualToString:@"txt"]) {
                    [files addObject:path];
                }
            }
        }
    }
    
    [files sortUsingComparator:^NSComparisonResult(id a, id b) {
        return [[(NSString *)a lastPathComponent] compare:[(NSString *)b lastPathComponent] options:NSCaseInsensitiveSearch];
    }];
    return files;
}

- (NSString *)userLogsDirectory
{
    NSString *home = [[[NSProcessInfo processInfo] environment] objectForKey:@"CONSOLE_ORIGINAL_HOME"];
    if (!home) home = NSHomeDirectory();
    return [home stringByAppendingPathComponent:@"Library/Logs"];
}

- (NSArray *)userLogFilesList
{
    NSMutableArray *files = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *logDir = [self userLogsDirectory];
    
    NSArray *entries = [fm contentsOfDirectoryAtPath:logDir error:nil];
    for (NSString *name in entries) {
        NSString *path = [logDir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:path isDirectory:&isDir] && !isDir && [fm isReadableFileAtPath:path]) {
            NSString *ext = [[name pathExtension] lowercaseString];
            if ([ext isEqualToString:@"log"] || [ext isEqualToString:@"txt"]) {
                [files addObject:path];
            }
        }
    }
    
    [files sortUsingComparator:^NSComparisonResult(id a, id b) {
        return [[(NSString *)a lastPathComponent] compare:[(NSString *)b lastPathComponent] options:NSCaseInsensitiveSearch];
    }];
    return files;
}

- (void)addQuery:(LogQuery *)query
{
    [_queries addObject:query];
    [self updateLogList];
}

- (void)removeQuery:(LogQuery *)query
{
    [_queries removeObject:query];
    if (_currentQuery == query) {
        _currentQuery = nil;
    }
    [self updateLogList];
}

- (NSArray *)queries
{
    return _queries;
}

- (void)setCurrentQuery:(LogQuery *)query
{
    if (_currentQuery != query) {
        [_currentQuery release];
        _currentQuery = [query retain];
        
        if (_currentQuery) {
            [_currentSourceName release];
            _currentSourceName = nil;
            [_currentSourcePrefix release];
            _currentSourcePrefix = nil;
        }
        
        // Refilter all entries
        [self refilterLogEntries];
        [self updateLogTable];
        [self updateLogList];
    }
}

- (void)setCurrentSourceName:(NSString *)sourceName
{
    if (_currentSourceName != sourceName) {
        [_currentSourceName release];
        _currentSourceName = [sourceName copy];
        
        if (_currentSourceName) {
            [_currentQuery release];
            _currentQuery = nil;
            [_currentSourcePrefix release];
            _currentSourcePrefix = nil;
        }
        
        [self refilterLogEntries];
        [self updateLogTable];
        [self updateLogList];
    }
}

- (void)setCurrentSourcePrefix:(NSString *)sourcePrefix
{
    if (_currentSourcePrefix != sourcePrefix) {
        [_currentSourcePrefix release];
        _currentSourcePrefix = [sourcePrefix copy];

        if (_currentSourcePrefix) {
            [_currentQuery release];
            _currentQuery = nil;
            [_currentSourceName release];
            _currentSourceName = nil;
        }

        [self refilterLogEntries];
        [self updateLogTable];
        [self updateLogList];
    }
}

- (LogQuery *)currentQuery
{
    return _currentQuery;
}

- (void)refilterLogEntries
{
    [_logEntriesLock lock];
    
    [_filteredLogEntries removeAllObjects];
    
    if (_currentQuery) {
        [_filteredLogEntries addObjectsFromArray:[_currentQuery filterLogEntries:_allLogEntries]];
    } else if (_currentSourceName) {
        for (LogEntry *entry in _allLogEntries) {
            if ([[entry sourceName] isEqualToString:_currentSourceName]) {
                [_filteredLogEntries addObject:entry];
            }
        }
    } else if (_currentSourcePrefix) {
        for (LogEntry *entry in _allLogEntries) {
            NSString *sourceName = [entry sourceName];
            if (sourceName && [sourceName hasPrefix:_currentSourcePrefix]) {
                [_filteredLogEntries addObject:entry];
            }
        }
    } else {
        [_filteredLogEntries addObjectsFromArray:_allLogEntries];
    }
    
    [_logEntriesLock unlock];
}

// MARK: - LogSourceDelegate

- (void)logSource:(LogSource *)source didReceiveLogEntry:(LogEntry *)entry
{
    [self addLogEntry:entry];
}

- (void)logSource:(LogSource *)source didReceiveLogEntries:(NSArray *)entries
{
    [self addLogEntries:entries];
}

- (void)logSource:(LogSource *)source didEncounterError:(NSError *)error
{
    NSDebugLLog(@"gwcomp", @"Log source %@ error: %@", [source name], error);
}

// MARK: - UI Updates

- (void)updateLogTable
{
    [_logTableView reloadData];
    
    // Scroll to bottom
    if ([_filteredLogEntries count] > 0) {
        [_logTableView scrollRowToVisible:[_filteredLogEntries count] - 1];
    }
}

- (void)updateLogList
{
    [_logListView reloadData];
}

// MARK: - NSTableView DataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    if (tableView == _logTableView) {
        return [_filteredLogEntries count];
    }
    return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (tableView == _logTableView && row < [_filteredLogEntries count]) {
        LogEntry *entry = [_filteredLogEntries objectAtIndex:row];
        NSString *identifier = [tableColumn identifier];
        
        if ([identifier isEqualToString:@"timestamp"]) {
            NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
            [formatter setDateFormat:@"HH:mm:ss.SSS"];
            return [formatter stringFromDate:[entry timestamp]];
        } else if ([identifier isEqualToString:@"process"]) {
            return [entry process];
        } else if ([identifier isEqualToString:@"message"]) {
            return [entry message];
        } else if ([identifier isEqualToString:@"priority"]) {
            return [entry priorityString];
        }
    }
    return nil;
}

// MARK: - NSOutlineView DataSource

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item
{
    if (item == nil) {
        return 3;  // "System Log Queries", "Log Files", "User Logs"
    }
    
    if ([item isKindOfClass:[NSString class]]) {
        NSString *category = (NSString *)item;
        if ([category isEqualToString:@"System Log Queries"]) {
            return [_queries count];
        } else if ([category isEqualToString:@"Log Files"]) {
            return [[self logFilesList] count];
        } else if ([category isEqualToString:@"User Logs"]) {
            return [[self userLogFilesList] count];
        }
    }
    
    return 0;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item
{
    if (item == nil) {
        if (index == 0) return @"System Log Queries";
        if (index == 1) return @"Log Files";
        if (index == 2) return @"User Logs";
        return nil;
    }
    
    if ([item isKindOfClass:[NSString class]]) {
        NSString *category = (NSString *)item;
        if ([category isEqualToString:@"System Log Queries"]) {
            return [_queries objectAtIndex:index];
        } else if ([category isEqualToString:@"Log Files"]) {
            return [[self logFilesList] objectAtIndex:index];
        } else if ([category isEqualToString:@"User Logs"]) {
            return [[self userLogFilesList] objectAtIndex:index];
        }
    }
    
    return nil;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item
{
    if (![item isKindOfClass:[NSString class]]) {
        return NO;
    }
    NSString *str = (NSString *)item;
    if ([str isEqualToString:@"System Log Queries"] || [str isEqualToString:@"Log Files"] || [str isEqualToString:@"User Logs"]) {
        return YES;
    }
    return NO;
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn forItem:(id)item
{
    if ([item isKindOfClass:[NSString class]]) {
        NSString *str = (NSString *)item;
        if ([str hasPrefix:@"/"]) {
            // For file paths, show directory/filename
            NSString *dir = [str stringByDeletingLastPathComponent];
            NSString *file = [str lastPathComponent];
            return [NSString stringWithFormat:@"%@/%@", [dir lastPathComponent], file];
        }
        return str;
    } else if ([item isKindOfClass:[LogQuery class]]) {
        return [(LogQuery *)item name];
    }
    return nil;
}

// GNUstep compatibility: NSOutlineViewDataSource required methods
- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item
{
    return [self outlineView:outlineView objectValueForTableColumn:tableColumn forItem:item];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView acceptDrop:(id<NSDraggingInfo>)info item:(id)item childIndex:(NSInteger)index
{
    return NO;
}

- (NSDragOperation)outlineView:(NSOutlineView *)outlineView validateDrop:(id<NSDraggingInfo>)info proposedItem:(id)item proposedChildIndex:(NSInteger)index
{
    return NSDragOperationNone;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView writeItems:(NSArray *)items toPasteboard:(NSPasteboard *)pasteboard
{
    return NO;
}

- (void)outlineView:(NSOutlineView *)outlineView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn byItem:(id)item
{
    // Read-only outline view
}

- (id)outlineView:(NSOutlineView *)outlineView itemForPersistentObject:(id)object
{
    return nil;
}

- (id)outlineView:(NSOutlineView *)outlineView persistentObjectForItem:(id)item
{
    return nil;
}

- (void)outlineView:(NSOutlineView *)outlineView sortDescriptorsDidChange:(NSArray *)oldDescriptors
{
    // No-op for now
}

- (NSArray *)outlineView:(NSOutlineView *)outlineView namesOfPromisedFilesDroppedAtDestination:(NSURL *)dropDestination forDraggedItems:(NSArray *)items
{
    return nil;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
    NSInteger row = [_logListView selectedRow];
    if (row >= 0) {
        id item = [_logListView itemAtRow:row];
        
        if ([item isKindOfClass:[LogQuery class]]) {
            [self setCurrentQuery:item];
        } else if ([item isKindOfClass:[NSString class]]) {
            NSString *str = (NSString *)item;
            if ([str isEqualToString:@"Log Files"]) {
                [self setCurrentSourcePrefix:nil];
                [self setCurrentQuery:nil];
                [self setCurrentSourceName:nil];
            } else if ([str isEqualToString:@"User Logs"]) {
                [self setCurrentSourcePrefix:[self userLogsDirectory]];
                [self setCurrentQuery:nil];
                [self setCurrentSourceName:nil];
            } else if ([str isEqualToString:@"System Log Queries"]) {
                if ([_queries count] > 0) {
                    [self setCurrentQuery:[_queries objectAtIndex:0]];
                }
            } else if ([str hasPrefix:@"/"]) {
                [self setCurrentSourceName:str];
            }
        }
    }
}

- (void)outlineViewColumnDidMove:(NSNotification *)notification
{
    // No-op
}

- (void)outlineViewColumnDidResize:(NSNotification *)notification
{
    // No-op
}

- (void)outlineViewItemDidCollapse:(NSNotification *)notification
{
    // No-op
}

- (void)outlineViewItemDidExpand:(NSNotification *)notification
{
    // No-op
}

- (void)outlineViewItemWillCollapse:(NSNotification *)notification
{
    // No-op
}

- (void)outlineViewItemWillExpand:(NSNotification *)notification
{
    // No-op
}

- (void)outlineViewSelectionIsChanging:(NSNotification *)notification
{
    // No-op
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldCollapseItem:(id)item
{
    return YES;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldExpandItem:(id)item
{
    return YES;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldEditTableColumn:(NSTableColumn *)tableColumn item:(id)item
{
    return NO;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldSelectItem:(id)item
{
    return YES;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldSelectTableColumn:(NSTableColumn *)tableColumn
{
    return YES;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldShowOutlineCellForItem:(id)item
{
    return [item isKindOfClass:[NSString class]];
}

- (NSCell *)outlineView:(NSOutlineView *)outlineView dataCellForTableColumn:(NSTableColumn *)tableColumn item:(id)item
{
    return nil;
}

- (void)outlineView:(NSOutlineView *)outlineView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn item:(id)item
{
    // No-op
}

- (void)outlineView:(NSOutlineView *)outlineView willDisplayOutlineCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn item:(id)item
{
    // No-op
}

- (BOOL)selectionShouldChangeInOutlineView:(NSOutlineView *)outlineView
{
    return YES;
}

- (void)outlineView:(NSOutlineView *)outlineView didClickTableColumn:(NSTableColumn *)tableColumn
{
    // No-op
}

- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(id)item
{
    return nil;
}

- (NSTableRowView *)outlineView:(NSOutlineView *)outlineView rowViewForItem:(id)item
{
    return nil;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    if ([notification object] == _logTableView) {
        [self showDetailForSelectedLog:nil];
    }
}

// MARK: - Actions

- (IBAction)toggleLogList:(id)sender
{
    _showingLogList = !_showingLogList;
    
    if (_showingLogList) {
        [_splitView setPosition:200 ofDividerAtIndex:0];
    } else {
        [_splitView setPosition:0 ofDividerAtIndex:0];
    }
}

- (IBAction)clearLogs:(id)sender
{
    NSAlert *alert = [NSAlert alertWithMessageText:@"Clear All Logs"
                                     defaultButton:@"Clear"
                                   alternateButton:@"Cancel"
                                       otherButton:nil
                         informativeTextWithFormat:@"This will clear all log entries from memory. This action cannot be undone."];
    
    if ([alert runModal] == NSAlertDefaultReturn) {
        [self clearLogEntries];
    }
}

- (IBAction)newQuery:(id)sender
{
    // Create a panel for input
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 300, 100)
                                                styleMask:NSTitledWindowMask
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    [panel setTitle:@"New System Log Query"];
    
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 60, 280, 20)];
    [label setStringValue:@"Enter a name for the new query:"];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [[panel contentView] addSubview:label];
    [label release];
    
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 35, 280, 24)];
    [[panel contentView] addSubview:input];
    
    NSButton *createBtn = [[NSButton alloc] initWithFrame:NSMakeRect(190, 5, 90, 24)];
    [createBtn setTitle:@"Create"];
    [createBtn setTarget:panel];
    [createBtn setAction:@selector(stopModal)];
    [createBtn setKeyEquivalent:@"\r"];
    [[panel contentView] addSubview:createBtn];
    [createBtn release];
    
    NSButton *cancelBtn = [[NSButton alloc] initWithFrame:NSMakeRect(100, 5, 90, 24)];
    [cancelBtn setTitle:@"Cancel"];
    [cancelBtn setTarget:panel];
    [cancelBtn setAction:@selector(abortModal)];
    [cancelBtn setKeyEquivalent:@"\033"];
    [[panel contentView] addSubview:cancelBtn];
    [cancelBtn release];
    
    [panel center];
    [panel makeKeyAndOrderFront:nil];
    
    NSInteger result = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    
    if (result == NSRunStoppedResponse) {
        NSString *queryName = [input stringValue];
        if ([queryName length] > 0) {
            LogQuery *query = [[LogQuery alloc] initWithName:queryName];
            [self addQuery:query];
            [query release];
            
            // TODO: Show query editor panel
        }
    }
    
    [input release];
    [panel release];
}

- (IBAction)search:(id)sender
{
    NSString *searchText = [_searchField stringValue];
    
    if ([searchText length] > 0) {
        LogQuery *searchQuery = [[LogQuery alloc] initWithName:@"Search Results"];
        [searchQuery setMessagePattern:searchText];
        [self setCurrentQuery:searchQuery];
        [searchQuery release];
    } else {
        // Reset to all messages
        if ([_queries count] > 0) {
            [self setCurrentQuery:[_queries objectAtIndex:0]];
        }
    }
}

- (IBAction)copyLogEntry:(id)sender
{
    NSInteger row = [_logTableView selectedRow];
    if (row >= 0 && row < [_filteredLogEntries count]) {
        LogEntry *entry = [_filteredLogEntries objectAtIndex:row];
        NSString *text = [entry formattedString];
        
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb declareTypes:@[NSStringPboardType] owner:nil];
        [pb setString:text forType:NSStringPboardType];
    }
}

- (IBAction)saveLogToFile:(id)sender
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setAllowedFileTypes:@[@"log", @"txt"]];
    [panel setNameFieldStringValue:@"console.log"];
    
    if ([panel runModal] == NSFileHandlingPanelOKButton) {
        NSMutableString *content = [NSMutableString string];
        
        for (LogEntry *entry in _filteredLogEntries) {
            [content appendString:[entry formattedString]];
            [content appendString:@"\n"];
        }
        
        NSError *error = nil;
        [content writeToURL:[panel URL]
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:&error];
        
        if (error) {
            NSAlert *alert = [NSAlert alertWithError:error];
            [alert runModal];
        }
    }
}

- (void)showDetailForSelectedLog:(id)sender
{
    NSInteger row = [_logTableView selectedRow];
    if (row >= 0 && row < [_filteredLogEntries count]) {
        LogEntry *entry = [_filteredLogEntries objectAtIndex:row];
        
        if ([entry hasDetailedReport]) {
            [[_detailTextView textStorage] setAttributedString:
             [[[NSAttributedString alloc] initWithString:[entry detailedReport]] autorelease]];
        } else {
            [[_detailTextView textStorage] setAttributedString:
             [[[NSAttributedString alloc] initWithString:[entry formattedString]] autorelease]];
        }
    }
}

- (void)showAlertForLogEntry:(LogEntry *)entry
{
    // Show notification or badge
    NSDebugLLog(@"gwcomp", @"Alert: %@", [entry message]);
    [NSApp requestUserAttention:NSInformationalRequest];
}

// MARK: - Configuration

- (void)loadConfiguration
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    NSNumber *maxEntries = [defaults objectForKey:@"MaxLogEntries"];
    if (maxEntries) {
        _maxLogEntries = [maxEntries integerValue];
    }
    
    NSNumber *refreshInterval = [defaults objectForKey:@"RefreshInterval"];
    if (refreshInterval) {
        _refreshInterval = [refreshInterval doubleValue];
    }
}

- (void)saveConfiguration
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    [defaults setObject:[NSNumber numberWithInteger:_maxLogEntries]
                 forKey:@"MaxLogEntries"];
    [defaults setObject:[NSNumber numberWithDouble:_refreshInterval]
                 forKey:@"RefreshInterval"];
    
    [defaults synchronize];
}

// MARK: - NSWindow Delegate

- (BOOL)windowShouldClose:(id)sender
{
    [NSApp terminate:nil];
    return YES;
}

@end

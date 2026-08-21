/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "CatalogController.h"
#import "CatalogEntry.h"
#import "BuildController.h"

static NSString *toolPath(NSString *name)
{
    NSString *p = [NSTask launchPathForTool:name];
    if (p) return p;
    NSArray *dirs = @[@"/usr/local/bin", @"/usr/local/sbin",
                       @"/usr/bin", @"/bin", @"/usr/sbin", @"/sbin"];
    for (NSString *dir in dirs) {
        p = [dir stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p])
            return p;
    }
    return nil;
}

/* Layout constants following AppearanceMetrics.h conventions */
static const CGFloat kSideMargin = 24.0;
static const CGFloat kBottomMargin = 20.0;
static const CGFloat kTopMargin = 15.0;
static const CGFloat kBtnHeight = 20.0;
static const CGFloat kBtnWide = 100.0;
static const CGFloat kBtnHSpace = 10.0;
static const CGFloat kSpace16 = 16.0;
static const CGFloat kSpace8 = 8.0;
static const CGFloat kRowHeight = 20.0;
static const CGFloat kSearchFieldHeight = 22.0;

static const CGFloat kWinWidth = 420.0;
static const CGFloat kWinHeight = 260.0;

@implementation CatalogController

- (id)init
{
    self = [super init];
    if (self) {
        _entries = [[CatalogEntry loadCatalog] retain];
        _filteredEntries = [_entries retain];
    }
    return self;
}

- (void)dealloc
{
    [_entries release];
    [_filteredEntries release];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_window release];
    [_tableView release];
    [_searchField release];
    [_buildButton release];
    [_spinner release];
    [_statusLabel release];
    [super dealloc];
}

- (void)showWindow
{
    if (_window) {
        [_window orderFront:nil];
        return;
    }

    [self loadEntriesFromLocal];

    CGFloat right = kSideMargin;
    CGFloat bottom = kBottomMargin;
    CGFloat btnW = kBtnWide;
    CGFloat btnH = kBtnHeight;

    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kWinWidth, kWinHeight)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                  | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_window setTitle:NSLocalizedString(@"Build", @"Window title")];
    [_window setMinSize:NSMakeSize(300, 200)];
    [_window setDelegate:(id)self];

    NSView *contentView = [_window contentView];
    CGFloat y = bottom;

    /* Build button (lower-right) */
    CGFloat buildX = kWinWidth - right - btnW;
    _buildButton = [[NSButton alloc] initWithFrame:NSMakeRect(buildX, y, btnW, btnH)];
    [_buildButton setTitle:NSLocalizedString(@"Build", @"Build button")];
    [_buildButton setTarget:self];
    [_buildButton setAction:@selector(buildClicked:)];
    [_buildButton setEnabled:NO];
    [_buildButton setKeyEquivalent:@"\r"];
    [contentView addSubview:_buildButton];

    /* Open button (to the left of Build) */
    CGFloat openX = buildX - kBtnHSpace - btnW;
    NSButton *openButton = [[NSButton alloc] initWithFrame:NSMakeRect(openX, y, btnW, btnH)];
    [openButton setTitle:NSLocalizedString(@"Open…", @"Open button")];
    [openButton setTarget:self];
    [openButton setAction:@selector(openClicked:)];
    [contentView addSubview:openButton];

    y += btnH + kSpace16;

    /* Table view — edge-to-edge */
    CGFloat tableTop = kWinHeight - kTopMargin - kSpace8 - kSearchFieldHeight;
    CGFloat listH = tableTop - y;
    CGFloat tableW = kWinWidth;
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, y, tableW, listH)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setHasHorizontalScroller:NO];
    [scrollView setBorderType:NSBezelBorder];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    _tableView = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, tableW, listH)];
    [_tableView setRowHeight:kRowHeight];
    [_tableView setAllowsMultipleSelection:NO];
    [_tableView setAllowsEmptySelection:NO];
    [_tableView setHeaderView:nil];

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [[column headerCell] setStringValue:NSLocalizedString(@"App", @"Table column header: app name")];
    [column setEditable:NO];
    [column setWidth:tableW];
    [_tableView addTableColumn:column];

    [_tableView setDataSource:self];
    [_tableView setDelegate:self];
    [_tableView setTarget:self];
    [_tableView setAction:@selector(tableClicked:)];
    [_tableView setDoubleAction:@selector(buildClicked:)];

    [scrollView setDocumentView:_tableView];
    [contentView addSubview:scrollView];

    y = tableTop + kSpace8;

    /* Search field */
    BOOL themeSearch = [NSSearchFieldCell instancesRespondToSelector:@selector(EAUsearchButtonRectForBounds:)];
    if (themeSearch)
      {
        _searchField = [[NSSearchField alloc] initWithFrame: NSMakeRect(kSideMargin, y, kWinWidth - kSideMargin * 2, kSearchFieldHeight)];
      }
    else
      {
        NSTextField *tf = [[NSTextField alloc] initWithFrame: NSMakeRect(kSideMargin, y, kWinWidth - kSideMargin * 2, kSearchFieldHeight)];
        [tf setBezeled: YES];
        [tf setBezelStyle: NSTextFieldRoundedBezel];
        [tf setEditable: YES];
        [tf setSelectable: YES];
        _searchField = (NSSearchField *)tf;
      }
    [_searchField setPlaceholderString:NSLocalizedString(@"Filter…", @"Search placeholder")];
    [_searchField setTarget:self];
    [_searchField setAction:@selector(filterContent:)];
    [_searchField setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(filterContent:)
                                                 name:NSControlTextDidChangeNotification
                                               object:_searchField];
    [contentView addSubview:_searchField];

    if ([_filteredEntries count] > 0) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [_buildButton setEnabled:YES];
    }

    /* Spinner + status text at the lower-left, shown while the catalog is
       being refreshed from the server. */
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(kSideMargin, bottom, 16, 16)];
    [_spinner setStyle:NSProgressIndicatorSpinningStyle];
    [_spinner setIndeterminate:YES];
    [_spinner setDisplayedWhenStopped:NO];
    [_spinner setHidden:YES];
    [contentView addSubview:_spinner];

    _statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(kSideMargin + 22, bottom, 170, 16)];
    [_statusLabel setBezeled:NO];
    [_statusLabel setDrawsBackground:NO];
    [_statusLabel setEditable:NO];
    [_statusLabel setSelectable:NO];
    [_statusLabel setStringValue:NSLocalizedString(@"Updating catalog…", @"Status while refreshing catalog")];
    [_statusLabel setHidden:YES];
    [contentView addSubview:_statusLabel];

    [_window center];
    [_window orderFront:nil];

    /* Refresh the catalog from the server in the background the first time the
       window is shown. The list is refreshed (and the spinner hidden) once the
       download has completed. */
    if (!_catalogRefreshStarted) {
        _catalogRefreshStarted = YES;
        [self showSpinner];
        [NSThread detachNewThreadSelector:@selector(fetchCatalogInBackground)
                                 toTarget:self
                               withObject:nil];
    }
}

- (void)loadEntriesFromLocal
{
    [_entries release];
    _entries = [[CatalogEntry loadCatalog] retain];
    [_filteredEntries release];
    _filteredEntries = [_entries retain];
}

#pragma mark - List actions

- (void)tableClicked:(id)sender
{
    NSInteger row = [_tableView selectedRow];
    [_buildButton setEnabled:(row >= 0)];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return [_filteredEntries count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (row < 0 || row >= (NSInteger)[_filteredEntries count]) return nil;
    CatalogEntry *entry = [_filteredEntries objectAtIndex:row];
    if (entry.desc) {
        return [NSString stringWithFormat:@"%@ \u2014 %@", entry.name, entry.desc];
    }
    return entry.name;
}

#pragma mark - Search

/* Extract the repository owner (organization or user) from a Git URL such as
   https://github.com/probonopd/DingusPPC.app -> "probonopd". Used so the search
   field can match apps by their GitHub owner, not just by name/description. */
- (NSString *)ownerFromGitURL:(NSString *)gitURL
{
    if ([gitURL length] == 0) return @"";
    NSString *s = gitURL;
    NSRange scheme = [s rangeOfString:@"://"];
    if (scheme.location != NSNotFound) {
        s = [s substringFromIndex:NSMaxRange(scheme)];
    }
    NSArray *parts = [s componentsSeparatedByString:@"/"];
    /* parts[0] is the host (e.g. github.com); the owner is the next segment. */
    if ([parts count] > 1) {
        NSString *owner = [parts objectAtIndex:1];
        if ([owner length] > 0) return owner;
    }
    return @"";
}

- (void)filterContent:(id)sender
{
    NSString *searchString = [_searchField stringValue];

    if ([searchString length] == 0) {
        [_filteredEntries release];
        _filteredEntries = [_entries retain];
    } else {
        NSMutableArray *filtered = [NSMutableArray array];
        for (CatalogEntry *entry in _entries) {
            NSString *lowerSearch = [searchString lowercaseString];
            if ([[entry.name lowercaseString] rangeOfString:lowerSearch].location != NSNotFound ||
                [[entry.desc lowercaseString] rangeOfString:lowerSearch].location != NSNotFound ||
                [[[self ownerFromGitURL:entry.gitURL] lowercaseString] rangeOfString:lowerSearch].location != NSNotFound) {
                [filtered addObject:entry];
            }
        }
        [_filteredEntries release];
        _filteredEntries = [filtered retain];
    }

    [_tableView reloadData];

    if ([_filteredEntries count] > 0) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [_buildButton setEnabled:YES];
    } else {
        [_buildButton setEnabled:NO];
    }
}

#pragma mark - Actions

- (void)buildClicked:(id)sender
{
    NSInteger row = [_tableView selectedRow];
    if (row < 0 || row >= (NSInteger)[_filteredEntries count]) return;

    CatalogEntry *entry = [_filteredEntries objectAtIndex:row];

    NSString *template = [NSString stringWithFormat:@"/tmp/Build-catalog-%@-XXXXXXXX",
                          [entry.name stringByReplacingOccurrencesOfString:@" " withString:@"_"]];
    char *tmpPath = strdup([template UTF8String]);
    if (!mkdtemp(tmpPath)) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"Clone Failed", @"Alert title: clone failed")];
        [alert setInformativeText:NSLocalizedString(@"Could not create temporary directory.", @"Alert: temp dir error")];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
        [alert runModal];
        free(tmpPath);
        return;
    }
    NSString *cloneDir = [[NSString stringWithUTF8String:tmpPath] stringByStandardizingPath];
    free(tmpPath);

    /* Dismiss catalog and show progress window immediately so the user
       sees feedback while the clone runs. */
    [_window orderOut:nil];

    NSString *guessedMakefile = [cloneDir stringByAppendingPathComponent:@"GNUmakefile"];

    BuildController *controller = [[BuildController alloc] init];
    [controller setMakefilePath:guessedMakefile];
    [controller setExtraArgs:@[]];
    [controller setBuildDir:cloneDir];
    [controller showProgressWindow];
    [NSApp updateWindows];

    /* Clone the repository on a background queue to keep GUI responsive */
    dispatch_async(buildQueue(), ^{
        NSTask *gitTask = [[NSTask alloc] init];
        [gitTask setLaunchPath:toolPath(@"git")];
        [gitTask setArguments:@[@"clone", @"--depth=1", entry.gitURL, cloneDir]];
        [gitTask setEnvironment:[[NSProcessInfo processInfo] environment]];

    NSPipe *gitPipe = [[NSPipe alloc] init];
    [gitTask setStandardOutput:gitPipe];
    [gitTask setStandardError:gitPipe];
    [gitTask setStandardInput:[NSFileHandle fileHandleWithNullDevice]];

        NSString *logMsg = [NSString stringWithFormat:NSLocalizedString(@"=== Cloning %@ ===\n", @"Log: cloning repo"), entry.gitURL];
        [controller.buildOutput appendString:logMsg];
        dispatch_async(dispatch_get_main_queue(), ^{
            [controller.logController appendLog:logMsg];
        });
        write(STDOUT_FILENO, [logMsg UTF8String], [logMsg length]);

        BOOL cloneOK = YES;
        @try {
            [gitTask launch];

            NSFileHandle *handle = [gitPipe fileHandleForReading];
            while ([gitTask isRunning]) {
                NSData *data = [handle availableData];
                if ([data length] > 0) {
                    NSString *outStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    [controller.buildOutput appendString:outStr];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [controller.logController appendLog:outStr];
                    });
                    write(STDOUT_FILENO, [data bytes], [data length]);
                }
            }
            NSData *remaining = [handle readDataToEndOfFile];
            if ([remaining length] > 0) {
                NSString *outStr = [[NSString alloc] initWithData:remaining encoding:NSUTF8StringEncoding];
                [controller.buildOutput appendString:outStr];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [controller.logController appendLog:outStr];
                });
                write(STDOUT_FILENO, [remaining bytes], [remaining length]);
            }
        } @catch (NSException *e) {
            cloneOK = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                [controller hideProgressWindow];
                NSAlert *alert = [[NSAlert alloc] init];
                [alert setMessageText:NSLocalizedString(@"Clone Failed", @"Alert title: clone failed")];
                [alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"git clone failed: %@", @"Alert: git clone error with reason"), [e reason]]];
                [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
                [alert runModal];
                [NSApp terminate:nil];
            });
        }

        if (cloneOK && [gitTask terminationStatus] != 0) {
            cloneOK = NO;
            dispatch_sync(dispatch_get_main_queue(), ^{
                [controller hideProgressWindow];
                NSAlert *alert = [[NSAlert alloc] init];
                [alert setMessageText:NSLocalizedString(@"Clone Failed", @"Alert title: clone failed")];
                [alert setInformativeText:NSLocalizedString(@"git clone returned an error.", @"Alert: git clone error")];
                [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
                [alert runModal];
                [NSApp terminate:nil];
            });
        }

        if (cloneOK) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *makefilePath = nil;

            // Use catalog-specified makefile path if present (for repos with subdirectory makefiles)
            if (entry.makefilePath) {
                NSString *mf = [cloneDir stringByAppendingPathComponent:entry.makefilePath];
                if ([fm fileExistsAtPath:mf]) {
                    makefilePath = mf;
                }
            }

            // Fallback: search common makefile names in root
            if (!makefilePath) {
                for (NSString *name in @[@"GNUmakefile", @"GNUmakefile.in", @"Makefile"]) {
                    NSString *mf = [cloneDir stringByAppendingPathComponent:name];
                    if ([fm fileExistsAtPath:mf]) {
                        makefilePath = mf;
                        break;
                    }
                }
            }

            if (!makefilePath) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [controller hideProgressWindow];
                    NSAlert *alert = [[NSAlert alloc] init];
                    [alert setMessageText:NSLocalizedString(@"No Makefile Found", @"Alert title: no makefile")];
                    [alert setInformativeText:NSLocalizedString(@"The cloned repository does not contain a GNUmakefile or Makefile.", @"Alert: no makefile in clone")];
                    [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
                    [alert runModal];
                    [NSApp terminate:nil];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [controller setMakefilePath:makefilePath];
                    [controller reloadIcon];
                    [controller startBuild];
                });
            }
        }
    });
}

- (void)openClicked:(id)sender
{
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    [openPanel setTitle:NSLocalizedString(@"Select GNUmakefile", @"Open panel title")];
    [openPanel setCanChooseFiles:YES];
    [openPanel setCanChooseDirectories:YES];
    [openPanel setAllowsMultipleSelection:NO];

    NSString *defaultDir = @"/Developer/Library/Sources";
    if ([[NSFileManager defaultManager] fileExistsAtPath:defaultDir]) {
        [openPanel setDirectoryURL:[NSURL fileURLWithPath:defaultDir]];
    }

    NSInteger result = [openPanel runModal];
    if (result != NSModalResponseOK) return;

    NSArray *urls = [openPanel URLs];
    if ([urls count] == 0) return;

    NSString *path = [[urls objectAtIndex:0] path];
    BOOL isDir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];

    NSString *makefilePath = nil;
    if (isDir) {
        for (NSString *name in @[@"GNUmakefile", @"GNUmakefile.in", @"Makefile"]) {
            NSString *mf = [path stringByAppendingPathComponent:name];
            if ([[NSFileManager defaultManager] fileExistsAtPath:mf]) {
                makefilePath = mf;
                break;
            }
        }
    } else {
        makefilePath = path;
    }

    if (makefilePath) {
        [self startBuildWithMakefilePath:makefilePath];
    }
}

- (void)startBuildWithMakefilePath:(NSString *)makefilePath
{
    [_window orderOut:nil];

    BuildController *controller = [[BuildController alloc] init];
    [controller setMakefilePath:makefilePath];
    [controller showWindow];
}

- (void)windowWillClose:(NSNotification *)notification
{
    [NSApp terminate:self];
}

#pragma mark - Catalog refresh from server

/* Build an IMF-fixdate (RFC 7231) string in GMT for the If-Modified-Since
   header from a local file modification date. */
- (NSString *)imfFixdateFromDate:(NSDate *)date
{
    NSCalendarDate *cd = [NSCalendarDate dateWithTimeIntervalSinceReferenceDate:
                          [date timeIntervalSinceReferenceDate]];
    return [cd descriptionWithCalendarFormat:@"%a, %d %b %Y %H:%M:%S GMT"
                                    timeZone:[NSTimeZone timeZoneWithAbbreviation:@"GMT"]
                                      locale:nil];
}

/* Runs on a background thread: download the catalog if it is newer than the
   local copy and store it in Caches. Always calls back on the main thread with
   an error message (or nil on success) so the window can report problems. */
- (void)fetchCatalogInBackground
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *errorMessage = nil;

    NSString *urlString = [CatalogEntry remoteCatalogURLString];
    NSURL *url = [NSURL URLWithString:urlString];

    if (!url) {
        errorMessage = NSLocalizedString(@"The catalog address is invalid.",
                                         @"Catalog fetch error");
    } else {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                      timeoutInterval:15.0];

        NSString *cachePath = [CatalogEntry catalogCachePath];

        /* Only send If-Modified-Since when we already hold a downloaded Caches
           copy, whose mtime is a genuine "last fetched" timestamp. The bundled
           copy's mtime is the app install time and would always look newer than
           the server, wrongly yielding a 304. When falling back to the bundle
           we do a full GET and decide via content comparison below. */
        if (cachePath && [fm fileExistsAtPath:cachePath]) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:cachePath error:NULL];
            NSDate *localDate = [attrs objectForKey:NSFileModificationDate];
            if (localDate) {
                NSString *ims = [self imfFixdateFromDate:localDate];
                if (ims) {
                    [req setValue:ims forHTTPHeaderField:@"If-Modified-Since"];
                }
            }
        }

        NSURLResponse *response = nil;
        NSError *error = nil;
        NSData *data = [NSURLConnection sendSynchronousRequest:req
                                            returningResponse:&response
                                                        error:&error];
        if (!data || [data length] == 0 || error) {
            errorMessage = [NSString stringWithFormat:
                NSLocalizedString(@"Could not download the catalog: %@",
                                  @"Catalog fetch error with reason"),
                (error ? [error localizedDescription]
                        : NSLocalizedString(@"no data received",
                                            @"Catalog fetch error: empty"))];
        } else {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            BOOL proceed = YES;
            if ([http isKindOfClass:[NSHTTPURLResponse class]]) {
                if ([http statusCode] == 304) {
                    proceed = NO;
                } else if ([http statusCode] != 200) {
                    errorMessage = [NSString stringWithFormat:
                        NSLocalizedString(@"The catalog server returned an error (HTTP %d).",
                                          @"Catalog fetch error with status code"),
                        (int)[http statusCode]];
                    proceed = NO;
                }
            }

            if (proceed) {
                /* Only accept a well-formed catalog array. */
                NSArray *parsed = [NSPropertyListSerialization
                                      propertyListWithData:data
                                                    options:NSPropertyListImmutable
                                                     format:NULL
                                                      error:NULL];
                if (![parsed isKindOfClass:[NSArray class]]) {
                    errorMessage = NSLocalizedString(@"The downloaded catalog is not valid.",
                                                     @"Catalog fetch error: bad plist");
                } else if (cachePath) {
                    [data writeToFile:cachePath atomically:YES];
                }
            }
        }
    }

    [self performSelectorOnMainThread:@selector(catalogFetchDidFinishWithError:)
                           withObject:errorMessage
                        waitUntilDone:NO];
    [pool release];
}

/* Called on the main thread once the background fetch has completed: report any
   error, hide the spinner, and refresh the list with whatever catalog is now on
   disk. */
- (void)catalogFetchDidFinishWithError:(NSString *)errorMessage
{
    [self hideSpinner];

    if (errorMessage) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:NSLocalizedString(@"Catalog Update Failed",
                                                @"Alert title: catalog fetch failed")];
        [alert setInformativeText:errorMessage];
        [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
        [alert runModal];
        [alert release];
    }

    [self reloadCatalog];
}

- (void)showSpinner
{
    [_spinner startAnimation:nil];
    [_spinner setHidden:NO];
    [_statusLabel setHidden:NO];
}

- (void)hideSpinner
{
    [_spinner stopAnimation:nil];
    [_spinner setHidden:YES];
    [_statusLabel setHidden:YES];
}

- (void)reloadCatalog
{
    [self loadEntriesFromLocal];

    [_tableView reloadData];

    if ([_filteredEntries count] > 0) {
        [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                byExtendingSelection:NO];
        [_buildButton setEnabled:YES];
    } else {
        [_buildButton setEnabled:NO];
    }
}

@end

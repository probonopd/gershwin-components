/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MenuControllerPrefPane.h"

static NSString *const kMenuAppBundleID = @"Menu";
static NSString *const kEnabledKey = @"GSMenuExtraEnabled";
static NSString *const kOrderKey = @"GSMenuExtraOrder";

@protocol MenuExtraConfigProtocol
- (BOOL)updateEnabledExtras:(NSArray *)identifiers;
@end

@implementation MenuControllerPrefPane

- (id)init
{
    self = [super init];
    if (self) {
        _extras = [[NSMutableArray alloc] init];
        _enabledMap = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [_mainView release];
    [_extras release];
    [_enabledMap release];
    [super dealloc];
}

#pragma mark - Scanning

- (NSArray *)knownCompiledInExtras
{
    return [NSArray arrayWithObjects:
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"io.github.gershwin-desktop.menuextra.clock", @"identifier",
            @"Clock", @"name",
            [NSNumber numberWithInteger:80], @"priority", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"io.github.gershwin-desktop.menuextra.sound", @"identifier",
            @"Sound", @"name",
            [NSNumber numberWithInteger:70], @"priority", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"io.github.gershwin-desktop.menuextra.wlan", @"identifier",
            @"WLAN", @"name",
            [NSNumber numberWithInteger:60], @"priority", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"io.github.gershwin-desktop.menuextra.battery", @"identifier",
            @"Battery", @"name",
            [NSNumber numberWithInteger:50], @"priority", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"io.github.gershwin-desktop.menuextra.brightness", @"identifier",
            @"Brightness", @"name",
            [NSNumber numberWithInteger:40], @"priority", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"io.github.gershwin-desktop.menuextra.buildmonitor", @"identifier",
            @"Build Monitor", @"name",
            [NSNumber numberWithInteger:30], @"priority", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"io.github.gershwin-desktop.menuextra.ram", @"identifier",
            @"RAM", @"name",
            [NSNumber numberWithInteger:20], @"priority", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:
            @"io.github.gershwin-desktop.menuextra.cpu", @"identifier",
            @"CPU", @"name",
            [NSNumber numberWithInteger:10], @"priority", nil],
        nil];
}

- (NSArray *)scanForExtras
{
    NSMutableArray *searchPaths = [NSMutableArray array];
    [searchPaths addObject:@"/System/Library/MenuExtras"];
    [searchPaths addObject:@"/System/Library/Menu/StatusItems"];
    [searchPaths addObject:@"/Library/MenuExtras"];
    [searchPaths addObject:@"/Library/Menu/StatusItems"];

    NSString *userLib = [NSSearchPathForDirectoriesInDomains(
        NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    if (userLib) {
        [searchPaths addObject:[userLib stringByAppendingPathComponent:@"MenuExtras"]];
        [searchPaths addObject:[userLib stringByAppendingPathComponent:@"Menu/StatusItems"]];
    }

    NSMutableDictionary *extrasById = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *searchPath in searchPaths) {
        NSArray *contents = [fm contentsOfDirectoryAtPath:searchPath error:NULL];
        for (NSString *item in contents) {
            NSString *fullPath = [searchPath stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || !isDir) continue;

            NSString *ext = [[fullPath pathExtension] lowercaseString];
            if (![ext isEqualToString:@"gsmenuextra"] && ![ext isEqualToString:@"bundle"]) continue;

            NSString *infoPath = [fullPath stringByAppendingPathComponent:@"Resources/Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
            if (!info) continue;

            NSString *identifier = [info objectForKey:@"CFBundleIdentifier"];
            if (!identifier) {
                identifier = [[fullPath lastPathComponent] stringByDeletingPathExtension];
            }

            NSString *displayName = [info objectForKey:@"CFBundleName"];
            if (!displayName) {
                displayName = [[fullPath lastPathComponent] stringByDeletingPathExtension];
            }

            if ([extrasById objectForKey:identifier]) continue;

            NSNumber *prio = [info objectForKey:@"GSMenuExtraPriority"];
            NSInteger priority = prio ? [prio integerValue] : 100;

            [extrasById setObject:[NSDictionary dictionaryWithObjectsAndKeys:
                identifier, @"identifier",
                displayName, @"name",
                [NSNumber numberWithInteger:priority], @"priority", nil]
                          forKey:identifier];
        }
    }

    NSArray *known = [self knownCompiledInExtras];
    for (NSDictionary *extra in known) {
        NSString *ident = [extra objectForKey:@"identifier"];
        if (![extrasById objectForKey:ident]) {
            [extrasById setObject:extra forKey:ident];
        }
    }

    NSArray *sorted = [[extrasById allValues] sortedArrayUsingComparator:
        ^NSComparisonResult(id a, id b) {
            NSInteger pa = [[a objectForKey:@"priority"] integerValue];
            NSInteger pb = [[b objectForKey:@"priority"] integerValue];
            if (pa > pb) return NSOrderedAscending;
            if (pa < pb) return NSOrderedDescending;
            return [[a objectForKey:@"name"] compare:[b objectForKey:@"name"]];
        }];

    return sorted;
}

#pragma mark - Defaults

- (void)readEnabledState
{
    [_enabledMap removeAllObjects];

    NSDictionary *domain = [[NSUserDefaults standardUserDefaults]
        persistentDomainForName:kMenuAppBundleID];
    NSArray *enabled = [domain objectForKey:kEnabledKey];

    if ([enabled isKindOfClass:[NSArray class]] && [enabled count] > 0) {
        for (NSString *ident in enabled) {
            if ([ident isKindOfClass:[NSString class]]) {
                [_enabledMap setObject:[NSNumber numberWithBool:YES] forKey:ident];
            }
        }
    } else {
        for (NSDictionary *extra in _extras) {
            [_enabledMap setObject:[NSNumber numberWithBool:YES]
                            forKey:[extra objectForKey:@"identifier"]];
        }
    }
}

- (void)notifyMenuApp:(NSArray *)enabledArray
{
    @try {
        id<MenuExtraConfigProtocol> proxy = (id<MenuExtraConfigProtocol>)
            [NSConnection rootProxyForConnectionWithRegisteredName:
                @"io.github.gershwin-desktop.MenuExtraConfigServer" host:nil];
        if (proxy) {
            NSLog(@"MenuPrefPane: connected to Menu DO server, calling updateEnabledExtras:");
            [proxy updateEnabledExtras:enabledArray];
        } else {
            NSLog(@"MenuPrefPane: got nil proxy for DO server");
        }
    } @catch (NSException *e) {
        NSLog(@"MenuPrefPane: Could not notify Menu app via DO: %@", e);
    }
}

- (void)writeEnabledState
{
    NSMutableArray *enabledArray = [NSMutableArray array];
    for (NSDictionary *extra in _extras) {
        NSString *ident = [extra objectForKey:@"identifier"];
        if ([[_enabledMap objectForKey:ident] boolValue]) {
            [enabledArray addObject:ident];
        }
    }

    NSMutableDictionary *domain = [NSMutableDictionary dictionary];
    [domain setObject:enabledArray forKey:kEnabledKey];
    [domain setObject:enabledArray forKey:kOrderKey];
    [[NSUserDefaults standardUserDefaults] setPersistentDomain:domain
                                                         forName:kMenuAppBundleID];
    [[NSUserDefaults standardUserDefaults] synchronize];

    [self notifyMenuApp:enabledArray];
}

#pragma mark - Table View

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    (void)tableView;
    return [_extras count];
}

- (id)tableView:(NSTableView *)tableView
    objectValueForTableColumn:(NSTableColumn *)tableColumn
            row:(NSInteger)row
{
    (void)tableView;
    if (row < 0 || row >= (NSInteger)[_extras count]) return @"";

    NSDictionary *extra = [_extras objectAtIndex:(NSUInteger)row];
    NSString *colId = [tableColumn identifier];

    if ([colId isEqualToString:@"enabled"]) {
        return [_enabledMap objectForKey:[extra objectForKey:@"identifier"]]
            ?: [NSNumber numberWithBool:NO];
    } else if ([colId isEqualToString:@"name"]) {
        return [extra objectForKey:@"name"];
    }
    return @"";
}

- (void)tableView:(NSTableView *)tableView
    setObjectValue:(id)object
    forTableColumn:(NSTableColumn *)tableColumn
               row:(NSInteger)row
{
    (void)tableView;
    if (row < 0 || row >= (NSInteger)[_extras count]) return;
    if (![[tableColumn identifier] isEqualToString:@"enabled"]) return;

    NSDictionary *extra = [_extras objectAtIndex:(NSUInteger)row];
    BOOL enabled = [object boolValue];

    if (enabled) {
        [_enabledMap setObject:[NSNumber numberWithBool:YES]
                        forKey:[extra objectForKey:@"identifier"]];
    } else {
        [_enabledMap removeObjectForKey:[extra objectForKey:@"identifier"]];
    }

    [self writeEnabledState];
}

#pragma mark - UI

- (NSView *)createMainView
{
    CGFloat w = 480;
    CGFloat h = 320;

    _mainView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];

    NSScrollView *scrollView = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(20, 20, w - 40, h - 40)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    _tableView = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, w - 60, h - 60)];
    [_tableView setDataSource:(id<NSTableViewDataSource>)self];
    [_tableView setDelegate:(id<NSTableViewDelegate>)self];
    [_tableView setHeaderView:nil];
    [_tableView setAllowsMultipleSelection:NO];

    NSTableColumn *enabledCol = [[NSTableColumn alloc] initWithIdentifier:@"enabled"];
    [[enabledCol headerCell] setStringValue:@""];
    [enabledCol setWidth:30];
    [enabledCol setEditable:YES];
    {
        NSButtonCell *checkCell = [[NSButtonCell alloc] init];
        [checkCell setButtonType:NSSwitchButton];
        [checkCell setTitle:@""];
        [checkCell setControlSize:NSSmallControlSize];
        [checkCell setRefusesFirstResponder:YES];
        [enabledCol setDataCell:checkCell];
        [checkCell release];
    }
    [_tableView addTableColumn:enabledCol];
    [enabledCol release];

    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [[nameCol headerCell] setStringValue:@"Extra"];
    [nameCol setWidth:w - 100];
    [nameCol setEditable:NO];
    [_tableView addTableColumn:nameCol];
    [nameCol release];

    [scrollView setDocumentView:_tableView];
    [_mainView addSubview:scrollView];
    [scrollView release];

    return _mainView;
}

- (void)refreshExtras
{
    NSArray *scanned = [self scanForExtras];
    [_extras setArray:scanned];
    [self readEnabledState];
    [_tableView reloadData];
}

@end

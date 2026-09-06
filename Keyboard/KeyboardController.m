/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "KeyboardController.h"
#import "AppearanceMetrics.h"
#import <dispatch/dispatch.h>

@class KeyboardController;

/* The pane view. When the host window gives us a width (which is not the
   560px base we built at), re-lay out the group boxes so the left/right
   margins to the window edge stay symmetric. */
@interface KeyboardMainView : NSView
{
    KeyboardController *_layoutOwner;
}
@end

@implementation KeyboardMainView
- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    [_layoutOwner relayoutWithWidth:newSize.width];
}
- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if ([self window] && [self superview]) {
        /* The host window does not necessarily size the pane view to its
           content area; make it fill the box content and re-lay out so the
           left/right margins stay symmetric.  GNUstep's setFrame: bypasses
           setFrameSize:, so re-lay out explicitly here. */
        [self setFrame:[[self superview] bounds]];
        [_layoutOwner relayoutWithWidth:[self bounds].size.width];
    }
}
- (void)setLayoutOwner:(KeyboardController *)owner
{
    _layoutOwner = owner;
}
@end

static NSString *const kKeyboardDomain = @"KeyboardPreferences";
static NSString *const kDefaultKeyboardFile = @"/etc/default/keyboard";
static NSString *const kSetxkbmapLocal = @"/usr/local/bin/setxkbmap";
static NSString *const kSetxkbmapSystem = @"/usr/bin/setxkbmap";

static NSComparisonResult LayoutComparator(id a, id b, void *context)
{
    NSDictionary *map = (NSDictionary *)context;
    NSString *da = [map objectForKey:a];
    NSString *db = [map objectForKey:b];
    return [da caseInsensitiveCompare:db];
}

@interface KeyboardController ()
- (void)ensureMetadataLoaded;
- (void)parseKeyboardMetadata;
- (NSDictionary *)fallbackLayouts;
- (NSString *)findExecutableFromCandidates:(NSArray *)candidates;
- (NSDictionary *)savedPreferences;
- (NSDictionary *)systemKeyboardDefaults;
- (NSDictionary *)currentXkbmapSettingsSync;
- (void)populateLayoutTable;
- (void)populateVariantsForLayout:(NSString *)layout;
- (void)selectLayout:(NSString *)layout variant:(NSString *)variant;
- (BOOL)applyLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options error:(NSString **)error;
- (void)persistUserDefaultsLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options keyboardType:(NSString *)keyboardType isApple:(BOOL)isApple;
- (void)writeUserAutostartWithLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options keyboardType:(NSString *)keyboardType isApple:(BOOL)isApple;
- (BOOL)updateSystemKeyboardFileWithLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options keyboardType:(NSString *)keyboardType isApple:(BOOL)isApple error:(NSString **)error;
- (NSString *)modelForKeyboardType:(NSString *)keyboardType isApple:(BOOL)isApple;
- (NSString *)shellEscapedValue:(NSString *)value;
- (NSString *)trimmed:(NSString *)value;
- (void)updateStatus:(NSString *)message;
- (void)showAlertWithTitle:(NSString *)title text:(NSString *)text;

/* Layout helpers (HIG group boxes and rows). */
- (NSBox *)groupBoxWithTitle:(NSString *)title frame:(NSRect)frame inView:(NSView *)parent;
- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame alignment:(NSTextAlignment)align;
- (void)addCheckbox:(NSButton *)checkbox toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w;
- (void)addPopUpRowWithLabel:(NSString *)label
                      popup:(NSPopUpButton *)popup
                      toBox:(NSBox *)box
                          y:(CGFloat)y
                      width:(CGFloat)w;
@end

@implementation KeyboardController

- (id)init
{
    self = [super init];
    if (self) {
        isRefreshing = YES;  // Start in refresh mode to prevent unwanted writes during initialization
        NSDebugLog(@"[Keyboard] Controller init, isRefreshing set to YES");
    }
    return self;
}

- (void)dealloc
{
    [mainView release];
    [layoutTable release];
    [variantTable release];
    [layoutScroll release];
    [variantScroll release];
    [statusLabel release];
    [tryTextField release];
    [isAppleKeyboardCheckbox release];
    [keyboardTypePopup release];
    [layouts release];
    [variantsByLayout release];
    [setxkbmapPath release];
    [sortedLayouts release];
    [currentVariants release];
    [lastAppliedLayout release];
    [lastAppliedVariant release];
    [lastAppliedKeyboardType release];
    [super dealloc];
}

- (NSView *)createMainView
{
    if (mainView) {
        return mainView;
    }

    [self ensureMetadataLoaded];

    const CGFloat winW = 560, winH = 440;
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;      /* 24 */
    const CGFloat topMargin = METRICS_CONTENT_TOP_MARGIN;        /* 15 */
    const CGFloat bottomMargin = METRICS_SPACE_12;               /* under status line */
    const CGFloat boxGap = METRICS_SPACE_8;                      /* between group boxes */
    const CGFloat rowH = METRICS_TEXT_INPUT_FIELD_HEIGHT;        /* 22 */
    const CGFloat checkboxRowH = METRICS_RADIO_BUTTON_LINE_SPACING; /* 20 */
    const CGFloat boxTitleInset = 14.0;
    const CGFloat keyboardTypeBoxH = 96;      /* apple checkbox, type popup */
    const CGFloat tryFieldH = 24;             /* try text field (no box) */
    const CGFloat statusH = 18;

    mainView = [[KeyboardMainView alloc] initWithFrame:NSMakeRect(0, 0, winW, winH)];
    [(KeyboardMainView *)mainView setLayoutOwner:self];
    [mainView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    CGFloat contentW = winW - 2 * sideMargin;
    CGFloat boxW = contentW;

    CGFloat y = winH - topMargin;

    /* ---- Keyboard Type group box ---- */
    keyboardTypeBox = [self groupBoxWithTitle:@"Keyboard Type"
                                       frame:NSMakeRect(sideMargin, y - keyboardTypeBoxH, boxW, keyboardTypeBoxH)
                                      inView:mainView];
    {
        CGFloat by = keyboardTypeBoxH - boxTitleInset - METRICS_SPACE_16 - checkboxRowH;
        [self addCheckbox:isAppleKeyboardCheckbox =
                   [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease]
                    toBox:keyboardTypeBox y:by width:boxW];
        [isAppleKeyboardCheckbox setButtonType:NSSwitchButton];
        [isAppleKeyboardCheckbox setTitle:@"Apple keyboard"];
        [isAppleKeyboardCheckbox setTarget:self];
        [isAppleKeyboardCheckbox setAction:@selector(isAppleKeyboardCheckboxChanged:)];

        by -= METRICS_SPACE_8 + rowH;
        [self addPopUpRowWithLabel:@"Type:"
                            popup:keyboardTypePopup =
                            [[[NSPopUpButton alloc] initWithFrame:NSZeroRect] autorelease]
                            toBox:keyboardTypeBox y:by width:boxW];
        [keyboardTypePopup addItemWithTitle:@"ANSI"];
        [keyboardTypePopup addItemWithTitle:@"ISO"];
        [keyboardTypePopup addItemWithTitle:@"JIS"];
        [keyboardTypePopup setTarget:self];
        [keyboardTypePopup setAction:@selector(keyboardTypeChanged:)];
    }

    /* ---- Layout + variant tables, side by side (no group box),
             filling the space between the box and the try field ---- */
    {
        const CGFloat gap = METRICS_SPACE_8;
        const CGFloat tryFieldY = bottomMargin + statusH + METRICS_SPACE_8;
        const CGFloat tablesBottom = tryFieldY + tryFieldH + boxGap;
        const CGFloat tablesTop = winH - topMargin - keyboardTypeBoxH - boxGap;
        const CGFloat tablesH = tablesTop - tablesBottom;
        const CGFloat halfW = (boxW - gap) / 2.0;

        layoutScroll = [[NSScrollView alloc] initWithFrame:
            NSMakeRect(sideMargin, tablesBottom, halfW, tablesH)];
        [layoutScroll setHasVerticalScroller:YES];
        [layoutScroll setHasHorizontalScroller:NO];
        [layoutScroll setBorderType:NSBezelBorder];
        [mainView addSubview:layoutScroll];

        layoutTable = [[NSTableView alloc] initWithFrame:[layoutScroll bounds]];
        [layoutTable setDelegate:self];
        [layoutTable setDataSource:self];
        [layoutTable setAllowsMultipleSelection:NO];
        [layoutTable setAllowsEmptySelection:NO];
        NSTableColumn *layoutColumn = [[NSTableColumn alloc] initWithIdentifier:@"layout"];
        [layoutColumn setTitle:@""];
        [layoutColumn setWidth:250];
        [layoutColumn setEditable:NO];
        [layoutTable addTableColumn:layoutColumn];
        [layoutColumn release];
        [layoutScroll setDocumentView:layoutTable];

        variantScroll = [[NSScrollView alloc] initWithFrame:
            NSMakeRect(sideMargin + halfW + gap, tablesBottom, halfW, tablesH)];
        [variantScroll setHasVerticalScroller:YES];
        [variantScroll setHasHorizontalScroller:NO];
        [variantScroll setBorderType:NSBezelBorder];
        [mainView addSubview:variantScroll];

        variantTable = [[NSTableView alloc] initWithFrame:[variantScroll bounds]];
        [variantTable setDelegate:self];
        [variantTable setDataSource:self];
        [variantTable setAllowsMultipleSelection:NO];
        [variantTable setAllowsEmptySelection:YES];
        NSTableColumn *variantColumn = [[NSTableColumn alloc] initWithIdentifier:@"variant"];
        [variantColumn setTitle:@""];
        [variantColumn setWidth:210];
        [variantColumn setEditable:NO];
        [variantTable addTableColumn:variantColumn];
        [variantColumn release];
        [variantScroll setDocumentView:variantTable];
    }

    /* ---- Try text field directly on the view (single item, no box) ---- */
    {
        const CGFloat tryFieldY = bottomMargin + statusH + METRICS_SPACE_8;
        tryTextField = [[NSTextField alloc] initWithFrame:
            NSMakeRect(sideMargin, tryFieldY, contentW, tryFieldH)];
        [tryTextField setEditable:YES];
        [tryTextField setSelectable:YES];
        [tryTextField setBezeled:YES];
        [tryTextField setDrawsBackground:YES];
        [tryTextField setPlaceholderString:@"Type here to test the keyboard layout"];
        [tryTextField setAutoresizingMask:NSViewWidthSizable];
        [mainView addSubview:tryTextField];
    }

    /* Status label at the bottom */
    statusLabel = [self labelWithText:@""
                                frame:NSMakeRect(sideMargin, bottomMargin,
                                                contentW, statusH)
                              alignment:NSTextAlignmentLeft];
    [statusLabel setFont:[NSFont systemFontOfSize:10]];
    [statusLabel setAutoresizingMask:(NSViewWidthSizable | NSViewMaxYMargin)];
    [mainView addSubview:statusLabel];

    [self populateLayoutTable];
    [self refreshFromSystem];

    return mainView;
}

/* Re-lay out the group boxes for the given view width, keeping the
   left and right margins equal. Called whenever the host resizes the
   pane view. */
- (void)relayoutWithWidth:(CGFloat)width
{
    const CGFloat sideMargin = METRICS_CONTENT_SIDE_MARGIN;  /* 24 */
    NSRect f;

    if (keyboardTypeBox) {
        f = [keyboardTypeBox frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [keyboardTypeBox setFrame:f];
    }
    if (layoutScroll && variantScroll) {
        const CGFloat gap = METRICS_SPACE_8;
        const CGFloat halfW = (width - 2 * sideMargin - gap) / 2.0;
        f = [layoutScroll frame];
        f.origin.x = sideMargin;
        f.size.width = halfW;
        [layoutScroll setFrame:f];
        f = [variantScroll frame];
        f.origin.x = sideMargin + halfW + gap;
        f.size.width = halfW;
        [variantScroll setFrame:f];
    }
    if (tryTextField) {
        f = [tryTextField frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [tryTextField setFrame:f];
    }
    if (statusLabel) {
        f = [statusLabel frame];
        f.origin.x = sideMargin;
        f.size.width = width - 2 * sideMargin;
        [statusLabel setFrame:f];
    }
}

/* Build a titled group box, top-anchored. Width is managed by
   relayoutWithWidth: so margins stay symmetric. */
- (NSBox *)groupBoxWithTitle:(NSString *)title frame:(NSRect)frame inView:(NSView *)parent
{
    NSBox *box = [[NSBox alloc] initWithFrame:frame];
    [box setTitle:title];
    [box setBoxType:NSBoxPrimary];
    [box setTitlePosition:NSAtTop];
    [box setBorderType:NSBezelBorder];
    [box setAutoresizingMask:NSViewMinYMargin];
    [parent addSubview:box];
    return box;
}

/* A plain read-only label. */
- (NSTextField *)labelWithText:(NSString *)text frame:(NSRect)frame alignment:(NSTextAlignment)align
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    [label setStringValue:text ?: @""];
    [label setBezeled:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setDrawsBackground:NO];
    [label setFont:[NSFont systemFontOfSize:11]];
    [label setAlignment:align];
    return label;
}

/* Position a checkbox in the top-left of a group box's content area.
   Width-flexible so it tracks the box. */
- (void)addCheckbox:(NSButton *)checkbox toBox:(NSBox *)box y:(CGFloat)y width:(CGFloat)w
{
    [checkbox setFrame:NSMakeRect(METRICS_SPACE_16, y, w - 2 * METRICS_SPACE_16, 18)];
    [checkbox setAutoresizingMask:NSViewWidthSizable];
    [box addSubview:checkbox];
}

/* A label + pop-up row: label on the left (right aligned), pop-up
   stretching to fill the rest of the row. */
- (void)addPopUpRowWithLabel:(NSString *)label
                      popup:(NSPopUpButton *)popup
                      toBox:(NSBox *)box
                          y:(CGFloat)y
                      width:(CGFloat)w
{
    const CGFloat pad = METRICS_SPACE_16;
    const CGFloat labelW = 110;
    const CGFloat gap = METRICS_SPACE_8;
    const CGFloat popupW = w - 2 * pad - labelW - gap;

    NSTextField *labelField = [self labelWithText:label
                                            frame:NSMakeRect(pad, y + 1, labelW, 20)
                                        alignment:NSTextAlignmentRight];
    [labelField setFont:[NSFont systemFontOfSize:11]];
    [labelField setAutoresizingMask:NSViewMaxXMargin];
    [box addSubview:labelField];
    [labelField release];

    [popup setFrame:NSMakeRect(pad + labelW + gap, y, popupW, 22)];
    [popup setAutoresizingMask:NSViewWidthSizable];
    [box addSubview:popup];
}

- (void)ensureMetadataLoaded
{
    if (metadataLoaded) {
        return;
    }

    [self parseKeyboardMetadata];
    setxkbmapPath = [[self findExecutableFromCandidates:[NSArray arrayWithObjects:kSetxkbmapLocal, kSetxkbmapSystem, nil]] retain];
    metadataLoaded = YES;
}

- (void)parseKeyboardMetadata
{
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSArray *possiblePaths = [NSArray arrayWithObjects:
                              @"/usr/share/X11/xkb/rules/base.lst",
                              @"/usr/local/share/X11/xkb/rules/base.lst",
                              nil];
    NSString *lstPath = nil;
    for (NSString *path in possiblePaths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            lstPath = path;
            break;
        }
    }
    NSError *error = nil;
    NSString *contents = lstPath ? [NSString stringWithContentsOfFile:lstPath encoding:NSUTF8StringEncoding error:&error] : nil;

    NSMutableDictionary *layoutMap = [[NSMutableDictionary alloc] init];
    NSMutableDictionary *variantMap = [[NSMutableDictionary alloc] init];

    if (contents) {
        BOOL inLayout = NO;
        BOOL inVariant = NO;
        NSArray *lines = [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

        for (NSString *line in lines) {
            NSString *trim = [line stringByTrimmingCharactersInSet:ws];
            if ([trim length] == 0) {
                continue;
            }

            if ([trim hasPrefix:@"! "]) {
                inLayout = [trim hasPrefix:@"! layout"];
                inVariant = [trim hasPrefix:@"! variant"];
                continue;
            }

            if (inLayout) {
                NSRange space = [trim rangeOfString:@" "];
                if (space.location == NSNotFound) {
                    continue;
                }
                NSString *code = [[trim substringToIndex:space.location] stringByTrimmingCharactersInSet:ws];
                NSString *desc = [[trim substringFromIndex:space.location] stringByTrimmingCharactersInSet:ws];
                if ([code length] > 0) {
                    [layoutMap setObject:(desc.length ? desc : code) forKey:code];
                }
                continue;
            }

            if (inVariant) {
                NSRange colon = [trim rangeOfString:@":"];
                if (colon.location == NSNotFound) {
                    continue;
                }
                NSString *lhs = [[trim substringToIndex:colon.location] stringByTrimmingCharactersInSet:ws];
                NSString *rhs = [[trim substringFromIndex:(colon.location + 1)] stringByTrimmingCharactersInSet:ws];

                NSArray *parts = [lhs componentsSeparatedByCharactersInSet:ws];
                if ([parts count] < 2) {
                    continue;
                }
                NSString *variantCode = [parts objectAtIndex:0];
                NSString *layoutCode = [parts lastObject];

                if ([variantCode length] == 0 || [layoutCode length] == 0) {
                    continue;
                }

                NSMutableArray *list = [variantMap objectForKey:layoutCode];
                if (!list) {
                    list = [NSMutableArray array];
                    [variantMap setObject:list forKey:layoutCode];
                }
                NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:variantCode, @"code", (rhs.length ? rhs : variantCode), @"description", nil];
                [list addObject:entry];
            }
        }
    }

    if ([layoutMap count] == 0) {
        NSDictionary *fallback = [self fallbackLayouts];
        layoutMap = [fallback mutableCopy];
    }

    [layouts release];
    [variantsByLayout release];

    layouts = layoutMap;
    variantsByLayout = variantMap;
}

- (NSDictionary *)fallbackLayouts
{
    return [NSDictionary dictionaryWithObjectsAndKeys:
            @"English (US)", @"us",
            @"English (UK)", @"gb",
            @"German", @"de",
            @"French", @"fr",
            @"Spanish", @"es",
            @"Italian", @"it",
            nil];
}

- (NSString *)findExecutableFromCandidates:(NSArray *)candidates
{
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in candidates) {
        if ([fm isExecutableFileAtPath:path]) {
            return path;
        }
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/which"];
    [task setArguments:[NSArray arrayWithObject:@"setxkbmap"]];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task launch];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *output = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    [task release];

    NSString *trim = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trim length] > 0 && [fm isExecutableFileAtPath:trim]) {
        return trim;
    }

    return nil;
}

- (NSDictionary *)savedPreferences
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *domain = [defaults persistentDomainForName:kKeyboardDomain];
    if (domain) {
        return domain;
    }
    return [NSDictionary dictionary];
}

- (NSDictionary *)systemKeyboardDefaults
{
    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfFile:kDefaultKeyboardFile encoding:NSUTF8StringEncoding error:&error];
    if (!contents) {
        return [NSDictionary dictionary];
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray *lines = [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) {
            continue;
        }
        NSString *key = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *val = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        val = [val stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
        if ([key length] && [val length]) {
            [result setObject:val forKey:key];
        }
    }
    return result;
}

// Synchronous helper — runs setxkbmap and parses its output.
// Only call from a background thread or during init.
- (NSDictionary *)currentXkbmapSettingsSync
{
    if (!setxkbmapPath) {
        return [NSDictionary dictionary];
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:setxkbmapPath];
    [task setArguments:[NSArray arrayWithObject:@"-query"]];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSPipe pipe]];

    // Force C locale for consistent tool output
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"C" forKey:@"LC_ALL"];
    [task setEnvironment:env];
    [env release];

    [task launch];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    NSString *output = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    [task release];

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) {
            continue;
        }
        NSString *key = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *val = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([key length] && [val length]) {
            [result setObject:val forKey:key];
        }
    }
    return result;
}

- (void)populateLayoutTable
{
    [sortedLayouts release];
    sortedLayouts = [[layouts allKeys] sortedArrayUsingFunction:LayoutComparator context:layouts];
    [sortedLayouts retain];
    [layoutTable reloadData];
}

- (void)populateVariantsForLayout:(NSString *)layout
{
    [currentVariants release];
    currentVariants = [[variantsByLayout objectForKey:layout] retain];
    if (!currentVariants) {
        currentVariants = [[NSArray array] retain];
    }
    [variantTable reloadData];
}

// NSTableView data source methods
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    if (tableView == layoutTable) {
        return [sortedLayouts count];
    } else if (tableView == variantTable) {
        return [currentVariants count];
    }
    return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (tableView == layoutTable) {
        NSString *code = [sortedLayouts objectAtIndex:row];
        NSString *desc = [layouts objectForKey:code];
        return [NSString stringWithFormat:@"%@ (%@)", desc, code];
    } else if (tableView == variantTable) {
        NSDictionary *entry = [currentVariants objectAtIndex:row];
        NSString *code = [entry objectForKey:@"code"];
        NSString *desc = [entry objectForKey:@"description"];
        return [NSString stringWithFormat:@"%@ (%@)", desc, code];
    }
    return nil;
}

// NSTableView delegate methods
- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    NSDebugLog(@"[Keyboard] tableViewSelectionDidChange: isRefreshing=%d", isRefreshing);
    if (isRefreshing) {
        NSDebugLog(@"[Keyboard] Ignoring table selection change during refresh");
        return;
    }
    NSTableView *tableView = [notification object];
    if (tableView == layoutTable) {
        NSInteger selectedRow = [layoutTable selectedRow];
        if (selectedRow >= 0 && selectedRow < (NSInteger)[sortedLayouts count]) {
            NSString *layout = [sortedLayouts objectAtIndex:selectedRow];
            NSDebugLog(@"[Keyboard] Layout table selection changed to row %ld: '%@'", (long)selectedRow, layout);
            [self populateVariantsForLayout:layout];
            [variantTable deselectAll:nil];
            [self applySelection:nil];
        }
    } else if (tableView == variantTable) {
        NSInteger selectedRow = [variantTable selectedRow];
        NSDebugLog(@"[Keyboard] Variant table selection changed to row %ld", (long)selectedRow);
        [self applySelection:nil];
    }
}

- (void)selectLayout:(NSString *)layout variant:(NSString *)variant
{
    NSDebugLog(@"[Keyboard] selectLayout: layout='%@' variant='%@' isRefreshing=%d", layout, variant, isRefreshing);
    if (![layout length]) {
        layout = @"us";
    }

    // ensure layout exists, otherwise fall back
    if (![layouts objectForKey:layout]) {
        NSDebugLog(@"[Keyboard] Layout '%@' not found in layouts dictionary", layout);
        NSArray *allKeys = [layouts allKeys];
        if ([allKeys containsObject:@"us"]) {
            NSDebugLog(@"[Keyboard] Falling back to 'us'");
            layout = @"us";
        } else if ([allKeys count] > 0) {
            NSDebugLog(@"[Keyboard] Falling back to first available layout");
            layout = [allKeys objectAtIndex:0];
        }
    }

    // Select layout in table
    NSInteger layoutIndex = [sortedLayouts indexOfObject:layout];
    NSDebugLog(@"[Keyboard] Looking for layout '%@' in sortedLayouts, index=%ld", layout, (long)layoutIndex);
    if (layoutIndex != NSNotFound) {
        [layoutTable selectRowIndexes:[NSIndexSet indexSetWithIndex:layoutIndex] byExtendingSelection:NO];
        [layoutTable scrollRowToVisible:layoutIndex];
    }

    [self populateVariantsForLayout:layout];

    // Select variant in table
    NSInteger variantIndex = NSNotFound;
    if ([variant length]) {
        for (NSUInteger i = 0; i < [currentVariants count]; i++) {
            NSDictionary *entry = [currentVariants objectAtIndex:i];
            if ([[entry objectForKey:@"code"] isEqualToString:variant]) {
                variantIndex = i;
                break;
            }
        }
    }
    NSDebugLog(@"[Keyboard] Looking for variant '%@', index=%ld", variant, (long)variantIndex);
    if (variantIndex != NSNotFound) {
        [variantTable selectRowIndexes:[NSIndexSet indexSetWithIndex:variantIndex] byExtendingSelection:NO];
        [variantTable scrollRowToVisible:variantIndex];
    } else {
        [variantTable deselectAll:nil];
    }
}

- (BOOL)applyLayout:(NSString *)layout variant:(NSString *)variant error:(NSString **)error
{
    return [self applyLayout:layout variant:variant options:@"" error:error];
}

- (BOOL)applyLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options error:(NSString **)error
{
    if (isRefreshing) {
        NSDebugLog(@"[Keyboard] applyLayout blocked during refresh");
        return YES;  // Pretend success during refresh
    }
    NSDebugLog(@"[Keyboard] applyLayout: layout='%@' variant='%@' options='%@'", layout, variant, options);
    if (!setxkbmapPath) {
        if (error) {
            *error = @"setxkbmap not found";
        }
        return NO;
    }

    NSString *trimmedLayout = [self trimmed:layout];
    NSString *trimmedVariant = [self trimmed:variant];
    NSString *trimmedOptions = [self trimmed:options];

    NSTask *clearTask = [[NSTask alloc] init];
    [clearTask setLaunchPath:setxkbmapPath];
    [clearTask setArguments:[NSArray arrayWithObjects:@"-option", @"", nil]];
    [clearTask launch];
    [clearTask waitUntilExit];
    [clearTask release];

    NSMutableArray *args = [NSMutableArray array];
    if ([trimmedLayout length]) {
        [args addObject:@"-layout"];
        [args addObject:trimmedLayout];
    }

    if ([trimmedVariant length]) {
        [args addObject:@"-variant"];
        [args addObject:trimmedVariant];
    }

    if ([trimmedOptions length]) {
        [args addObject:@"-option"];
        [args addObject:trimmedOptions];
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:setxkbmapPath];
    [task setArguments:args];

    NSPipe *stderrPipe = [NSPipe pipe];
    [task setStandardError:stderrPipe];

    [task launch];
    // Drain stderr before waitUntilExit to avoid pipe-buffer deadlock
    NSData *stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];

    int status = [task terminationStatus];
    [task release];

    if (status != 0) {
        NSString *stderrString = [[[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] autorelease];
        if (error) {
            *error = (stderrString.length ? stderrString : @"Failed to run setxkbmap");
        }
        return NO;
    }

    [lastAppliedLayout release];
    [lastAppliedVariant release];

    lastAppliedLayout = [trimmedLayout copy];
    lastAppliedVariant = [trimmedVariant copy];

    return YES;
}

- (void)persistUserDefaultsLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options keyboardType:(NSString *)keyboardType isApple:(BOOL)isApple
{
    if (isRefreshing) {
        NSDebugLog(@"[Keyboard] persistUserDefaultsLayout blocked during refresh");
        return;
    }
    NSDebugLog(@"[Keyboard] persistUserDefaultsLayout: layout='%@' variant='%@' options='%@' keyboardType='%@' isApple=%d", layout, variant, options, keyboardType, isApple);
    NSMutableDictionary *domain = [NSMutableDictionary dictionary];
    if (layout) {
        [domain setObject:layout forKey:@"layout"];
    }
    if (variant) {
        [domain setObject:variant forKey:@"variant"];
    }
    if (options) {
        [domain setObject:options forKey:@"options"];
    }
    if (keyboardType) {
        [domain setObject:keyboardType forKey:@"keyboardType"];
    }
    [domain setObject:[NSNumber numberWithBool:isApple] forKey:@"isApple"];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setPersistentDomain:domain forName:kKeyboardDomain];
    [defaults synchronize];
}

- (void)writeUserAutostartWithLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options keyboardType:(NSString *)keyboardType isApple:(BOOL)isApple
{
    if (isRefreshing) {
        NSDebugLog(@"[Keyboard] writeUserAutostartWithLayout blocked during refresh");
        return;
    }
    NSDebugLog(@"[Keyboard] writeUserAutostartWithLayout: layout='%@' variant='%@' options='%@' keyboardType='%@' isApple=%d", layout, variant, options, keyboardType, isApple);
    NSString *home = NSHomeDirectory();
    NSString *binDir = [home stringByAppendingPathComponent:@".local/bin"];
    NSString *scriptPath = [binDir stringByAppendingPathComponent:@"gershwin-apply-keyboard.sh"];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:binDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *escapedLayout = [self shellEscapedValue:(layout ? layout : @"")];
    NSString *escapedVariant = [self shellEscapedValue:(variant ? variant : @"")];
    NSString *escapedOptions = [self shellEscapedValue:(options ? options : @"")];
    NSString *model = [self modelForKeyboardType:(keyboardType ? keyboardType : @"") isApple:isApple];
    NSString *escapedModel = [self shellEscapedValue:model];

    NSMutableString *script = [NSMutableString string];
    [script appendString:@"#!/bin/sh\nset -e\n\nsetxkbmap_bin=\"/usr/local/bin/setxkbmap\"\n[ -x \"$setxkbmap_bin\" ] || setxkbmap_bin=\"/usr/bin/setxkbmap\"\n[ -x \"$setxkbmap_bin\" ] || exit 0\n\n$setxkbmap_bin -option '' >/dev/null 2>&1 || true\ncmd=\"$setxkbmap_bin -model '"];
    [script appendString:escapedModel];
    [script appendString:@"' -layout '"];
    [script appendString:escapedLayout];
    [script appendString:@"'\"\nif [ -n \""];
    [script appendString:escapedVariant];
    [script appendString:@"\" ]; then\n  cmd=\"$cmd -variant '"];
    [script appendString:escapedVariant];
    [script appendString:@"'\"\nfi\nif [ -n \""];
    [script appendString:escapedOptions];
    [script appendString:@"\" ]; then\n  cmd=\"$cmd -option '"];
    [script appendString:escapedOptions];
    [script appendString:@"'\"\nelse\n  cmd=\"$cmd -option ''\"\nfi\nsh -c \"$cmd\" >/dev/null 2>&1\n"];
    
    /*
     * Apple ISO Keyboard TLDE/LSGT Swap Fix
     * 
     * Problem: Apple ISO keyboards have two keys physically swapped compared to PC ISO keyboards:
     * 
     * PC ISO Layout:              Apple ISO Layout:
     *   Top-left: ^ (TLDE = 49)     Top-left: < (physically TLDE = 49)
     *   Left of Z: < (LSGT = 94)    Left of Z: ^ (physically LSGT = 94)
     * 
     * The XKB applealu_iso model correctly identifies the keyboard but does NOT remap
     * the keycodes to match the physical layout. This causes the symbols to appear wrong:
     * - Pressing the top-left key (expecting <) produces ^
     * - Pressing the left-of-Z key (expecting ^) produces <
     * 
     * Solution: After setxkbmap configures the layout, use xmodmap to swap the symbol
     * mappings for keycodes 49 and 94, so they match what users expect based on the
     * physical key labels and positions on Apple ISO keyboards.
     * 
     * For German (de) layout specifically:
     *   - Keycode 49 should produce: < > (less/greater with bar/dagger on level 3/4)
     *   - Keycode 94 should produce: ^ ° (circumflex/degree with notsign on level 3)
     */
    if (isApple && [keyboardType isEqualToString:@"ISO"]) {
        [script appendString:@"\n# Fix Apple ISO keyboard TLDE/LSGT swap\n"];
        [script appendString:@"if command -v xmodmap >/dev/null 2>&1; then\n"];
        [script appendString:@"  xmodmap -e 'keycode 49 = less greater less greater bar dagger bar' >/dev/null 2>&1 || true\n"];
        [script appendString:@"  xmodmap -e 'keycode 94 = asciicircum degree asciicircum degree notsign notsign notsign' >/dev/null 2>&1 || true\n"];
        [script appendString:@"fi\n"];
    }

    [script writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *attrs = [NSDictionary dictionaryWithObject:[NSNumber numberWithShort:0755] forKey:NSFilePosixPermissions];
    [fm setAttributes:attrs ofItemAtPath:scriptPath error:nil];
}

- (BOOL)updateSystemKeyboardFileWithLayout:(NSString *)layout variant:(NSString *)variant options:(NSString *)options keyboardType:(NSString *)keyboardType isApple:(BOOL)isApple error:(NSString **)error
{
    if (isRefreshing) {
        NSDebugLog(@"[Keyboard] updateSystemKeyboardFileWithLayout blocked during refresh");
        if (error) {
            *error = @"Skipped during refresh";
        }
        return NO;
    }
    NSDebugLog(@"[Keyboard] updateSystemKeyboardFileWithLayout: layout='%@' variant='%@' options='%@' keyboardType='%@' isApple=%d", layout, variant, options, keyboardType, isApple);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];

    NSDictionary *systemDefaults = [self systemKeyboardDefaults];
    NSString *model = nil;
    if ([keyboardType length]) {
        model = [self modelForKeyboardType:keyboardType isApple:isApple];
    } else {
        model = [systemDefaults objectForKey:@"XKBMODEL"];
        if (![model length]) {
            // Default to a reasonable PC ISO model if nothing else is known
            model = @"pc105";
        }
    }

    NSMutableString *payload = [NSMutableString string];
    [payload appendFormat:@"XKBMODEL=\"%@\"\n", model];
    [payload appendFormat:@"XKBLAYOUT=\"%@\"\n", (layout ? layout : @"")];
    [payload appendFormat:@"XKBVARIANT=\"%@\"\n", (variant ? variant : @"")];
    [payload appendFormat:@"XKBOPTIONS=\"%@\"\n", (options ? options : @"")];

    if (![payload writeToFile:tmpPath atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        if (error) {
            *error = @"Unable to write temporary keyboard file";
        }
        return NO;
    }

    NSString *sudoPath = @"/usr/bin/sudo";
    if (![fm isExecutableFileAtPath:sudoPath]) {
        [fm removeItemAtPath:tmpPath error:nil];
        if (error) {
            *error = @"sudo not available";
        }
        return NO;
    }

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:sudoPath];
    [task setArguments:[NSArray arrayWithObjects:@"-E", @"-A", @"install", @"-m", @"644", tmpPath, kDefaultKeyboardFile, nil]];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardError:pipe];

    [task launch];
    [task waitUntilExit];

    int status = [task terminationStatus];
    NSData *stderrData = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *stderrString = [[[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] autorelease];

    [task release];
    [fm removeItemAtPath:tmpPath error:nil];

    if (status != 0) {
        if (error) {
            *error = (stderrString.length ? stderrString : @"Failed to update /etc/default/keyboard");
        }
        return NO;
    }

    return YES;
}

- (NSString *)modelForKeyboardType:(NSString *)keyboardType isApple:(BOOL)isApple
{
    if (isApple) {
        if ([keyboardType isEqualToString:@"ISO"]) {
            return @"applealu_iso";
        } else if ([keyboardType isEqualToString:@"JIS"]) {
            return @"applealu_jis";
        } else {
            return @"applealu_ansi";
        }
    } else {
        if ([keyboardType isEqualToString:@"ISO"]) {
            return @"pc105";
        } else if ([keyboardType isEqualToString:@"JIS"]) {
            return @"pc106";
        } else {
            return @"pc104";
        }
    }
}

- (NSString *)shellEscapedValue:(NSString *)value
{
    NSString *v = (value ? value : @"");
    return [v stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
}

- (NSString *)trimmed:(NSString *)value
{
    if (!value) {
        return @"";
    }
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)updateStatus:(NSString *)message
{
    [statusLabel setStringValue:(message ? message : @"")];
}

- (void)showAlertWithTitle:(NSString *)title text:(NSString *)text
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:(title ? title : @"Keyboard Preference")];
    [alert setInformativeText:(text ? text : @"")];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (IBAction)isAppleKeyboardCheckboxChanged:(id)sender
{
    (void)sender;
    // Don't apply changes during initial refresh
    if (isRefreshing) {
        return;
    }
    [self applySelection:nil];
}

- (IBAction)keyboardTypeChanged:(id)sender
{
    (void)sender;
    // Don't apply changes during initial refresh
    if (isRefreshing) {
        return;
    }
    [self applySelection:nil];
}

- (IBAction)applySelection:(id)sender
{
    NSDebugLog(@"[Keyboard] applySelection called, isRefreshing=%d", isRefreshing);
    (void)sender;
    // Don't apply changes during initial refresh
    if (isRefreshing) {
        NSDebugLog(@"[Keyboard] Blocking applySelection during refresh");
        return;
    }
    [self ensureMetadataLoaded];

    NSInteger layoutRow = [layoutTable selectedRow];
    NSString *layout = (layoutRow >= 0 && layoutRow < (NSInteger)[sortedLayouts count]) ? [sortedLayouts objectAtIndex:layoutRow] : nil;

    NSInteger variantRow = [variantTable selectedRow];
    NSString *variant = nil;
    if (variantRow >= 0 && variantRow < (NSInteger)[currentVariants count]) {
        NSDictionary *entry = [currentVariants objectAtIndex:variantRow];
        variant = [entry objectForKey:@"code"];
    }

    NSString *options = @"";
    if ([isAppleKeyboardCheckbox state] == NSOnState) {
        options = @"altwin:swap_alt_win";
    }

    NSString *keyboardType = [[keyboardTypePopup titleOfSelectedItem] copy];
    BOOL isApple = ([isAppleKeyboardCheckbox state] == NSOnState);

    NSDebugLog(@"[Keyboard] Applying layout='%@' variant='%@' options='%@' keyboardType='%@' isApple=%d", layout, variant, options, keyboardType, isApple);

    [self updateStatus:@"Applying layout..."];

    // Capture values for the block
    NSString *layoutCopy  = [layout copy];
    NSString *variantCopy = [variant copy];
    NSString *optionsCopy = [options copy];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *applyError = nil;
        BOOL success = [self applyLayout:layoutCopy variant:variantCopy options:optionsCopy error:&applyError];
        NSString *errorCopy = [applyError copy];

        // Apple ISO TLDE/LSGT swap
        if (success && isApple && [keyboardType isEqualToString:@"ISO"]) {
            NSDebugLog(@"[Keyboard] Applying TLDE/LSGT swap for Apple ISO keyboard");
            NSTask *xmodmapTask = [[NSTask alloc] init];
            [xmodmapTask setLaunchPath:@"/usr/bin/xmodmap"];
            [xmodmapTask setArguments:[NSArray arrayWithObjects:
                @"-e", @"keycode 49 = less greater less greater bar dagger bar",
                @"-e", @"keycode 94 = asciicircum degree asciicircum degree notsign notsign notsign",
                nil]];
            [xmodmapTask launch];
            [xmodmapTask waitUntilExit];
            [xmodmapTask release];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!success) {
                [self showAlertWithTitle:@"Could not set layout" text:errorCopy];
                [self updateStatus:[NSString stringWithFormat:@"Failed to apply layout (%@)", errorCopy ? errorCopy : @"unknown error"]];
                [errorCopy release];
                [layoutCopy release];
                [variantCopy release];
                [optionsCopy release];
                [keyboardType release];
                return;
            }
            [errorCopy release];

            [self persistUserDefaultsLayout:layoutCopy variant:variantCopy options:optionsCopy keyboardType:keyboardType isApple:isApple];
            [self writeUserAutostartWithLayout:layoutCopy variant:variantCopy options:optionsCopy keyboardType:keyboardType isApple:isApple];

            NSString *systemError = nil;
            BOOL systemUpdated = [self updateSystemKeyboardFileWithLayout:layoutCopy variant:variantCopy options:optionsCopy keyboardType:keyboardType isApple:isApple error:&systemError];

            NSMutableString *status = [NSMutableString stringWithFormat:@"Active layout: %@", layoutCopy];
            if ([variantCopy length]) {
                [status appendFormat:@" / %@", variantCopy];
            }
            if ([keyboardType length]) {
                [status appendFormat:@" (%@)", keyboardType];
            }

            if (systemUpdated) {
                [status appendString:@" — saved to /etc/default/keyboard."];
            } else {
                [status appendString:@" — saved for this user. System file not updated."];
                if ([systemError length]) {
                    [status appendFormat:@" (%@)", systemError];
                }
            }

            [self updateStatus:status];
            [layoutCopy release];
            [variantCopy release];
            [optionsCopy release];
            [keyboardType release];
        });
    });
}

- (void)refreshFromSystem
{
    NSDebugLog(@"[Keyboard] refreshFromSystem: START");
    [self ensureMetadataLoaded];
    isRefreshing = YES;
    NSDebugLog(@"[Keyboard] isRefreshing set to YES");

    // Gather data that can be read synchronously (file reads, user defaults)
    NSDictionary *system = [self systemKeyboardDefaults];
    NSDictionary *saved  = [self savedPreferences];

    // Move the potentially blocking setxkbmap query off the main thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *xkbCurrent = [self currentXkbmapSettingsSync];

        // Come back to the main thread for all UI updates
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *layout = [system objectForKey:@"XKBLAYOUT"];
            NSString *variant = [system objectForKey:@"XKBVARIANT"];
            NSString *options = [system objectForKey:@"XKBOPTIONS"];
            NSString *keyboardType = nil;
            NSNumber *savedIsApple = nil;
            NSDebugLog(@"[Keyboard] System config file: layout='%@' variant='%@' options='%@'", layout, variant, options);

            // If system config is empty, try current XKB settings
            if (![layout length]) {
                NSDebugLog(@"[Keyboard] System config empty, trying current XKB settings");
                layout = [xkbCurrent objectForKey:@"layout"];
                variant = [xkbCurrent objectForKey:@"variant"];
                options = [xkbCurrent objectForKey:@"options"];
                NSDebugLog(@"[Keyboard] Current XKB: layout='%@' variant='%@' options='%@'", layout, variant, options);
                if ([layout rangeOfString:@","].location != NSNotFound) {
                    layout = [[layout componentsSeparatedByString:@","] objectAtIndex:0];
                }
                if ([variant rangeOfString:@","].location != NSNotFound) {
                    variant = [[variant componentsSeparatedByString:@","] objectAtIndex:0];
                }
            }

            // If still empty, try saved preferences
            if (![layout length]) {
                NSDebugLog(@"[Keyboard] Still empty, trying saved preferences");
                layout = [saved objectForKey:@"layout"];
                variant = [saved objectForKey:@"variant"];
                options = [saved objectForKey:@"options"];
                keyboardType = [saved objectForKey:@"keyboardType"];
                savedIsApple = [saved objectForKey:@"isApple"];
                if (savedIsApple) {
                    [isAppleKeyboardCheckbox setState:([savedIsApple boolValue] ? NSOnState : NSOffState)];
                }
            }

            // If keyboardType not found in saved prefs, try to infer from system model
            if (!keyboardType) {
                NSString *model = [system objectForKey:@"XKBMODEL"];
                if ([model isEqualToString:@"pc104"] || [model isEqualToString:@"applealu_ansi"]) {
                    keyboardType = @"ANSI";
                } else if ([model isEqualToString:@"pc105"] || [model isEqualToString:@"applealu_iso"]) {
                    keyboardType = @"ISO";
                } else if ([model isEqualToString:@"pc106"] || [model isEqualToString:@"applealu_jis"]) {
                    keyboardType = @"JIS";
                } else {
                    keyboardType = @"ANSI";
                }
            }

            NSDebugLog(@"[Keyboard] Final values to select: layout='%@' variant='%@' options='%@' keyboardType='%@'", layout, variant, options, keyboardType);
            [self selectLayout:layout variant:variant];

            // Determine Apple state
            BOOL modelIndicatesApple = NO;
            NSString *modelVal = [system objectForKey:@"XKBMODEL"];
            if (modelVal && [modelVal hasPrefix:@"apple"]) {
                modelIndicatesApple = YES;
            }
            BOOL isApple = NO;
            if (savedIsApple) {
                isApple = [savedIsApple boolValue];
            } else if (modelIndicatesApple) {
                isApple = YES;
            } else if ([options isEqualToString:@"altwin:swap_alt_win"]) {
                isApple = YES;
            }

            [isAppleKeyboardCheckbox setState:(isApple ? NSOnState : NSOffState)];

            if ([keyboardType length]) {
                [keyboardTypePopup selectItemWithTitle:keyboardType];
            } else {
                [keyboardTypePopup selectItemAtIndex:0];
            }

            NSMutableString *status = [NSMutableString stringWithFormat:@"Current layout: %@", layout ? layout : @"(unknown)"];
            if ([variant length]) {
                [status appendFormat:@" / %@", variant];
            }
            if ([keyboardType length]) {
                [status appendFormat:@" (%@)", keyboardType];
            }
            if ([options length]) {
                [status appendFormat:@" (%@)", options];
            }

            [status appendString:@". Changes apply instantly."];
            [self updateStatus:status];

            isRefreshing = NO;
            NSDebugLog(@"[Keyboard] refreshFromSystem: END");
        });
    });
}

@end

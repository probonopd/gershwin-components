/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "ActionSearch.h"
#import "AppMenuWidget.h"
#import "X11ShortcutManager.h"
#import "MenuUtils.h"
#import "WindowMonitor.h"
#import <GNUstepGUI/GSTheme.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <dispatch/dispatch.h>

static ActionSearchController *_sharedController = nil;
static pthread_mutex_t _singletonMutex = PTHREAD_MUTEX_INITIALIZER;

static const CGFloat kSearchFieldWidth = 200;
static const CGFloat kSearchFieldHeight = 22;
static const CGFloat kMaxResultsShown = 15;


#pragma mark - ActionSearchResult

@implementation ActionSearchResult

- (id)initWithMenuItem:(NSMenuItem *)item path:(NSString *)path
{
    self = [super init];
    if (self) {
        self.menuItem = item;
        self.title = [item title];
        self.path = path;
        self.keyEquivalent = [item keyEquivalent] ?: @"";
        self.modifierMask = [item keyEquivalentModifierMask];
        self.enabled = [item isEnabled];
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"ActionSearchResult: %@ (%@)", self.title, self.path];
}

@end


#pragma mark - ActionSearchController

@interface NSTextView (ActionSearchSwizzle)
- (void)gw_moveUp:(id)sender;
- (void)gw_moveDown:(id)sender;
- (void)gw_complete:(id)sender;
@end

@implementation NSTextView (ActionSearchSwizzle)

- (void)gw_moveUp:(id)sender
{
    id delegate = [self delegate];
    /* The field editor's delegate is the NSTextField, whose own delegate is
       the search controller.  Walk the chain and route through
       control:textView:doCommandBySelector: so arrow navigation reaches the
       search controller. */
    if (delegate && [delegate respondsToSelector:@selector(delegate)]) {
        id owner = [delegate delegate];
        if (owner && [owner respondsToSelector:@selector(control:textView:doCommandBySelector:)]) {
            if ([owner control:nil textView:self doCommandBySelector:@selector(moveUp:)]) {
                return;
            }
        }
    }
    [self gw_moveUp:sender];
}

- (void)gw_moveDown:(id)sender
{
    id delegate = [self delegate];
    if (delegate && [delegate respondsToSelector:@selector(delegate)]) {
        id owner = [delegate delegate];
        if (owner && [owner respondsToSelector:@selector(control:textView:doCommandBySelector:)]) {
            if ([owner control:nil textView:self doCommandBySelector:@selector(moveDown:)]) {
                return;
            }
        }
    }
    [self gw_moveDown:sender];
}

- (void)gw_complete:(id)sender
{
    ActionSearchController *ctrl = [ActionSearchController sharedController];
    if ([ctrl.searchPanel isVisible]) {
        [ctrl.searchField setStringValue:@""];
        [ctrl hideSearchPopup];
        [NSApp hide:nil];
        return;
    }
    [self gw_complete:sender];
}

@end

static const NSTimeInterval kFocusLossArmDelay = 0.05;

@interface ActionSearchController ()
@property (nonatomic, assign) BOOL resultsMenuTracking;
@property (nonatomic, assign) BOOL focusLossArmed;
@end

@implementation ActionSearchController

+ (void)initialize
{
    [super initialize];

    static BOOL swizzled = NO;
    if (!swizzled) {
        Method originalMoveUp = class_getInstanceMethod([NSTextView class], @selector(moveUp:));
        Method swizzledMoveUp = class_getInstanceMethod([NSTextView class], @selector(gw_moveUp:));
        if (originalMoveUp && swizzledMoveUp) {
            method_exchangeImplementations(originalMoveUp, swizzledMoveUp);
        }

        Method originalMoveDown = class_getInstanceMethod([NSTextView class], @selector(moveDown:));
        Method swizzledMoveDown = class_getInstanceMethod([NSTextView class], @selector(gw_moveDown:));
        if (originalMoveDown && swizzledMoveDown) {
            method_exchangeImplementations(originalMoveDown, swizzledMoveDown);
        }

        Method originalComplete = class_getInstanceMethod([NSTextView class], @selector(complete:));
        Method swizzledComplete = class_getInstanceMethod([NSTextView class], @selector(gw_complete:));
        if (originalComplete && swizzledComplete) {
            method_exchangeImplementations(originalComplete, swizzledComplete);
        }

        swizzled = YES;
    }
}

- (void)_deferredFocusToSearchField
{
    if ([self.searchPanel isVisible]) {
        [self.searchPanel makeKeyWindow];
        [self.searchPanel makeFirstResponder:self.searchField];
        [self.searchField selectText:nil];
    }
}

+ (instancetype)sharedController
{
    pthread_mutex_lock(&_singletonMutex);
    if (_sharedController == nil) {
        _sharedController = [[ActionSearchController alloc] init];
    }
    pthread_mutex_unlock(&_singletonMutex);
    return _sharedController;
}

- (id)init
{
    self = [super init];
    if (self) {
        self.allMenuItems = [NSMutableArray array];
        self.filteredResults = [NSMutableArray array];

        [self createSearchPanel];
        [self createResultsMenu];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(searchPanelDidResignKey:)
                                                   name:NSWindowDidResignKeyNotification
                                                 object:self.searchPanel];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(applicationDidResignActive:)
                                                   name:NSApplicationDidResignActiveNotification
                                                 object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(activeWindowChanged:)
                                                   name:WindowMonitorActiveWindowChangedNotification
                                                 object:nil];
        _focusLossArmed = NO;
    }
    return self;
}

- (void)createSearchPanel
{
    // Minimal borderless panel — just a surface for the text field, no extras
    NSRect panelRect = NSMakeRect(0, 0, kSearchFieldWidth, kSearchFieldHeight);

    self.searchPanel = [[NSPanel alloc] initWithContentRect:panelRect
                                                  styleMask:NSBorderlessWindowMask
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    [self.searchPanel setLevel:NSStatusWindowLevel];
    [self.searchPanel setHasShadow:NO];
    [self.searchPanel setOpaque:NO];
    [self.searchPanel setBackgroundColor:[NSColor clearColor]];
    [self.searchPanel setBecomesKeyOnlyIfNeeded:NO];
    [self.searchPanel setReleasedWhenClosed:NO];
    /* NSPanel defaults to hidesOnDeactivate:YES.  That makes GNUstep remember
       the panel when the app deactivates and order it front again when the
       app reactivates - which would reopen the search box the moment the
       user clicks back on the menu bar after it was dismissed.  The search
       panel is closed explicitly (hideSearchPopup), so it must not be
       auto-hidden and auto-re-shown by the app activation cycle. */
    [self.searchPanel setHidesOnDeactivate:NO];

    // Search field fills the panel exactly — no padding
    BOOL themeSearch = [NSSearchFieldCell instancesRespondToSelector:@selector(EAUsearchButtonRectForBounds:)];
    if (themeSearch)
      {
        self.searchField = [[NSSearchField alloc] initWithFrame:panelRect];
      }
    else
      {
        NSTextField *tf = [[NSTextField alloc] initWithFrame:panelRect];
        [tf setBezeled:YES];
        [tf setBezelStyle:NSTextFieldRoundedBezel];
        [tf setEditable:YES];
        [tf setSelectable:YES];
        [tf setEnabled:YES];
        [tf setFont:[NSFont menuFontOfSize:0]];
        self.searchField = tf;
      }
    [self.searchField setDelegate:self];
    /* Enter in a text field ends editing and fires the field's action; the
       search box must act on Return, so point the action at the submit
       handler (which launches the highlighted or first matching result). */
    [self.searchField setTarget:self];
    [self.searchField setAction:@selector(searchFieldSubmit:)];
    [self.searchField setFont:[NSFont menuFontOfSize:0]];

    NSAttributedString *placeholder = [[NSAttributedString alloc]
        initWithString:@"Search menus..."
        attributes:@{
            NSForegroundColorAttributeName: [NSColor grayColor],
            NSFontAttributeName: [NSFont menuFontOfSize:0]
        }];
    [[self.searchField cell] setPlaceholderAttributedString:placeholder];

    [[self.searchPanel contentView] addSubview:self.searchField];

    NSDebugLLog(@"gwcomp", @"ActionSearchController: Created search panel (no padding)");
}

- (void)createResultsMenu
{
    self.resultsMenu = [[NSMenu alloc] initWithTitle:@"Search Results"];
    [self.resultsMenu setAutoenablesItems:NO];
    [self.resultsMenu setDelegate:self];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(resultsMenuDidBeginTracking:)
                                                 name:NSMenuDidBeginTrackingNotification
                                               object:self.resultsMenu];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(resultsMenuDidEndTracking:)
                                                 name:NSMenuDidEndTrackingNotification
                                               object:self.resultsMenu];

    NSDebugLLog(@"gwcomp", @"ActionSearchController: Created results menu");
}

- (void)setAppMenuWidget:(AppMenuWidget *)widget
{
    _appMenuWidget = widget;
}

- (void)showSearchPopupAtPoint:(NSPoint)point
{
    (void)point;

    [[X11ShortcutManager sharedManager] suspendKeyGrabs];

    [self collectMenuItems];
    [self.searchField setStringValue:@""];
    [self.filteredResults removeAllObjects];

    // Position panel below the menu bar, at the left edge of the screen
    NSRect panelFrame = [self.searchPanel frame];
    NSRect screenFrame = [[NSScreen mainScreen] frame];
    const CGFloat menuBarHeight = [[GSTheme theme] menuBarHeight];

    panelFrame.origin.x = screenFrame.origin.x + 8;
    panelFrame.origin.y = screenFrame.origin.y + screenFrame.size.height
                          - menuBarHeight - panelFrame.size.height;

    [self.searchPanel setFrame:panelFrame display:YES];

    [NSApp activateIgnoringOtherApps:YES];

    [self.searchPanel makeKeyAndOrderFront:nil];

    [self.searchPanel makeFirstResponder:self.searchField];
    [self.searchField selectText:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self _deferredFocusToSearchField];
    });

    [NSApp activateIgnoringOtherApps:YES];
    [self.searchPanel makeKeyWindow];
    [self.searchPanel makeFirstResponder:self.searchField];
    [self.searchField selectText:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self _deferredFocusToSearchField];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self _deferredFocusToSearchField];
    });

    // Arm focus-loss detection after a grace period to avoid premature
    // closing during the initial window-switch / focus-grab sequence.
    self.focusLossArmed = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFocusLossArmDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self.searchPanel isVisible]) {
            self.focusLossArmed = YES;
        }
    });

    self.resultsMenuTracking = NO;

    NSDebugLLog(@"gwcomp", @"ActionSearchController: Showing search panel below menu bar");
}

- (void)hideSearchPopup
{
    self.focusLossArmed = NO;

    if (self.resultsMenuTracking) {
        if ([self.resultsMenu respondsToSelector:@selector(cancelTracking)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.resultsMenu performSelector:@selector(cancelTracking)];
            #pragma clang diagnostic pop
        }
        self.resultsMenuTracking = NO;
    }

    [self closeAllMenuWindows];

    [self.searchPanel orderOut:nil];
    [[X11ShortcutManager sharedManager] resumeKeyGrabs];
    NSDebugLLog(@"gwcomp", @"ActionSearchController: Hiding search popup");
}

- (void)toggleSearchPopupAtPoint:(NSPoint)point
{
    if ([self.searchPanel isVisible]) {
        [self hideSearchPopup];
    } else {
        [self showSearchPopupAtPoint:point];
    }
}

- (BOOL)isSearchVisible
{
    /* GNUstep can leave the panel flagged visible while its X11 window is
       unmapped - e.g. when the search was opened while another app had the
       focus and the ordering was deferred.  Only treat the search as visible
       when the panel is really on screen, so toggling can re-show it. */
    if (![self.searchPanel isVisible]) return NO;
    Display *display = [MenuUtils sharedDisplay];
    if (!display) return YES;
    Window xid = (Window)(uintptr_t)[self.searchPanel windowRef];
    if (xid == 0) return NO;
    XWindowAttributes attrs;
    return (XGetWindowAttributes(display, xid, &attrs) == Success
            && attrs.map_state == IsViewable);
}

- (void)toggleSearch:(id)sender
{
    (void)sender;

    if ([self isSearchVisible]) {
        [self hideSearchPopup];
        return;
    }

    NSRect screenFrame = [[NSScreen mainScreen] frame];
    NSPoint centerPoint = NSMakePoint(
        screenFrame.origin.x + screenFrame.size.width / 2,
        screenFrame.origin.y + screenFrame.size.height / 2 + 200
    );

    [self showSearchPopupAtPoint:centerPoint];
}

#pragma mark - Menu Collection

- (void)collectMenuItems
{
    [self.allMenuItems removeAllObjects];

    if (!self.appMenuWidget) {
        NSDebugLLog(@"gwcomp", @"ActionSearchController: No appMenuWidget set");
        return;
    }

    NSMenu *currentMenu = [self.appMenuWidget currentMenu];
    if (!currentMenu) {
        NSDebugLLog(@"gwcomp", @"ActionSearchController: No current menu available");
        return;
    }

    /* Populate the dynamic Applications submenu (app launchers) before
       collecting, so applications are searchable even when the Command menu
       has never been opened. */
    if ([self.appMenuWidget respondsToSelector:@selector(ensureSystemMenuPopulated)]) {
        [self.appMenuWidget ensureSystemMenuPopulated];
    }

    NSDebugLLog(@"gwcomp", @"ActionSearchController: Collecting items from: %@", [currentMenu title]);
    [self collectItemsFromMenu:currentMenu withPath:@""];
    NSDebugLLog(@"gwcomp", @"ActionSearchController: Collected %lu menu items", (unsigned long)[self.allMenuItems count]);
}

- (void)collectItemsFromMenu:(NSMenu *)menu withPath:(NSString *)path
{
    if (!menu) return;

    for (NSMenuItem *item in [menu itemArray]) {
        if ([item isSeparatorItem]) continue;

        if ([[item title] isEqualToString:@"Search..."]) continue;

        NSString *itemPath;
        NSString *itemTitle = [item title];

        if ([item hasSubmenu]) {
            itemTitle = [NSString stringWithFormat:@"%@ \u25B7", itemTitle];
        }

        if ([path length] > 0) {
            itemPath = [NSString stringWithFormat:@"%@ %@", path, itemTitle];
        } else {
            itemPath = itemTitle;
        }

        if ([item hasSubmenu]) {
            [self collectItemsFromMenu:[item submenu] withPath:itemPath];
        } else if ([item action] != nil) {
            ActionSearchResult *result = [[ActionSearchResult alloc] initWithMenuItem:item path:itemPath];
            [self.allMenuItems addObject:result];
        }
    }
}

#pragma mark - Search

- (void)searchWithString:(NSString *)searchString
{
    [self.filteredResults removeAllObjects];

    if ([searchString length] == 0) {
        return;
    }

    NSString *lowercaseSearch = [searchString lowercaseString];

    for (ActionSearchResult *result in self.allMenuItems) {
        NSString *lowercaseTitle = [[result title] lowercaseString];
        NSString *lowercasePath = [[result path] lowercaseString];

        if ([lowercaseTitle rangeOfString:lowercaseSearch].location != NSNotFound ||
            [lowercasePath rangeOfString:lowercaseSearch].location != NSNotFound) {
            [self.filteredResults addObject:result];
        }

        if ([self.filteredResults count] >= kMaxResultsShown) {
            break;
        }
    }

    NSDebugLLog(@"gwcomp", @"ActionSearchController: Search '%@' found %lu results",
          searchString, (unsigned long)[self.filteredResults count]);

    if ([self.filteredResults count] == 0) {
        /* No match - hide the results menu so a stale, emptied window does not
           stay mapped as a blank rectangle below the search box. */
        [self closeResultsMenuWindow];
        return;
    }

    [self showResultsMenu];
}

/* Order out the results-menu window (and its panels) without touching the
   search box itself.  The box and the results menu are shown and hidden
   together; this only tears down the menu when a query stops matching. */
- (void)closeResultsMenuWindow
{
    @try
        {
            NSWindow *menuWindow = [self.resultsMenu window];
            if (menuWindow && [menuWindow isVisible]) {
                [menuWindow orderOut:nil];
            }
        }
    @catch (NSException *e)
        {
            NSDebugLLog(@"gwcomp", @"ActionSearchController: closeResultsMenuWindow: %@", e);
        }
}

- (void)showResultsMenu
{
    [self showResultsMenuWithHighlight:-1];
}

- (void)showResultsMenuWithHighlight:(NSInteger)highlightIndex
{
    if (![self.searchPanel isVisible]) {
        NSDebugLLog(@"gwcomp", @"ActionSearchController: Not showing results - search not visible");
        return;
    }

    NSString *currentQuery = [[self.searchField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([currentQuery length] == 0) {
        return;
    }

    [self.resultsMenu removeAllItems];

    if ([self.filteredResults count] == 0) {
        return;
    }

    NSString *previousTopLevelMenu = @"";
    for (NSUInteger i = 0; i < [self.filteredResults count]; i++) {
        ActionSearchResult *result = [self.filteredResults objectAtIndex:i];

        NSString *topLevelMenu = result.path;
        NSRange firstSpace = [topLevelMenu rangeOfString:@" "];
        if (firstSpace.location != NSNotFound) {
            topLevelMenu = [topLevelMenu substringToIndex:firstSpace.location];
        }
        topLevelMenu = [topLevelMenu stringByReplacingOccurrencesOfString:@" \u25B7" withString:@""];

        if (i > 0 && ![topLevelMenu isEqual:previousTopLevelMenu]) {
            [self.resultsMenu addItem:[NSMenuItem separatorItem]];
        }

        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[result path]
                                                       action:@selector(resultMenuItemClicked:)
                                                keyEquivalent:@""];
        [item setTarget:self];
        [item setRepresentedObject:result];
        [item setEnabled:[result enabled]];

        if ([[result keyEquivalent] length] > 0) {
            [item setKeyEquivalent:[result keyEquivalent]];
            [item setKeyEquivalentModifierMask:[result modifierMask]];
        }

        [self.resultsMenu addItem:item];
        previousTopLevelMenu = topLevelMenu;
    }

    if (self.resultsMenuTracking) {
        if ([self.resultsMenu respondsToSelector:@selector(cancelTracking)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self.resultsMenu performSelector:@selector(cancelTracking)];
            #pragma clang diagnostic pop
        }
        self.resultsMenuTracking = NO;
    }

    // Position menu flush below the search field using the panel's content view
    NSView *contentView = [self.searchPanel contentView];
    NSPoint menuLocation = NSMakePoint(0, 0);

    self.resultsMenuTracking = YES;
    [self.resultsMenu popUpMenuPositioningItem:nil
                                    atLocation:menuLocation
                                        inView:contentView];

    /* Highlight the target item AFTER the popup is positioned: displayPopUpMenu:
       re-sizes and re-populates the menu view, which resets the highlight.  The
       highlighted index lives on the NSMenuView (menuRepresentation), not the
       NSMenu. */
    if (highlightIndex >= 0) {
        id menuRep = [self.resultsMenu menuRepresentation];
        if (menuRep && [menuRep respondsToSelector:@selector(setHighlightedItemIndex:)]) {
            [menuRep setHighlightedItemIndex:highlightIndex];
            [menuRep setNeedsDisplay:YES];
        }
    }
}

- (void)resultMenuItemClicked:(NSMenuItem *)sender
{
    ActionSearchResult *result = [sender representedObject];
    if (result) {
        NSDebugLLog(@"gwcomp", @"ActionSearchController: Selected: %@", [result path]);
        [self hideSearchPopup];
        [self executeActionForResult:result];
    }
}

#pragma mark - Action Execution

- (void)executeActionForResult:(ActionSearchResult *)result
{
    if (!result || !result.menuItem) {
        NSDebugLLog(@"gwcomp", @"ActionSearchController: Cannot execute - no result or menu item");
        return;
    }

    NSMenuItem *originalItem = result.menuItem;

    NSDebugLLog(@"gwcomp", @"ActionSearchController: Executing action for: %@", [result path]);

    if ([originalItem target] && [originalItem action]) {
        @try {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [[originalItem target] performSelector:[originalItem action] withObject:originalItem];
            #pragma clang diagnostic pop
        } @catch (NSException *exception) {
            NSDebugLLog(@"gwcomp", @"ActionSearchController: Exception executing action: %@", exception);
        }
    } else if ([originalItem action]) {
        [NSApp sendAction:[originalItem action] to:nil from:originalItem];
    }
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidChange:(NSNotification *)notification
{
    (void)notification;
    NSString *searchString = [self.searchField stringValue];
    [self searchWithString:searchString];
}

#pragma mark - Focus Tracking

- (void)closeAllMenuWindows
{
    for (NSWindow *win in [NSApp windows]) {
        NSString *cls = NSStringFromClass([win class]);
        if ([cls hasPrefix:@"NSMenu"] || [cls hasPrefix:@"NSStatusBar"]) {
            @try {
                [win orderOut:nil];
                NSDebugLLog(@"gwcomp", @"ActionSearchController: Closed menu window of class %@", cls);
            } @catch (NSException *e) {
                (void)e;
            }
        }
    }
}

- (void)searchPanelDidResignKey:(NSNotification *)notification
{
    (void)notification;
    if (!self.focusLossArmed) return;
    if (self.resultsMenuTracking) return;
    [self hideSearchPopup];
}

- (void)applicationDidResignActive:(NSNotification *)notification
{
    (void)notification;
    if (!self.focusLossArmed) return;
    [self hideSearchPopup];
}

- (void)activeWindowChanged:(NSNotification *)notification
{
    if (!self.focusLossArmed) return;
    if (![self.searchPanel isVisible]) return;

    unsigned long newWindowId = [[notification.userInfo objectForKey:@"windowId"] unsignedLongValue];
    if (newWindowId == 0) return;
    if ((Window)newWindowId == (Window)[self.searchPanel windowNumber]) return;

    // Check by NSApp first, then by PID (catches NSMenuWindow popups).
    BOOL isMenuAppWindow = ([NSApp windowWithWindowNumber:newWindowId] != nil);
    if (!isMenuAppWindow) {
        pid_t windowPID = [MenuUtils getWindowPID:newWindowId];
        isMenuAppWindow = (windowPID == [[NSProcessInfo processInfo] processIdentifier]);
    }
    if (isMenuAppWindow) return;

    [self hideSearchPopup];
}

- (void)resultsMenuDidBeginTracking:(NSNotification *)notification
{
    (void)notification;
    self.resultsMenuTracking = YES;
}

- (void)resultsMenuDidEndTracking:(NSNotification *)notification
{
    (void)notification;
    self.resultsMenuTracking = NO;

    // If the panel lost key while the menu was open (click outside), close immediately.
    if (![self.searchPanel isKeyWindow]) {
        [self hideSearchPopup];
        return;
    }

    // Still key.  Close only if the menu was dismissed by Escape - a regular
    // typed character also produces a keyDown here while the results menu is
    // being re-shown on each keystroke, and must NOT close the search box.
    NSEvent *currentEvent = [NSApp currentEvent];
    if (currentEvent && [currentEvent type] == NSKeyDown) {
        NSString *chars = [currentEvent charactersIgnoringModifiers];
        if ([chars length] > 0 && [chars characterAtIndex:0] == 0x1B) {
            [self hideSearchPopup];
            return;
        }
    }
}

#pragma mark - NSMenuDelegate

- (void)menuWillOpen:(NSMenu *)menu
{
    if (menu == self.resultsMenu) {
        if (![self.searchPanel isVisible]) {
            NSDebugLLog(@"gwcomp", @"ActionSearchController: Preventing results menu open because search is hidden");
            [self closeAllMenuWindows];
            self.resultsMenuTracking = NO;
        }
    }
}

- (void)menuDidClose:(NSMenu *)menu
{
    if (menu == self.resultsMenu) {
        self.resultsMenuTracking = NO;
    }
}

- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector
{
    return [self control:nil textView:textView doCommandBySelector:commandSelector];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector
{
    (void)control;
    (void)textView;

    if (commandSelector == @selector(selectAll:)) {
        [textView selectAll:nil];
        return YES;
    }
    if (commandSelector == @selector(copy:)) {
        [textView copy:nil];
        return YES;
    }
    if (commandSelector == @selector(paste:)) {
        [textView paste:nil];
        return YES;
    }

    if (commandSelector == @selector(moveDown:)) {
        if ([self.filteredResults count] > 0) {
            NSArray *items = [self.resultsMenu itemArray];
            NSInteger cur = [self currentHighlightedResultIndex];
            NSInteger target = -1;
            for (NSInteger ii = cur + 1; ii < (NSInteger)[items count]; ii++) {
                NSMenuItem *mi = [items objectAtIndex:ii];
                if (![mi isSeparatorItem] && [mi isEnabled]) { target = ii; break; }
            }
            if (target < 0) {
                /* Wrap around to the first enabled item. */
                for (NSInteger ii = 0; ii < (NSInteger)[items count]; ii++) {
                    NSMenuItem *mi = [items objectAtIndex:ii];
                    if (![mi isSeparatorItem] && [mi isEnabled]) { target = ii; break; }
                }
            }
            [self showResultsMenuWithHighlight:target];
            return YES;
        }
        return NO;
    }

    if (commandSelector == @selector(moveUp:)) {
        if ([self.filteredResults count] > 0) {
            NSArray *items = [self.resultsMenu itemArray];
            NSInteger cur = [self currentHighlightedResultIndex];
            NSInteger target = -1;
            for (NSInteger ii = cur - 1; ii >= 0; ii--) {
                NSMenuItem *mi = [items objectAtIndex:ii];
                if (![mi isSeparatorItem] && [mi isEnabled]) { target = ii; break; }
            }
            if (target < 0) {
                /* Wrap around to the last enabled item. */
                for (NSInteger ii = (NSInteger)[items count] - 1; ii >= 0; ii--) {
                    NSMenuItem *mi = [items objectAtIndex:ii];
                    if (![mi isSeparatorItem] && [mi isEnabled]) { target = ii; break; }
                }
            }
            [self showResultsMenuWithHighlight:target];
            return YES;
        }
        return NO;
    }

    if (commandSelector == @selector(cancelOperation:)) {
        [self.searchField setStringValue:@""];
        [self hideSearchPopup];

        [NSApp hide:nil];

        return YES;
    }

    /* Enter executes the highlighted result (or the first result when none is
       highlighted).  The results menu is shown with popUpMenuPositioningItem:
       which under this theme does not run a modal tracking loop, so the Return
       key is delivered to the search field instead of the menu - handle it
       here, mirroring what selecting a result row would do. */
    if (commandSelector == @selector(insertNewline:)
        || commandSelector == @selector(insertNewlineIgnoringFieldEditor:)) {
        [self executeHighlightedResult];
        return YES;
    }

    return NO;
}

/* Fired when the user presses Return in the search field.  NSTextField ends
   editing on Return and sends the field's action (see setAction: in
   createSearchPanel:); this handler launches the highlighted (or first)
   result, exactly like clicking a result row would. */
- (void)searchFieldSubmit:(id)sender
{
    (void)sender;
    /* The field action is also sent when the field editor ends editing - e.g.
       whenever the results menu is shown while typing - so only act on a real
       Return/Enter key press, not on the editing-end that the popup display
       triggers for every typed character. */
    NSEvent *currentEvent = [NSApp currentEvent];
    if (!currentEvent || [currentEvent type] != NSKeyDown) {
        return;
    }
    NSString *chars = [currentEvent characters];
    if ([chars length] != 1 ||
        ([chars characterAtIndex:0] != '\r' && [chars characterAtIndex:0] != '\n' && [chars characterAtIndex:0] != 3)) {
        return;
    }
    [self executeHighlightedResult];
}

/* Current highlighted index in the results menu, or -1 when none. */
- (NSInteger)currentHighlightedResultIndex
{
    id menuRep = [self.resultsMenu menuRepresentation];
    if ([menuRep respondsToSelector:@selector(highlightedItemIndex)]) {
        return (NSInteger)[menuRep highlightedItemIndex];
    }
    return -1;
}

- (void)executeHighlightedResult
{
    NSMenuItem *item = nil;
    id menuRep = [self.resultsMenu menuRepresentation];
    NSInteger highlightedIndex = -1;
    if ([menuRep respondsToSelector:@selector(highlightedItemIndex)]) {
        highlightedIndex = (NSInteger)[menuRep highlightedItemIndex];
    }
    if (highlightedIndex >= 0) {
        item = [self.resultsMenu itemAtIndex:highlightedIndex];
        if ([item isSeparatorItem] || ![item isEnabled]) item = nil;
    }
    if (!item) {
        NSArray *items = [self.resultsMenu itemArray];
        for (NSMenuItem *mi in items) {
            if (![mi isSeparatorItem] && [mi isEnabled]) { item = mi; break; }
        }
    }
    if (item) {
        [self resultMenuItemClicked:item];
    }
}

@end


#pragma mark - ActionSearchMenuView

@implementation ActionSearchMenuView

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
    }
    return self;
}

- (void)setAppMenuWidget:(AppMenuWidget *)widget
{
    _appMenuWidget = widget;
    [[ActionSearchController sharedController] setAppMenuWidget:widget];
}

- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;

    NSString *searchIcon = @"\U0001F50D";
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11],
        NSForegroundColorAttributeName: [NSColor darkGrayColor]
    };

    NSSize iconSize = [searchIcon sizeWithAttributes:attrs];
    NSPoint iconPoint = NSMakePoint((self.bounds.size.width - iconSize.width) / 2,
                                    (self.bounds.size.height - iconSize.height) / 2);
    [searchIcon drawAtPoint:iconPoint withAttributes:attrs];
}

- (void)mouseDown:(NSEvent *)event
{
    (void)event;

    NSPoint locationInView = [self convertPoint:[event locationInWindow] fromView:nil];
    NSPoint screenLocation = [[self window] convertBaseToScreen:
        [self convertPoint:locationInView toView:nil]];

    [[ActionSearchController sharedController] toggleSearchPopupAtPoint:screenLocation];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    (void)event;
    return YES;
}

@end

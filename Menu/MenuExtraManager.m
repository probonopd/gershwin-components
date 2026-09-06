/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MenuExtraManager.h"
#import "GSMenuExtra.h"
#import "GSMenuExtraContext.h"
#import "GSMenuExtraBundle.h"
#import "GSMenuExtraInstance.h"
#import "MenuExtrasPrefPanel.h"
#import <dispatch/dispatch.h>
#import <AppKit/NSMenuView.h>
#import <GNUstepGUI/GSTheme.h>
#import "TintedMenuItemCell.h"
#import <sys/stat.h>
#if defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__)
#import <sys/sysctl.h>
#endif
#if defined(__linux__)
#import <dirent.h>
#endif




static char kExtrasMenuViewTag;
static char kWidthIndexKey;
static char kExtrasSubmenuIdentifierKey;

#pragma mark - GSTheme hook (horizontal menus only, never vertical dropdowns)

@interface GSTheme (FixedWidthExtras)
@end

static NSMutableDictionary<NSString *, GSMenuExtraInstance *> *GSMenuExtraInstanceDictionary = nil;

@implementation GSTheme (FixedWidthExtras)

- (CGFloat)proposedTitleWidth:(CGFloat)proposedWidth forMenuView:(NSMenuView *)aMenuView
{
    if (!objc_getAssociatedObject(aMenuView, &kExtrasMenuViewTag)) {
        return proposedWidth;
    }

    NSNumber *idx = objc_getAssociatedObject(aMenuView, &kWidthIndexKey);
    NSUInteger index = [idx unsignedIntegerValue];
    NSMenu *menu = [aMenuView menu];
    NSArray *items = [menu itemArray];
    if (index >= [items count]) {
        index = 0;
        objc_setAssociatedObject(aMenuView, &kWidthIndexKey, @1, OBJC_ASSOCIATION_RETAIN);
    } else {
        objc_setAssociatedObject(aMenuView, &kWidthIndexKey, @(index + 1), OBJC_ASSOCIATION_RETAIN);
    }

    NSMenuItem *item = [items objectAtIndex:index];
    NSString *ident = [item representedObject];
    CGFloat result = proposedWidth;
    if (ident && GSMenuExtraInstanceDictionary) {
        GSMenuExtraInstance *inst = [GSMenuExtraInstanceDictionary objectForKey:ident];
        if (inst) {
            @try {
                result = [inst width];
            } @catch (NSException *e) {
                NSLog(@"GSMenuExtra: exception in proposedTitleWidth for %@: %@", ident, e);
            }
        }
    }
    return result;
}

@end

#pragma mark - MenuExtraManager

static NSString *const GSMenuExtraEnabledKey = @"GSMenuExtraEnabled";
static NSString *const GSMenuExtraOrderKey = @"GSMenuExtraOrder";

@interface MenuExtraManager ()
{
    MenuExtrasPrefPanel *_prefPanel;
    NSMutableDictionary<NSString *, GSMenuExtraInstance *> *_instances;
    dispatch_source_t _fsMonitorSource;
    NSMutableSet<NSString *> *_knownBundlePaths;
    NSMenu *_extrasMenu;
    NSMenuView *_extrasMenuView;
    NSMutableDictionary *_extrasMenuItems;
    NSMutableArray<GSMenuExtraInstance *> *_allExtras;
    NSConnection *_doConnection;
    BOOL _needsUpdateGuard;
    BOOL _needsReload;
    NSTimer *_reloadTimer;
    NSArray *_pendingIdentifiers;
}
@end

@implementation MenuExtraManager

- (instancetype)initWithScreenWidth:(CGFloat)width
                      menuBarHeight:(CGFloat)height
{
    self = [super init];
    if (self) {
        _screenWidth = width;
        _menuBarHeight = height;
        _menuExtras = [NSMutableArray array];
        _allExtras = [NSMutableArray array];
        _extrasMenuItems = [NSMutableDictionary dictionary];
        _instances = [NSMutableDictionary dictionary];
        GSMenuExtraInstanceDictionary = [NSMutableDictionary dictionary];
        _knownBundlePaths = [NSMutableSet set];
    }
    return self;
}

- (void)dealloc
{
    [self unloadAllMenuExtras];
}

#pragma mark - Bundle discovery

+ (NSArray<NSString *> *)searchPaths
{
    static NSArray *paths = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *result = [NSMutableArray array];

        [result addObject:[[[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"MenuExtras"]];

        NSSearchPathDomainMask domains[] = {
            NSSystemDomainMask,
            NSLocalDomainMask,
            NSUserDomainMask
        };
        for (int i = 0; i < 3; i++) {
            NSString *libDir = [NSSearchPathForDirectoriesInDomains(
                NSLibraryDirectory, domains[i], YES) firstObject];
            if (libDir) {
                [result addObject:[libDir stringByAppendingPathComponent:@"MenuExtras"]];
            }
        }

        paths = [result copy];
    });
    return paths;
}

- (void)collectBundlesInDirectory:(NSString *)dirPath
                           result:(NSMutableDictionary *)bundlesById
{
    [self collectBundlesInDirectory:dirPath result:bundlesById depth:0];
}

- (void)collectBundlesInDirectory:(NSString *)dirPath
                           result:(NSMutableDictionary *)bundlesById
                            depth:(NSUInteger)depth
{
    /* Cap recursion: a symlink loop in a MenuExtras search directory (or
       simply a pathologically deep tree) would otherwise recurse until the
       stack overflows and kills the process. */
    if (depth > 5) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *contents = [fm contentsOfDirectoryAtPath:dirPath error:&error];
    if (error || !contents) return;

    for (NSString *item in contents) {
        NSString *fullPath = [dirPath stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || !isDir) continue;

        NSString *ext = [[fullPath pathExtension] lowercaseString];
        if ([ext isEqualToString:@"bundle"] || [ext isEqualToString:@"gsmenuextra"]) {
            GSMenuExtraBundle *bundle = [[GSMenuExtraBundle alloc] initWithURL:[NSURL fileURLWithPath:fullPath]];
            NSString *ident = [bundle identifier];
            GSMenuExtraBundle *existing = [bundlesById objectForKey:ident];
            if (!existing) {
                [bundlesById setObject:bundle forKey:ident];
                [_knownBundlePaths addObject:fullPath];
                NSLog(@"GSMenuExtra: discovered %@ at %@", ident, fullPath);
            }
        } else {
            [self collectBundlesInDirectory:fullPath result:bundlesById depth:depth + 1];
        }
    }
}

- (NSArray<GSMenuExtraBundle *> *)discoverBundles
{
    NSMutableDictionary *bundlesById = [NSMutableDictionary dictionary];

    for (NSString *searchPath in [[self class] searchPaths]) {
        [self collectBundlesInDirectory:searchPath result:bundlesById];
    }

    NSLog(@"GSMenuExtra: discovered %lu bundles total", (unsigned long)[bundlesById count]);
    return [bundlesById allValues];
}

#pragma mark - Bundle loading

- (GSMenuExtraInstance *)loadInstanceFromBundle:(GSMenuExtraBundle *)bundle
{
    NSBundle *nsBundle = [bundle bundle];

    @try {
        if (![nsBundle isLoaded]) {
            if (![nsBundle load]) {
                NSLog(@"GSMenuExtra: failed to load bundle %@", [bundle identifier]);
                return nil;
            }
        }

        Class principalClass = [nsBundle principalClass];
        if (!principalClass) return nil;

        if (![principalClass conformsToProtocol:@protocol(GSMenuExtra)]) {
            NSLog(@"GSMenuExtra: principal class %@ does not conform to GSMenuExtra", NSStringFromClass(principalClass));
            return nil;
        }

        id<GSMenuExtra> extra = [[principalClass alloc] init];
        if (!extra) return nil;

        // Check system compatibility before loading.
        // Non-compatible extras are silently skipped — they won't appear
        // in the menu bar or the preferences panel.
        if ([extra respondsToSelector:@selector(isCompatibleWithSystem)]
            && ![extra isCompatibleWithSystem]) {
            NSLog(@"GSMenuExtra: %@ is not compatible with this system, skipping",
                  [bundle identifier]);
            return nil;
        }

        GSMenuExtraInstance *instance = [[GSMenuExtraInstance alloc] initWithExtra:extra
                                                                          identifier:[bundle identifier]
                                                                         displayName:[bundle displayName]
                                                                          priority:[bundle priority]
                                                                          manager:self];

        return instance;
    } @catch (NSException *exception) {
        NSLog(@"GSMenuExtra: exception loading bundle %@: %@", [bundle identifier], exception);
        return nil;
    }
}

#pragma mark - Main loading

- (void)loadMenuExtras
{
    NSMutableArray *allInstances = [NSMutableArray array];

    NSArray *bundles = [self discoverBundles];

    for (GSMenuExtraBundle *bundle in bundles) {
        NSString *ident = [bundle identifier];

        if ([_instances objectForKey:ident]) continue;

        NSLog(@"GSMenuExtra: loading bundle %@", ident);
        GSMenuExtraInstance *instance = [self loadInstanceFromBundle:bundle];
        if (instance) {
            [_instances setObject:instance forKey:ident];
            [GSMenuExtraInstanceDictionary setObject:instance forKey:ident];

            [allInstances addObject:instance];
            NSLog(@"GSMenuExtra: loaded bundle %@", ident);
        } else {
            NSLog(@"GSMenuExtra: FAILED to load bundle %@", ident);
        }
    }

    NSSet *enabledSet = [self loadEnabledPreference];

    NSArray *savedOrder = [self loadOrderPreference];
    NSMutableArray *orderedAll = [NSMutableArray arrayWithCapacity:[allInstances count]];

    NSMutableDictionary *instancesById = [NSMutableDictionary dictionary];
    for (GSMenuExtraInstance *inst in allInstances) {
        [instancesById setObject:inst forKey:[inst identifier]];
    }

    for (NSString *ident in savedOrder) {
        GSMenuExtraInstance *inst = [instancesById objectForKey:ident];
        if (inst) {
            [orderedAll addObject:inst];
            [instancesById removeObjectForKey:ident];
        }
    }

    for (GSMenuExtraInstance *inst in allInstances) {
        if ([instancesById objectForKey:[inst identifier]]) {
            [orderedAll addObject:inst];
        }
    }

    NSComparisonResult (^instanceComparator)(GSMenuExtraInstance *, GSMenuExtraInstance *) =
        ^NSComparisonResult(GSMenuExtraInstance *a, GSMenuExtraInstance *b) {
            NSInteger pa = [a displayPriority];
            NSInteger pb = [b displayPriority];
            if (pa < pb) return NSOrderedAscending;
            if (pa > pb) return NSOrderedDescending;
            return NSOrderedSame;
        };

    _allExtras = orderedAll;
    [_allExtras sortUsingComparator:instanceComparator];
    _menuExtras = [NSMutableArray array];

    [self applyEnabledSet:enabledSet];

    // Load enabled extras (calls menuExtraDidLoad wrapped in @try/@catch).
    for (GSMenuExtraInstance *inst in _menuExtras) {
        [inst load];
    }

    [self setupDOServer];
    [self startFileSystemMonitoring];
}

- (NSArray<GSMenuExtraInstance *> *)allMenuExtras
{
    return _allExtras;
}

- (void)reloadEnabledFromDefaults
{
    NSLog(@"GSMenuExtra: reloadEnabledFromDefaults called, _allExtras=%@",
          _allExtras ? @"non-nil" : @"nil");
    if (!_allExtras) return;

    NSSet *enabledSet = [self loadEnabledPreference];
    NSLog(@"GSMenuExtra: enabledSet=%@", enabledSet ?: @"nil (show all)");
    [self applyEnabledSet:enabledSet];
}

- (void)setupDOServer
{
    _doConnection = [[NSConnection alloc] init];
    [_doConnection setRootObject:self];
    if ([_doConnection registerName:@"io.github.gershwin-desktop.MenuExtraConfigServer"]) {
        NSLog(@"GSMenuExtra: DO server registered for config changes");
    }
}

- (BOOL)updateEnabledExtras:(NSArray *)identifiers
{
    NSLog(@"GSMenuExtra: DO received %lu identifiers", (unsigned long)[identifiers count]);
    _pendingIdentifiers = [NSArray arrayWithArray:identifiers];
    _needsReload = YES;

    if (!_reloadTimer) {
        _reloadTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                        target:self
                                                      selector:@selector(reloadTimerFired:)
                                                      userInfo:nil
                                                       repeats:NO];
    }
    NSLog(@"GSMenuExtra: DO method returning YES");
    return YES;
}

- (void)reloadTimerFired:(NSTimer *)timer
{
    if (!_needsReload || !_pendingIdentifiers || !_allExtras || [_allExtras count] == 0) {
        _needsReload = NO;
        _pendingIdentifiers = nil;
        [_reloadTimer invalidate];
        _reloadTimer = nil;
        return;
    }

    _needsReload = NO;
    NSArray *pending = _pendingIdentifiers;
    _pendingIdentifiers = nil;
    [_reloadTimer invalidate];
    _reloadTimer = nil;

    for (id obj in pending) {
        if (![obj isKindOfClass:[NSString class]]) {
            NSLog(@"GSMenuExtra: reloadTimerFired — BAD identifier type: %@", [obj class]);
            return;
        }
    }

    [[NSUserDefaults standardUserDefaults] setObject:pending forKey:GSMenuExtraEnabledKey];
    [[NSUserDefaults standardUserDefaults] setObject:pending forKey:GSMenuExtraOrderKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    NSSet *enabledSet = [NSSet setWithArray:pending];
    [self applyEnabledSet:enabledSet];
}



- (void)rebuildExtrasMenu
{
    NSLog(@"GSMenuExtra: rebuildExtrasMenu start, extras=%lu, menuItems=%lu",
          (unsigned long)[_menuExtras count], (unsigned long)[_extrasMenuItems count]);

    if (!_extrasMenu) {
        _extrasMenu = [[NSMenu alloc] initWithTitle:@"Extras"];
        NSLog(@"GSMenuExtra: created new _extrasMenu");
    }

    /* Remove items no longer wanted */
    NSMutableArray *identsToRemove = [NSMutableArray array];
    for (NSString *ident in _extrasMenuItems) {
        BOOL found = NO;
        for (GSMenuExtraInstance * p in _menuExtras) {
            if ([[p identifier] isEqualToString:ident]) {
                found = YES;
                break;
            }
        }
        if (!found) {
            [identsToRemove addObject:ident];
        }
    }
    NSLog(@"GSMenuExtra: removing %lu items", (unsigned long)[identsToRemove count]);
    for (NSString *ident in identsToRemove) {
        NSMenuItem *item = [_extrasMenuItems objectForKey:ident];
        NSInteger idx = [_extrasMenu indexOfItem:item];
        if (idx >= 0) {
            [_extrasMenu removeItemAtIndex:idx];
        }
        [_extrasMenuItems removeObjectForKey:ident];
    }

    /* Add items that are new */
    NSLog(@"GSMenuExtra: adding new items");
    for (GSMenuExtraInstance * provider in _menuExtras) {
        NSString *ident = [provider identifier];
        if ([_extrasMenuItems objectForKey:ident]) continue;
        NSLog(@"GSMenuExtra:   adding item %@", ident);

        NSString *title = [provider title] ? [provider title] : ident;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                       action:NULL
                                                keyEquivalent:@""];
        NSLog(@"GSMenuExtra:   created item");
        if ([provider respondsToSelector:@selector(icon)]) {
            NSImage *icon = [provider icon];
            if (icon) {
                CGFloat iconSize = _menuBarHeight - 4.0;
                [icon setSize:NSMakeSize(iconSize, iconSize)];
                [item setImage:icon];
            }
        }
        NSLog(@"GSMenuExtra:   set icon");
        if ([provider respondsToSelector:@selector(menu)]) {
            NSMenu *submenu = [provider menu];
            if (submenu) {
                [self configureSubmenu:submenu forIdentifier:ident];
                [item setSubmenu:submenu];
            }
        }
        NSLog(@"GSMenuExtra:   set submenu");
        [item setRepresentedObject:ident];

        NSInteger insertIdx = [_extrasMenu numberOfItems];
        for (NSUInteger i = 0; i < [_menuExtras count]; i++) {
            if ([[_menuExtras[i] identifier] isEqualToString:ident]) {
                for (NSUInteger j = 0; j < (NSUInteger)[_extrasMenu numberOfItems]; j++) {
                    NSMenuItem *existing = [_extrasMenu itemAtIndex:j];
                    NSString *eid = [existing representedObject];
                    for (GSMenuExtraInstance * ep in _menuExtras) {
                        if ([[ep identifier] isEqualToString:eid]) {
                            NSInteger pa = 100, pb = 100;
                            if ([provider respondsToSelector:@selector(displayPriority)])
                                pa = [provider displayPriority];
                            if ([ep respondsToSelector:@selector(displayPriority)])
                                pb = [ep displayPriority];
                            if (pa > pb) {
                                insertIdx = j;
                            }
                            break;
                        }
                    }
                }
                break;
            }
        }
        NSLog(@"GSMenuExtra:   inserting at %ld", (long)insertIdx);
        [_extrasMenu insertItem:item atIndex:insertIdx];
        NSLog(@"GSMenuExtra:   inserted OK");
        [_extrasMenuItems setObject:item forKey:ident];
    }

    /* Update view */
    NSLog(@"GSMenuExtra: updating view");
    if (!_extrasMenuView) {
        _extrasMenuView = [[NSMenuView alloc] initWithFrame:NSMakeRect(0, 0, 0, _menuBarHeight)];
        [_extrasMenuView setHorizontal:YES];
        objc_setAssociatedObject(_extrasMenuView, &kExtrasMenuViewTag, @YES, OBJC_ASSOCIATION_RETAIN);
        [_extrasMenuView setMenu:_extrasMenu];
    } else {
        [_extrasMenuView setMenu:_extrasMenu];
    }
    NSLog(@"GSMenuExtra: view menu set");

    objc_setAssociatedObject(_extrasMenuView, &kWidthIndexKey, @0, OBJC_ASSOCIATION_RETAIN);
    [_extrasMenuView sizeToFit];
    CGFloat width = [self extrasMenuWidth];
    NSLog(@"GSMenuExtra: width=%g", width);

    NSView *superview = [_extrasMenuView superview];
    if (superview) {
        CGFloat menuBarW = NSWidth([superview bounds]);
        [_extrasMenuView setFrame:NSMakeRect(menuBarW - width - 8, 0, width, _menuBarHeight)];
        [superview setNeedsDisplay:YES];
    } else {
        [_extrasMenuView setFrameSize:NSMakeSize(width, _menuBarHeight)];
    }
    NSLog(@"GSMenuExtra: rebuildExtrasMenu done");
}

- (void)applyEnabledSet:(NSSet *)enabledSet
{
    if (!_allExtras || [_allExtras count] == 0) return;

    NSMutableArray *newEnabled = [NSMutableArray array];
    for (GSMenuExtraInstance * p in _allExtras) {
        if (!enabledSet || [enabledSet containsObject:[p identifier]]) {
            [newEnabled addObject:p];
        }
    }

    if (enabledSet && [enabledSet count] > 0 && [newEnabled count] == 0 && [_allExtras count] > 0) {
        NSLog(@"GSMenuExtra: enabledSet contains NO matching extras (%lu identifiers, %lu loaded) — ignoring",
              (unsigned long)[enabledSet count], (unsigned long)[_allExtras count]);
        newEnabled = [NSMutableArray arrayWithArray:_allExtras];
    }

    NSLog(@"GSMenuExtra: applyEnabledSet: %lu extras enabled out of %lu total",
          (unsigned long)[newEnabled count], (unsigned long)[_allExtras count]);

    [newEnabled sortUsingComparator:^NSComparisonResult(GSMenuExtraInstance * a, GSMenuExtraInstance * b) {
        NSInteger pa = 100, pb = 100;
        if ([a respondsToSelector:@selector(displayPriority)]) pa = [a displayPriority];
        if ([b respondsToSelector:@selector(displayPriority)]) pb = [b displayPriority];
        if (pa < pb) return NSOrderedAscending;
        if (pa > pb) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    BOOL changed = ([_menuExtras count] != [newEnabled count]);
    if (!changed) {
        for (NSUInteger i = 0; i < [_menuExtras count]; i++) {
            if (![[_menuExtras[i] identifier] isEqualToString:[newEnabled[i] identifier]]) {
                changed = YES;
                break;
            }
        }
    }
    if (!changed) return;

    // On subsequent calls (toggles), stop disabled extras and start re-enabled ones.
    if ([_menuExtras count] > 0) {
        for (GSMenuExtraInstance *inst in _allExtras) {
            if (![newEnabled containsObject:inst]) {
                @try {
                    [inst unload];
                } @catch (NSException *e) {
                    NSLog(@"GSMenuExtra: exception in unload for %@: %@", [inst identifier], e);
                }
            }
        }
        for (GSMenuExtraInstance *inst in newEnabled) {
            BOOL wasEnabled = NO;
            for (GSMenuExtraInstance *oi in _menuExtras) {
                if ([[oi identifier] isEqualToString:[inst identifier]]) {
                    wasEnabled = YES;
                    break;
                }
            }
            if (!wasEnabled) {
                [inst load];
            }
        }
    }

    _menuExtras = newEnabled;

    if (!_extrasMenu) {
        _extrasMenu = [[NSMenu alloc] initWithTitle:@"Extras"];
    }

    // Detach submenus before removing items to prevent "already has supermenu" exceptions
    // when reusing the same submenu object on a new item (CPU/RAM cache their menu objects).
    for (NSMenuItem *existingItem in [_extrasMenu itemArray]) {
        if ([existingItem hasSubmenu]) {
            [existingItem setSubmenu:nil];
        }
    }
    [_extrasMenu removeAllItems];
    [_extrasMenuItems removeAllObjects];

    for (GSMenuExtraInstance * provider in _menuExtras) {
        NSString *ident = [provider identifier];
        NSString *title = ident;
        @try {
            title = [provider title] ?: ident;
        } @catch (NSException *e) {
            NSLog(@"GSMenuExtra: exception in title for %@: %@", ident, e);
        }
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                       action:NULL
                                                keyEquivalent:@""];
        if ([provider respondsToSelector:@selector(icon)]) {
            @try {
                NSImage *icon = [provider icon];
                if (icon) {
                    CGFloat iconSize = _menuBarHeight - 4.0;
                    [icon setSize:NSMakeSize(iconSize, iconSize)];
                    [item setImage:icon];
                }
            } @catch (NSException *e) {
                NSLog(@"GSMenuExtra: exception in icon for %@: %@", ident, e);
            }
        }
        if ([provider respondsToSelector:@selector(menu)]) {
            NSMenu *submenu = nil;
            @try {
                submenu = [provider menu];
            } @catch (NSException *e) {
                NSLog(@"GSMenuExtra: exception in menu for %@: %@", ident, e);
            }
            if (submenu) {
                [item setSubmenu:submenu];
            }
        }
        [item setRepresentedObject:ident];
        [_extrasMenu addItem:item];
        [_extrasMenuItems setObject:item forKey:ident];
    }

    if (_extrasMenuView) {
        [_extrasMenuView setFrameSize:NSMakeSize(0, _menuBarHeight)];
        [_extrasMenuView sizeToFit];
        CGFloat width = [self extrasMenuWidth];
        NSView *superview = [_extrasMenuView superview];
        if (superview) {
            CGFloat menuBarW = NSWidth([superview bounds]);
            [_extrasMenuView setFrame:NSMakeRect(menuBarW - width - 8, 0, width, _menuBarHeight)];
            [superview setNeedsDisplay:YES];
        } else {
            [_extrasMenuView setFrameSize:NSMakeSize(width, _menuBarHeight)];
        }
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"GSMenuExtraEnabledSetDidChange"
                                                        object:self];

    NSLog(@"GSMenuExtra: applied enabled set, %lu items active",
          (unsigned long)[_menuExtras count]);
}

- (void)unloadAllMenuExtras
{
    [self stopUpdateTimers];

    _needsReload = NO;
    _pendingIdentifiers = nil;
    [_reloadTimer invalidate];
    _reloadTimer = nil;

    if (_doConnection) {
        [_doConnection invalidate];
        _doConnection = nil;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if (_fsMonitorSource) {
        dispatch_source_cancel(_fsMonitorSource);
        _fsMonitorSource = nil;
    }

    [self savePreferences];

    for (GSMenuExtraInstance * item in _menuExtras) {
        @try {
            if ([item respondsToSelector:@selector(unload)]) [item unload];
        } @catch (NSException *exception) {}
    }

    [_extrasMenuItems removeAllObjects];
    _extrasMenu = nil;
    _extrasMenuView = nil;
    [_menuExtras removeAllObjects];
    [_instances removeAllObjects];
    [GSMenuExtraInstanceDictionary removeAllObjects];
}

- (GSMenuExtraInstance *)providerForIdentifier:(NSString *)identifier
{
    if (!identifier) return nil;

    for (GSMenuExtraInstance * provider in _allExtras) {
        if ([[provider identifier] isEqualToString:identifier]) {
            return provider;
        }
    }
    return nil;
}

- (void)configureSubmenu:(NSMenu *)submenu forIdentifier:(NSString *)identifier
{
    if (!submenu || !identifier) return;

    objc_setAssociatedObject(submenu, &kExtrasSubmenuIdentifierKey, identifier, OBJC_ASSOCIATION_RETAIN);
    [submenu setDelegate:(id<NSMenuDelegate>)self];
    [submenu setAutoenablesItems:NO];

    if ([submenu numberOfItems] > 0
        && [[submenu itemAtIndex:[submenu numberOfItems] - 1] action] != @selector(showPreferencesPanel)) {
        [submenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *prefsItem = [[NSMenuItem alloc] initWithTitle:@"Customize..."
                                                           action:@selector(showPreferencesPanel)
                                                    keyEquivalent:@""];
        [prefsItem setTarget:self];
        [submenu addItem:prefsItem];
    }
}

- (void)replaceMenu:(NSMenu *)target withMenu:(NSMenu *)source
{
    if (!target || !source || target == source) return;

    while ([target numberOfItems] > 0) {
        [target removeItemAtIndex:0];
    }
    while ([source numberOfItems] > 0) {
        NSMenuItem *item = [source itemAtIndex:0];
        [source removeItemAtIndex:0];
        [target addItem:item];
    }
}

#pragma mark - View creation

- (NSView *)createExtrasMenuView
{
    _extrasMenu = [[NSMenu alloc] initWithTitle:@"Extras"];

    for (GSMenuExtraInstance * provider in _menuExtras) {
        NSString *ident = [provider identifier];
        NSString *title = [provider title] ? [provider title] : ident;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                       action:NULL
                                                keyEquivalent:@""];
        if ([provider respondsToSelector:@selector(icon)]) {
            NSImage *icon = [provider icon];
            if (icon) {
                CGFloat iconSize = _menuBarHeight - 4.0;
                [icon setSize:NSMakeSize(iconSize, iconSize)];
                [item setImage:icon];
            }
        }
        if ([provider respondsToSelector:@selector(menu)]) {
            NSMenu *submenu = [provider menu];
            if (submenu) {
                [self configureSubmenu:submenu forIdentifier:ident];
                [item setSubmenu:submenu];
            }
        }
        [item setRepresentedObject:ident];
        [_extrasMenu addItem:item];
        [_extrasMenuItems setObject:item forKey:ident];
    }
    _extrasMenuView = [[NSMenuView alloc] initWithFrame:NSMakeRect(0, 0, 0, _menuBarHeight)];
    [_extrasMenuView setHorizontal:YES];
    objc_setAssociatedObject(_extrasMenuView, &kExtrasMenuViewTag, @YES, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(_extrasMenuView, &kWidthIndexKey, @0, OBJC_ASSOCIATION_RETAIN);
    [_extrasMenuView setMenu:_extrasMenu];

    CGFloat width = [self extrasMenuWidth];
    [_extrasMenuView setFrameSize:NSMakeSize(width, _menuBarHeight)];

    return _extrasMenuView;
}

- (CGFloat)extrasMenuWidthForView:(NSMenuView *)view menu:(NSMenu *)menu
{
    if (!view || !menu || [[menu itemArray] count] == 0) return 0;

    objc_setAssociatedObject(view, &kWidthIndexKey, @0, OBJC_ASSOCIATION_RETAIN);
    [view sizeToFit];

    __block CGFloat maxX = 0;
    [[menu itemArray] enumerateObjectsUsingBlock:
        ^(NSMenuItem *item, NSUInteger idx, BOOL *stop) {
            NSRect r = [view rectOfItemAtIndex: idx];
            CGFloat right = NSMaxX(r);
            if (right > maxX) maxX = right;
        }];

    return maxX;
}

- (CGFloat)extrasMenuWidth
{
    return [self extrasMenuWidthForView:_extrasMenuView menu:_extrasMenu];
}

#pragma mark - Update timers

- (void)startUpdateTimers
{
    _updateTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                    target:self
                                                  selector:@selector(updateTimerFired:)
                                                  userInfo:[_menuExtras copy]
                                                   repeats:YES];
    [self updateTimerFired:_updateTimer];
}

- (void)updateTimerFired:(NSTimer *)timer
{
    @try {
        objc_setAssociatedObject(_extrasMenuView, &kWidthIndexKey, @0, OBJC_ASSOCIATION_RETAIN);
        NSArray *items = [timer userInfo];
        for (GSMenuExtraInstance * item in items) {
            @try {
                [item tick];
                NSString *title = [item title];
                if (!title) {
                    title = [NSString stringWithFormat:@"[%@]", [item identifier]];
                }
                NSMenuItem *menuItem = [_extrasMenuItems objectForKey:[item identifier]];
                if (menuItem) [menuItem setTitle:title];
            } @catch (NSException *e) {
                NSLog(@"GSMenuExtra: exception updating item %@: %@", [item identifier], e);
            }
        }
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtra: exception in updateTimerFired: %@", e);
    }
}

- (void)stopUpdateTimers
{
    [_updateTimer invalidate];
    _updateTimer = nil;
}

#pragma mark - Presentation invalidation

- (void)refreshExtraWithIdentifier:(NSString *)identifier
{
    NSMenuItem *menuItem = [_extrasMenuItems objectForKey:identifier];
    if (!menuItem) return;

    for (GSMenuExtraInstance * provider in _menuExtras) {
        if ([[provider identifier] isEqualToString:identifier]) {
            @try {
                NSString *title = [provider title];
                if (title) [menuItem setTitle:title];

                if ([provider respondsToSelector:@selector(icon)]) {
                    NSImage *icon = [provider icon];
                    if (icon) {
                        CGFloat iconSize = _menuBarHeight - 4.0;
                        [icon setSize:NSMakeSize(iconSize, iconSize)];
                        [menuItem setImage:icon];
                    } else {
                        [menuItem setImage:nil];
                    }
                    if (_extrasMenuView) {
                        [_extrasMenuView performSelector:@selector(display)
                                             withObject:nil
                                             afterDelay:0];
                    }
                }
                if ([provider respondsToSelector:@selector(menu)]) {
                    if ([provider respondsToSelector:@selector(menuWillOpen)]) {
                        [provider menuWillOpen];
                    }
                    NSMenu *freshSubmenu = [provider menu];
                    if (freshSubmenu) {
                        NSMenu *existingSubmenu = [menuItem submenu];
                        if (existingSubmenu) {
                            [self configureSubmenu:existingSubmenu forIdentifier:identifier];
                            [self replaceMenu:existingSubmenu withMenu:freshSubmenu];
                        } else {
                            [self configureSubmenu:freshSubmenu forIdentifier:identifier];
                            [menuItem setSubmenu:freshSubmenu];
                        }
                    }
                }
            } @catch (NSException *e) {
                NSLog(@"GSMenuExtra: exception refreshing %@: %@", identifier, e);
            }
            break;
        }
    }
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    if (_needsUpdateGuard) return;
    _needsUpdateGuard = YES;

    NSString *identifier = objc_getAssociatedObject(menu, &kExtrasSubmenuIdentifierKey);
    GSMenuExtraInstance * provider = [self providerForIdentifier:identifier];
    if (!provider) { _needsUpdateGuard = NO; return; }

    @try {
        if ([provider respondsToSelector:@selector(menuWillOpen)]) {
            [provider menuWillOpen];
        }
        if ([provider respondsToSelector:@selector(menu)]) {
            NSMenu *freshMenu = [provider menu];
            if (freshMenu && freshMenu != menu) {
                [self replaceMenu:menu withMenu:freshMenu];
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"MenuExtraManager: exception in menuNeedsUpdate for %@: %@", identifier, exception);
    }

    _needsUpdateGuard = NO;
}

- (void)menuWillOpen:(NSMenu *)menu
{
    [self menuNeedsUpdate:menu];
}

- (void)menuDidClose:(NSMenu *)menu
{
    NSString *identifier = objc_getAssociatedObject(menu, &kExtrasSubmenuIdentifierKey);
    GSMenuExtraInstance * provider = [self providerForIdentifier:identifier];
    if ([provider respondsToSelector:@selector(menuDidClose)]) {
        [provider menuDidClose];
    }
}

#pragma mark - Preferences

- (void)savePreferences
{
    NSMutableArray *order = [NSMutableArray arrayWithCapacity:[_menuExtras count]];
    for (GSMenuExtraInstance * item in _menuExtras) {
        [order addObject:[item identifier]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:order forKey:GSMenuExtraOrderKey];

    NSMutableArray *enabled = [NSMutableArray arrayWithCapacity:[_menuExtras count]];
    for (GSMenuExtraInstance * item in _menuExtras) {
        [enabled addObject:[item identifier]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:enabled forKey:GSMenuExtraEnabledKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSArray<NSString *> *)loadOrderPreference
{
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:GSMenuExtraOrderKey];
    if ([saved isKindOfClass:[NSArray class]]) return saved;
    return @[];
}

- (NSSet *)loadEnabledPreference
{
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:GSMenuExtraEnabledKey];
    if ([saved isKindOfClass:[NSArray class]]) return [NSSet setWithArray:saved];
    return nil;
}

#pragma mark - Configuration panel

- (void)showPreferencesPanel
{
    if (!_prefPanel) {
        _prefPanel = [[MenuExtrasPrefPanel alloc] initWithManager:self];
    } else {
        [_prefPanel reloadExtras];
    }
    [_prefPanel showWindow:nil];
    [[_prefPanel window] makeKeyAndOrderFront:nil];
}

#pragma mark - File system monitoring

- (void)startFileSystemMonitoring
{
#if !defined(__linux__) && !defined(__FreeBSD__) && !defined(__OpenBSD__)
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    int fd = open([[[[self class] searchPaths] firstObject] fileSystemRepresentation], O_EVTONLY);
    if (fd < 0) return;

    _fsMonitorSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME, queue);

    dispatch_source_set_event_handler(_fsMonitorSource, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self rescanBundles];
        });
    });

    dispatch_source_set_cancel_handler(_fsMonitorSource, ^{
        close(fd);
    });

    dispatch_resume(_fsMonitorSource);
#else
    /* Poll-based fallback: rescan every 10 seconds */
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:10.0
                                         target:self
                                       selector:@selector(rescanBundles)
                                       userInfo:nil
                                        repeats:YES];
    });
#endif
}

- (void)rescanBundles
{
    [self rescanBundlesNow];
}

- (void)rescanBundlesNow
{
    NSMutableSet *currentPaths = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *searchPath in [[self class] searchPaths]) {
        if (![fm fileExistsAtPath:searchPath]) continue;
        NSError *error = nil;
        NSArray *contents = [fm contentsOfDirectoryAtPath:searchPath error:&error];
        if (!contents) continue;

        for (NSString *item in contents) {
            NSString *fullPath = [searchPath stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:fullPath isDirectory:&isDir] || !isDir) continue;
            NSString *ext = [[fullPath pathExtension] lowercaseString];
            if (![ext isEqualToString:@"bundle"] && ![ext isEqualToString:@"gsmenuextra"]) continue;
            [currentPaths addObject:fullPath];
        }
    }

    NSMutableSet *added = [NSMutableSet setWithSet:currentPaths];
    [added minusSet:_knownBundlePaths];

    NSMutableSet *removed = [NSMutableSet setWithSet:_knownBundlePaths];
    [removed minusSet:currentPaths];

    for (NSString *path in removed) {
        NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
        GSMenuExtraInstance * toRemove = nil;
        for (GSMenuExtraInstance * p in _menuExtras) {
            if ([[p identifier] isEqualToString:name] || [[p identifier] isEqualToString:path]) {
                toRemove = p;
                break;
            }
        }
        if (toRemove) {
            if ([toRemove respondsToSelector:@selector(unload)]) [toRemove unload];
            [_menuExtras removeObject:toRemove];
            NSString *ident = [toRemove identifier];
            [_extrasMenuItems removeObjectForKey:ident];
            [_instances removeObjectForKey:ident];
            [GSMenuExtraInstanceDictionary removeObjectForKey:ident];
        }
        [_knownBundlePaths removeObject:path];
    }

    for (NSString *path in added) {
        NSURL *url = [NSURL fileURLWithPath:path];
        GSMenuExtraBundle *bundle = [[GSMenuExtraBundle alloc] initWithURL:url];

        NSString *ident = [bundle identifier];
        if (ident && ![_instances objectForKey:ident]) {
            GSMenuExtraInstance *instance = [self loadInstanceFromBundle:bundle];
            if (instance) {
                [_menuExtras addObject:instance];
                [_knownBundlePaths addObject:path];
                [_instances setObject:instance forKey:ident];
                [GSMenuExtraInstanceDictionary setObject:instance forKey:ident];

                [self rebuildExtrasMenu];
            }
        }
    }

    if ([added count] > 0 || [removed count] > 0) {
        [self savePreferences];
        if (_extrasMenuView) {
            CGFloat w = [self extrasMenuWidth];
            [_extrasMenuView setFrameSize:NSMakeSize(w, NSHeight([_extrasMenuView frame]))];
        }
    }
}

@end

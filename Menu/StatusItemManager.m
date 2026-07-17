/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "StatusItemManager.h"
#import "GSMenuExtra.h"
#import "GSMenuExtraContext.h"
#import "GSMenuExtraBundle.h"
#import "GSMenuExtraInstance.h"
#import "MenuExtrasPrefPanel.h"
#import <dispatch/dispatch.h>
#import <AppKit/NSMenuView.h>
#import <GNUstepGUI/GSTheme.h>
#import "TintedMenuItemCell.h"

#pragma mark - Width reference helpers

static NSString *WidthRefForIdentifier(NSString *ident, NSString *title)
{
    if ([ident rangeOfString:@"battery"].location != NSNotFound) {
        return @"99%";
    }
    if ([ident rangeOfString:@"clock"].location != NSNotFound) {
        return @"99:99:99 PM";
    }
    if ([title rangeOfString:@"%"].location != NSNotFound) {
        return @"100%";
    }
    return nil;
}

static char kExtrasMenuViewTag;
static char kWidthIndexKey;
static char kExtrasSubmenuIdentifierKey;

#pragma mark - GSTheme hook (horizontal menus only, never vertical dropdowns)

@interface GSTheme (FixedWidthExtras)
@end

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
    NSString *title = [item title];
    CGFloat result = proposedWidth;
    if ([title length] > 0) {
        NSString *widthRef = WidthRefForIdentifier(ident, title);
        if (widthRef) {
            NSFont *font = [aMenuView font] ? [aMenuView font] : [NSFont menuBarFontOfSize:0];
            NSSize size = [widthRef sizeWithAttributes:@{ NSFontAttributeName: font }];
            result = ceil(size.width);
        }
    }
    return result;
}

@end

#pragma mark - GSMenuExtraAdapter

@interface GSMenuExtraAdapter : NSObject <StatusItemProvider>
{
    id<GSMenuExtra> _extra;
    NSString *_identifier;
    CGFloat _cachedWidth;
    GSMenuExtraContext *_context;
}
@end

@implementation GSMenuExtraAdapter

- (instancetype)initWithGSMenuExtra:(id<GSMenuExtra>)extra
                         identifier:(NSString *)identifier
                             context:(GSMenuExtraContext *)context
{
    self = [super init];
    if (self) {
        _extra = extra;
        _identifier = [identifier copy];
        _context = context;
        _cachedWidth = 0;
        if ([_extra respondsToSelector:@selector(setContext:)]) {
            [(id)_extra setContext:context];
        }
    }
    return self;
}

- (NSString *)identifier { return _identifier; }

- (NSString *)title { return [_extra title]; }

- (CGFloat)width
{
    if (_cachedWidth > 0) return _cachedWidth;
    NSFont *font = [NSFont menuBarFontOfSize:0];
    NSDictionary *attrs = @{ NSFontAttributeName: font };
    NSString *display = [_extra title];
    if (!display) display = @"";
    NSString *widthRef = nil;
    if ([display length] > 0) {
        widthRef = WidthRefForIdentifier(_identifier, display);
    }
    if (!widthRef) widthRef = display;
    NSSize size = [widthRef sizeWithAttributes:attrs];
    _cachedWidth = ceil(size.width) + 16.0;
    return _cachedWidth;
}

- (void)loadWithManager:(StatusItemManager *)manager
{
    if ([_extra respondsToSelector:@selector(menuExtraDidLoad)]) {
        [_extra menuExtraDidLoad];
    }
}

- (void)update {
    _cachedWidth = 0;
    [_context invalidatePresentation];
}
- (void)handleClick {}
- (NSMenu *)menu { return [_extra menu]; }
- (void)refreshMenuItems:(NSMenu *)submenu
{
    if ([_extra respondsToSelector:@selector(refreshMenuItems:)]) {
        [(id)_extra refreshMenuItems:submenu];
    }
}
- (NSImage *)icon { return [_extra image]; }
- (NSTimeInterval)updateInterval { return 0; }

- (void)unload
{
    if ([_extra respondsToSelector:@selector(menuExtraWillUnload)]) {
        [_extra menuExtraWillUnload];
    }
    _extra = nil;
}

- (NSInteger)displayPriority
{
    static NSDictionary *priorityMap = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        priorityMap = @{
            @"org.gnustep.menuextra.clock":      @50,
            @"org.gnustep.menuextra.battery":    @40,
            @"org.gnustep.menuextra.wlan":       @30,
            @"org.gnustep.menuextra.sound":      @20,
            @"org.gnustep.menuextra.brightness": @10,
        };
    });
    NSNumber *p = [priorityMap objectForKey:_identifier];
    return p ? [p integerValue] : 0;
}

- (void)menuWillOpen
{
    if ([_extra respondsToSelector:@selector(menuExtraWillOpenMenu)]) {
        [_extra menuExtraWillOpenMenu];
    }
}

- (void)menuDidClose
{
    if ([_extra respondsToSelector:@selector(menuExtraDidCloseMenu)]) {
        [_extra menuExtraDidCloseMenu];
    }
}

@end

#pragma mark - StatusItemManager

static NSString *const GSMenuExtraEnabledKey = @"GSMenuExtraEnabled";
static NSString *const GSMenuExtraOrderKey = @"GSMenuExtraOrder";

@interface StatusItemManager ()
{
    MenuExtrasPrefPanel *_prefPanel;
    NSMutableDictionary<NSString *, GSMenuExtraInstance *> *_instances;
    dispatch_source_t _fsMonitorSource;
    NSMutableSet<NSString *> *_knownBundlePaths;
    NSMenu *_extrasMenu;
    NSMenuView *_extrasMenuView;
    NSMutableDictionary *_extrasMenuItems;
    NSMutableArray<id<StatusItemProvider>> *_allStatusItems;
    BOOL _needsUpdateGuard;
}
@end

@implementation StatusItemManager

- (instancetype)initWithScreenWidth:(CGFloat)width
                      menuBarHeight:(CGFloat)height
{
    self = [super init];
    if (self) {
        _screenWidth = width;
        _menuBarHeight = height;
        _statusItems = [NSMutableArray array];
        _allStatusItems = [NSMutableArray array];
        _updateTimers = [NSMutableDictionary dictionary];
        _extrasMenuItems = [NSMutableDictionary dictionary];
        _instances = [NSMutableDictionary dictionary];
        _knownBundlePaths = [NSMutableSet set];
    }
    return self;
}

- (void)dealloc
{
    [self unloadAllStatusItems];
}

#pragma mark - Bundle discovery

+ (NSArray<NSString *> *)searchPaths
{
    static NSArray *paths = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *result = [NSMutableArray array];

        [result addObject:[[[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"StatusItems"]];

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
                [result addObject:[libDir stringByAppendingPathComponent:@"Menu/StatusItems"]];
            }
        }

        [result addObject:[[[NSBundle mainBundle] resourcePath]
            stringByAppendingPathComponent:@"StatusItems"]];

        paths = [result copy];
    });
    return paths;
}

- (void)collectBundlesInDirectory:(NSString *)dirPath
                           result:(NSMutableDictionary *)bundlesById
{
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
            [self collectBundlesInDirectory:fullPath result:bundlesById];
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

- (id<StatusItemProvider>)loadCompiledInProviderForIdentifier:(NSString *)identifier
{
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"org.gnustep.menuextra.clock":      @"ClockExtra",
            @"org.gnustep.menuextra.battery":    @"BatteryExtra",
            @"org.gnustep.menuextra.wlan":       @"WLANExtra",
            @"org.gnustep.menuextra.sound":      @"SoundExtra",
            @"org.gnustep.menuextra.brightness": @"BrightnessExtra",
            @"org.gershwin.menu.statusitem.time":       @"TimeDisplayProvider",
            @"org.gershwin.menu.statusitem.cpu":       @"CPUProvider",
            @"org.gershwin.menu.statusitem.ram":       @"RAMProvider",
        };
    });

    NSString *className = [map objectForKey:identifier];
    if (!className) return nil;

    Class cls = NSClassFromString(className);
    if (!cls) return nil;

    NSLog(@"GSMenuExtra: trying compiled-in class %@ for identifier %@", className, identifier);

    if ([cls conformsToProtocol:@protocol(GSMenuExtra)]) {
        id<GSMenuExtra> extra = [[cls alloc] init];
        if (!extra) return nil;
        GSMenuExtraContext *ctx = [[GSMenuExtraContext alloc] initWithManager:self identifier:identifier];
        return [[GSMenuExtraAdapter alloc] initWithGSMenuExtra:extra identifier:identifier context:ctx];
    }

    if ([cls conformsToProtocol:@protocol(StatusItemProvider)]) {
        id<StatusItemProvider> provider = [[cls alloc] init];
        if (!provider) return nil;
        [provider loadWithManager:self];
        return provider;
    }

    return nil;
}

#pragma mark - Bundle loading

- (id<StatusItemProvider>)loadProviderFromBundle:(GSMenuExtraBundle *)bundle
{
    NSBundle *nsBundle = [bundle bundle];

    @try {
        if (![nsBundle isLoaded]) {
            NSError *error = nil;
            if (![nsBundle loadAndReturnError:&error]) return nil;
        }

        Class principalClass = [nsBundle principalClass];
        if (!principalClass) return nil;

        if ([bundle isGSMenuExtra]) {
            if (![principalClass conformsToProtocol:@protocol(GSMenuExtra)]) return nil;

            id<GSMenuExtra> extra = [[principalClass alloc] init];
            if (!extra) return nil;

            GSMenuExtraContext *context =
                [[GSMenuExtraContext alloc] initWithManager:self
                                                 identifier:[bundle identifier]];

            return [[GSMenuExtraAdapter alloc] initWithGSMenuExtra:extra
                                                        identifier:[bundle identifier]
                                                           context:context];
        }

        if (![principalClass conformsToProtocol:@protocol(StatusItemProvider)]) return nil;

        id<StatusItemProvider> provider = [[principalClass alloc] init];
        if (!provider) return nil;

        [provider loadWithManager:self];
        return provider;
    } @catch (NSException *exception) {
        return nil;
    }
}

#pragma mark - Main loading

- (void)loadStatusItems
{
    NSMutableSet *loadedIdentifiers = [NSMutableSet set];
    NSMutableArray *allProviders = [NSMutableArray array];

    NSArray *bundles = [self discoverBundles];

    for (GSMenuExtraBundle *bundle in bundles) {
        NSString *ident = [bundle identifier];
        if ([loadedIdentifiers containsObject:ident]) continue;

        NSLog(@"GSMenuExtra: loading bundle %@", ident);
        id<StatusItemProvider> provider = [self loadProviderFromBundle:bundle];
        if (provider) {
            [loadedIdentifiers addObject:ident];
            [allProviders addObject:provider];
            GSMenuExtraInstance *instance = [[GSMenuExtraInstance alloc] initWithProvider:provider view:nil];
            [_instances setObject:instance forKey:ident];
            NSLog(@"GSMenuExtra: loaded bundle %@", ident);
        } else {
            NSLog(@"GSMenuExtra: FAILED to load bundle %@", ident);
        }
    }

    /* Fallback: try compiled-in classes for any extras not found as bundles */
    NSLog(@"GSMenuExtra: trying compiled-in fallback...");
    NSArray *builtinIds = @[
        @"org.gnustep.menuextra.clock",
        @"org.gnustep.menuextra.battery",
        @"org.gnustep.menuextra.wlan",
        @"org.gnustep.menuextra.sound",
        @"org.gnustep.menuextra.brightness",
        @"org.gershwin.menu.statusitem.cpu",
        @"org.gershwin.menu.statusitem.ram"
    ];
    for (NSString *ident in builtinIds) {
        if ([loadedIdentifiers containsObject:ident]) continue;
        id<StatusItemProvider> provider = [self loadCompiledInProviderForIdentifier:ident];
        if (provider) {
            [provider loadWithManager:self];
            [loadedIdentifiers addObject:ident];
            [allProviders addObject:provider];
            GSMenuExtraInstance *instance = [[GSMenuExtraInstance alloc] initWithProvider:provider view:nil];
            [_instances setObject:instance forKey:ident];
            NSLog(@"GSMenuExtra: loaded compiled-in %@", ident);
        }
    }

    NSArray *savedOrder = [self loadOrderPreference];
    NSSet *enabledSet = [self loadEnabledPreference];
    NSMutableArray *orderedAll = [NSMutableArray arrayWithCapacity:[allProviders count]];
    NSMutableArray *orderedEnabled = [NSMutableArray arrayWithCapacity:[allProviders count]];

    NSMutableDictionary *providersById = [NSMutableDictionary dictionary];
    for (id<StatusItemProvider> p in allProviders) {
        [providersById setObject:p forKey:[p identifier]];
    }

    for (NSString *ident in savedOrder) {
        id<StatusItemProvider> p = [providersById objectForKey:ident];
        if (p) {
            [orderedAll addObject:p];
            if (!enabledSet || [enabledSet containsObject:ident]) {
                [orderedEnabled addObject:p];
            }
            [providersById removeObjectForKey:ident];
        }
    }

    for (id<StatusItemProvider> p in allProviders) {
        if ([providersById objectForKey:[p identifier]]) {
            [orderedAll addObject:p];
            if (!enabledSet || [enabledSet containsObject:[p identifier]]) {
                [orderedEnabled addObject:p];
            }
        }
    }

    NSComparisonResult (^providerComparator)(id<StatusItemProvider>, id<StatusItemProvider>) =
        ^NSComparisonResult(id<StatusItemProvider> a, id<StatusItemProvider> b) {
            NSInteger pa = 100, pb = 100;
            if ([a respondsToSelector:@selector(displayPriority)]) pa = [a displayPriority];
            if ([b respondsToSelector:@selector(displayPriority)]) pb = [b displayPriority];
            if (pa < pb) return NSOrderedAscending;
            if (pa > pb) return NSOrderedDescending;
            return NSOrderedSame;
        };

    _allStatusItems = orderedAll;
    _statusItems = orderedEnabled;

    [_allStatusItems sortUsingComparator:providerComparator];
    [_statusItems sortUsingComparator:providerComparator];

    [self startFileSystemMonitoring];
}

- (NSArray<id<StatusItemProvider>> *)allStatusItems
{
    return _allStatusItems;
}

- (id<StatusItemProvider>)providerForIdentifier:(NSString *)identifier
{
    if (!identifier) return nil;

    for (id<StatusItemProvider> provider in _allStatusItems) {
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

    for (id<StatusItemProvider> provider in _statusItems) {
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

- (CGFloat)extrasMenuWidth
{
    if ([_extrasMenuItems count] == 0 || !_extrasMenuView) return 0;

    objc_setAssociatedObject(_extrasMenuView, &kWidthIndexKey, @0, OBJC_ASSOCIATION_RETAIN);
    [_extrasMenuView sizeToFit];

    __block CGFloat maxX = 0;
    [[_extrasMenu itemArray] enumerateObjectsUsingBlock:
        ^(NSMenuItem *item, NSUInteger idx, BOOL *stop) {
            NSRect r = [_extrasMenuView rectOfItemAtIndex: idx];
            CGFloat right = NSMaxX(r);
            if (right > maxX) maxX = right;
        }];

    return maxX;
}

#pragma mark - Update timers

- (void)startUpdateTimers
{
    NSMutableDictionary *intervalGroups = [NSMutableDictionary dictionary];

    for (id<StatusItemProvider> item in _statusItems) {
        NSTimeInterval interval = 1.0;
        if ([item respondsToSelector:@selector(updateInterval)]) {
            interval = [item updateInterval];
        }
        if (interval <= 0) continue;
        if (interval < 0.5) interval = 0.5;

        NSNumber *key = @(interval);
        NSMutableArray *group = [intervalGroups objectForKey:key];
        if (!group) {
            group = [NSMutableArray array];
            [intervalGroups setObject:group forKey:key];
        }
        [group addObject:item];
    }

    for (NSNumber *intervalKey in intervalGroups) {
        NSTimeInterval interval = [intervalKey doubleValue];
        NSArray *items = [intervalGroups objectForKey:intervalKey];

        NSTimer *timer =
            [NSTimer scheduledTimerWithTimeInterval:interval
                                             target:self
                                           selector:@selector(updateTimerFired:)
                                           userInfo:items
                                            repeats:YES];
        [_updateTimers setObject:timer forKey:intervalKey];
        [self updateTimerFired:timer];
    }
}

- (void)updateTimerFired:(NSTimer *)timer
{
    objc_setAssociatedObject(_extrasMenuView, &kWidthIndexKey, @0, OBJC_ASSOCIATION_RETAIN);
    NSArray *items = [timer userInfo];
    for (id<StatusItemProvider> item in items) {
        @try {
            if ([item respondsToSelector:@selector(update)]) {
                [item update];
            }
            NSString *title = [item title];
            if (!title) {
                title = [NSString stringWithFormat:@"[%@]", [item identifier]];
            }
            NSMenuItem *menuItem = [_extrasMenuItems objectForKey:[item identifier]];
            if (menuItem) [menuItem setTitle:title];
        } @catch (NSException *exception) {}
    }
}

- (void)stopUpdateTimers
{
    for (NSTimer *timer in [_updateTimers allValues]) {
        [timer invalidate];
    }
    [_updateTimers removeAllObjects];
}

#pragma mark - Presentation invalidation

- (void)refreshExtraWithIdentifier:(NSString *)identifier
{
    NSMenuItem *menuItem = [_extrasMenuItems objectForKey:identifier];
    if (!menuItem) return;

    for (id<StatusItemProvider> provider in _statusItems) {
        if ([[provider identifier] isEqualToString:identifier]) {
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
            }
            if ([provider respondsToSelector:@selector(menu)]) {
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
            } else if ([provider respondsToSelector:@selector(refreshMenuItems:)]) {
                NSMenu *sub = [menuItem submenu];
                if (sub) [provider refreshMenuItems:sub];
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
    id<StatusItemProvider> provider = [self providerForIdentifier:identifier];
    if (!provider) { _needsUpdateGuard = NO; return; }

    if ([provider respondsToSelector:@selector(menuWillOpen)]) {
        [provider menuWillOpen];
    }
    if ([provider respondsToSelector:@selector(menu)]) {
        NSMenu *freshMenu = [provider menu];
        if (freshMenu && freshMenu != menu) {
            [self replaceMenu:menu withMenu:freshMenu];
        }
    }
    if ([provider respondsToSelector:@selector(refreshMenuItems:)]) {
        [provider refreshMenuItems:menu];
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
    id<StatusItemProvider> provider = [self providerForIdentifier:identifier];
    if ([provider respondsToSelector:@selector(menuDidClose)]) {
        [provider menuDidClose];
    }
}

#pragma mark - Preferences

- (void)savePreferences
{
    NSMutableArray *order = [NSMutableArray arrayWithCapacity:[_statusItems count]];
    for (id<StatusItemProvider> item in _statusItems) {
        [order addObject:[item identifier]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:order forKey:GSMenuExtraOrderKey];

    NSMutableArray *enabled = [NSMutableArray arrayWithCapacity:[_statusItems count]];
    for (id<StatusItemProvider> item in _statusItems) {
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
        id<StatusItemProvider> toRemove = nil;
        for (id<StatusItemProvider> p in _statusItems) {
            if ([[p identifier] isEqualToString:name] || [[p identifier] isEqualToString:path]) {
                toRemove = p;
                break;
            }
        }
        if (toRemove) {
            if ([toRemove respondsToSelector:@selector(unload)]) [toRemove unload];
            [_statusItems removeObject:toRemove];
            NSString *ident = [toRemove identifier];
            [_extrasMenuItems removeObjectForKey:ident];
            [_instances removeObjectForKey:ident];
        }
        [_knownBundlePaths removeObject:path];
    }

    for (NSString *path in added) {
        NSURL *url = [NSURL fileURLWithPath:path];
        GSMenuExtraBundle *bundle = [[GSMenuExtraBundle alloc] initWithURL:url];

        NSString *ident = [bundle identifier];
        if (ident && ![_instances objectForKey:ident]) {
            id<StatusItemProvider> provider = [self loadProviderFromBundle:bundle];
            if (provider) {
                [provider loadWithManager:self];
                [_statusItems addObject:provider];
                [_knownBundlePaths addObject:path];

                GSMenuExtraInstance *inst = [[GSMenuExtraInstance alloc] initWithProvider:provider view:nil];
                [_instances setObject:inst forKey:ident];
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

#pragma mark - Cleanup

- (void)unloadAllStatusItems
{
    [self stopUpdateTimers];

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if (_fsMonitorSource) {
        dispatch_source_cancel(_fsMonitorSource);
        _fsMonitorSource = nil;
    }

    [self savePreferences];

    for (id<StatusItemProvider> item in _statusItems) {
        @try {
            if ([item respondsToSelector:@selector(unload)]) [item unload];
        } @catch (NSException *exception) {}
    }

    [_extrasMenuItems removeAllObjects];
    _extrasMenu = nil;
    _extrasMenuView = nil;
    [_statusItems removeAllObjects];
    [_instances removeAllObjects];
}

@end

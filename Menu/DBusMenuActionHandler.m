/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#import "DBusMenuActionHandler.h"
#import "DBusConnection.h"
#import "X11ShortcutManager.h"
#import "MenuProfiler.h"

// DBus info is stored on each NSMenuItem via -setRepresentedObject: with a
// dictionary under the key "dbusInfo".  NSMenuItem copies retain the
// representedObject, so the info survives the deep copy performed by
// MenuProtocolManager.prependGNUstepStubIfNeeded (which merges a GNUstep stub
// menu with a DBus menu for bundled apps).  The previous scheme
// keyed a static dict by the item's pointer, which broke as soon as the
// menu was copied.
static NSString *const kDBusInfoKey = @"dbusInfo";

@implementation DBusMenuActionHandler

+ (void)setupActionForMenuItem:(NSMenuItem *)menuItem
                   serviceName:(NSString *)serviceName
                    objectPath:(NSString *)objectPath
                dbusConnection:(GNUDBusConnection *)dbusConnection
{
    if (!menuItem || !serviceName || !objectPath || !dbusConnection) {
        NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: ERROR: Missing required parameters for action setup");
        return;
    }

    [menuItem setTarget:[DBusMenuActionHandler class]];
    [menuItem setAction:@selector(menuItemAction:)];

    // Preserve any existing representedObject (DBusMenuParser sets it to the
    // item ID as an NSNumber) by wrapping it alongside the DBus info.
    id existing = [menuItem representedObject];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                 serviceName,    @"serviceName",
                                 objectPath,     @"objectPath",
                                 dbusConnection, @"dbusConnection",
                                 nil];
    if (existing) {
        info[@"itemId"] = existing;
    }
    [menuItem setRepresentedObject:@{ kDBusInfoKey: info }];
    
    NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: Set up action for menu item '%@' (ID=%ld, service=%@, path=%@)", 
          [menuItem title], (long)[menuItem tag], serviceName, objectPath);
    
    // Register global shortcut if we have a key equivalent and swapping is enabled
    if ([[menuItem keyEquivalent] length] > 0 && [menuItem keyEquivalentModifierMask] > 0) {
        NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: Menu item '%@' has shortcut: %@+%lu", 
              [menuItem title], [menuItem keyEquivalent], (unsigned long)[menuItem keyEquivalentModifierMask]);
        
        if ([[X11ShortcutManager sharedManager] shouldSwapCtrlAlt]) {
            NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: Registering shortcut for menu item '%@'", [menuItem title]);
            [[X11ShortcutManager sharedManager] registerShortcutForMenuItem:menuItem 
                                                                serviceName:serviceName 
                                                                 objectPath:objectPath 
                                                             dbusConnection:dbusConnection];
        } else {
            NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: Shortcut swapping disabled, not registering");
        }
    } else {
        NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: Menu item '%@' has no shortcut", [menuItem title]);
    }
}

+ (void)menuItemAction:(id)sender
{
    MENU_PROFILE_BEGIN(DBusMenuItemAction);
    
    NSMenuItem *menuItem = (NSMenuItem *)sender;

    // Retrieve DBus connection info from the menu item's representedObject.
    NSDictionary *rep = nil;
    id raw = [menuItem representedObject];
    if ([raw isKindOfClass:[NSDictionary class]]) {
        rep = [(NSDictionary *)raw objectForKey:kDBusInfoKey];
    }

    NSString *serviceName = [rep objectForKey:@"serviceName"];
    NSString *objectPath = [rep objectForKey:@"objectPath"];
    GNUDBusConnection *dbusConnection = [rep objectForKey:@"dbusConnection"];

    if (!serviceName || !objectPath || !dbusConnection) {
        NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: ERROR: Missing DBus info for menu item '%@'", [menuItem title]);
        NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: Service: %@, Path: %@, Connection: %@", serviceName, objectPath, dbusConnection);
        MENU_PROFILE_END(DBusMenuItemAction);
        return;
    }
    
    int menuItemId = [menuItem tag];
    NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: Triggering action for menu item '%@' (ID=%d, service=%@, path=%@)", 
          [menuItem title], menuItemId, serviceName, objectPath);
    
    // Send Event method call to activate the menu item
    // According to DBusMenu spec, Event method signature is: (isvu)
    // Based on reference implementation: id, eventType, data (variant), timestamp
    
    // Create unsigned int NSNumber explicitly using NSValue approach
    unsigned int timestampValue = 0;
    NSNumber *timestampNumber = [[NSNumber alloc] initWithUnsignedInt:timestampValue];
    NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: Timestamp NSNumber objCType: %s (unsigned int: %s)", 
          [timestampNumber objCType], @encode(unsigned int));
    
    NSArray *arguments = [NSArray arrayWithObjects:
                         [NSNumber numberWithInt:menuItemId],  // menu item ID (int32)
                         @"clicked",                           // event type (string)
                         @"",                                  // event data (variant - empty string as placeholder)
                         timestampNumber,                      // timestamp (uint32 - 0 for current time)
                         nil];
    
    NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: Calling Event method with signature (isvu) and arguments: %@", arguments);
    NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: Argument details:");
    for (NSUInteger i = 0; i < [arguments count]; i++) {
        id arg = [arguments objectAtIndex:i];
        NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler:   [%lu]: %@ (class: %@)", (unsigned long)i, arg, [arg class]);
    }
    
    id result = [dbusConnection callMethod:@"Event"
                                 onService:serviceName
                                objectPath:objectPath
                                 interface:@"com.canonical.dbusmenu"
                                 arguments:arguments];
    
    if (result) {
        NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: Event method call succeeded, result: %@", result);
    } else {
        NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: Event method call failed or returned nil");
    }
    
    MENU_PROFILE_END(DBusMenuItemAction);
}

+ (BOOL)shouldSwapCtrlAlt
{
    return [[X11ShortcutManager sharedManager] shouldSwapCtrlAlt];
}

+ (void)setSwapCtrlAlt:(BOOL)swap
{
    [[X11ShortcutManager sharedManager] setSwapCtrlAlt:swap];
    NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: Ctrl/Alt swapping %@", swap ? @"enabled" : @"disabled");
}

+ (void)cleanup
{
    NSDebugLLog(@"gwcomp", @"DBusMenuActionHandler: Performing cleanup...");
    [[X11ShortcutManager sharedManager] cleanup];
}

@end

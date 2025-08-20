#import "DBusMenuActionHandler.h"
#import "DBusConnection.h"
#import "X11ShortcutManager.h"

// Static variables to store DBus connection info for menu actions
static NSMutableDictionary *menuItemToServiceMap = nil;
static NSMutableDictionary *menuItemToObjectPathMap = nil;
static NSMutableDictionary *menuItemToConnectionMap = nil;

@implementation DBusMenuActionHandler

+ (void)initialize
{
    if (self == [DBusMenuActionHandler class]) {
        menuItemToServiceMap = [[NSMutableDictionary alloc] init];
        menuItemToObjectPathMap = [[NSMutableDictionary alloc] init];
        menuItemToConnectionMap = [[NSMutableDictionary alloc] init];
    }
}

+ (void)setupActionForMenuItem:(NSMenuItem *)menuItem
                   serviceName:(NSString *)serviceName
                    objectPath:(NSString *)objectPath
                dbusConnection:(GNUDBusConnection *)dbusConnection
{
    if (!menuItem || !serviceName || !objectPath || !dbusConnection) {
        NSLog(@"DBusMenuActionHandler: ERROR: Missing required parameters for action setup");
        return;
    }
    
    [menuItem setTarget:[DBusMenuActionHandler class]];
    [menuItem setAction:@selector(menuItemAction:)];
    
    // Store DBus connection info for this menu item
    NSString *menuItemKey = [NSString stringWithFormat:@"%p", menuItem];
    [menuItemToServiceMap setObject:serviceName forKey:menuItemKey];
    [menuItemToObjectPathMap setObject:objectPath forKey:menuItemKey];
    [menuItemToConnectionMap setObject:dbusConnection forKey:menuItemKey];
    
    NSLog(@"DBusMenuActionHandler: Set up action for menu item '%@' (ID=%ld, service=%@, path=%@)", 
          [menuItem title], (long)[menuItem tag], serviceName, objectPath);
    
    // Register global shortcut if we have a key equivalent and swapping is enabled
    if ([[menuItem keyEquivalent] length] > 0 && [menuItem keyEquivalentModifierMask] > 0) {
        NSLog(@"DBusMenuActionHandler: Menu item '%@' has shortcut: %@+%lu", 
              [menuItem title], [menuItem keyEquivalent], (unsigned long)[menuItem keyEquivalentModifierMask]);
        
        if ([[X11ShortcutManager sharedManager] shouldSwapCtrlAlt]) {
            NSLog(@"DBusMenuActionHandler: Registering shortcut for menu item '%@'", [menuItem title]);
            [[X11ShortcutManager sharedManager] registerShortcutForMenuItem:menuItem 
                                                                serviceName:serviceName 
                                                                 objectPath:objectPath 
                                                             dbusConnection:dbusConnection];
        } else {
            NSLog(@"DBusMenuActionHandler: Shortcut swapping disabled, not registering");
        }
    } else {
        NSLog(@"DBusMenuActionHandler: Menu item '%@' has no shortcut", [menuItem title]);
    }
}

+ (void)menuItemAction:(id)sender
{
    NSMenuItem *menuItem = (NSMenuItem *)sender;
    NSString *menuItemKey = [NSString stringWithFormat:@"%p", menuItem];
    
    // Retrieve DBus connection info for this menu item
    NSString *serviceName = [menuItemToServiceMap objectForKey:menuItemKey];
    NSString *objectPath = [menuItemToObjectPathMap objectForKey:menuItemKey];
    GNUDBusConnection *dbusConnection = [menuItemToConnectionMap objectForKey:menuItemKey];
    
    if (!serviceName || !objectPath || !dbusConnection) {
        NSLog(@"DBusMenuActionHandler: ERROR: Missing DBus info for menu item '%@'", [menuItem title]);
        NSLog(@"DBusMenuActionHandler: Service: %@, Path: %@, Connection: %@", serviceName, objectPath, dbusConnection);
        return;
    }
    
    int menuItemId = [menuItem tag];
    NSLog(@"DBusMenuActionHandler: Triggering action for menu item '%@' (ID=%d, service=%@, path=%@)", 
          [menuItem title], menuItemId, serviceName, objectPath);
    
    // Send Event method call to activate the menu item
    // According to DBusMenu spec, Event method signature is: (isvu)
    // Based on reference implementation: id, eventType, data (variant), timestamp
    
    // Create unsigned int NSNumber explicitly using NSValue approach
    unsigned int timestampValue = 0;
    NSNumber *timestampNumber = [[NSNumber alloc] initWithUnsignedInt:timestampValue];
    NSLog(@"DBusMenuActionHandler: Timestamp NSNumber objCType: %s (unsigned int: %s)", 
          [timestampNumber objCType], @encode(unsigned int));
    
    NSArray *arguments = [NSArray arrayWithObjects:
                         [NSNumber numberWithInt:menuItemId],  // menu item ID (int32)
                         @"clicked",                           // event type (string)
                         @"",                                  // event data (variant - empty string as placeholder)
                         timestampNumber,                      // timestamp (uint32 - 0 for current time)
                         nil];
    
    NSLog(@"DBusMenuActionHandler: Calling Event method with signature (isvu) and arguments: %@", arguments);
    NSLog(@"DBusMenuActionHandler: Argument details:");
    for (NSUInteger i = 0; i < [arguments count]; i++) {
        id arg = [arguments objectAtIndex:i];
        NSLog(@"DBusMenuActionHandler:   [%lu]: %@ (class: %@)", (unsigned long)i, arg, [arg class]);
    }
    
    id result = [dbusConnection callMethod:@"Event"
                                 onService:serviceName
                                objectPath:objectPath
                                 interface:@"com.canonical.dbusmenu"
                                 arguments:arguments];
    
    if (result) {
        NSLog(@"DBusMenuActionHandler: Event method call succeeded, result: %@", result);
    } else {
        NSLog(@"DBusMenuActionHandler: Event method call failed or returned nil");
    }
}

+ (BOOL)shouldSwapCtrlAlt
{
    return [[X11ShortcutManager sharedManager] shouldSwapCtrlAlt];
}

+ (void)setSwapCtrlAlt:(BOOL)swap
{
    [[X11ShortcutManager sharedManager] setSwapCtrlAlt:swap];
    NSLog(@"DBusMenuActionHandler: Ctrl/Alt swapping %@", swap ? @"enabled" : @"disabled");
}

+ (void)cleanup
{
    NSLog(@"DBusMenuActionHandler: Performing cleanup...");
    [[X11ShortcutManager sharedManager] cleanup];
    
    // Clean up static dictionaries
    [menuItemToServiceMap removeAllObjects];
    [menuItemToObjectPathMap removeAllObjects];
    [menuItemToConnectionMap removeAllObjects];
}

@end

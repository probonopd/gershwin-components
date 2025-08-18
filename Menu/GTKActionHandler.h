#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@class GNUDBusConnection;

/**
 * GTKActionHandler
 * 
 * Handles GTK-style action activation using org.gtk.Actions interface.
 * This is separate from the Canonical dbusmenu action handling.
 */
@interface GTKActionHandler : NSObject

// Set up action handling for a GTK menu item (full method)
+ (void)setupActionForMenuItem:(NSMenuItem *)menuItem
                    actionName:(NSString *)actionName
                   serviceName:(NSString *)serviceName
                    actionPath:(NSString *)actionPath
                dbusConnection:(GNUDBusConnection *)dbusConnection;

// Legacy method for compatibility
+ (void)setupActionForMenuItem:(NSMenuItem *)menuItem;

// GTK menu item action handler
+ (void)gtkMenuItemAction:(id)sender;

// Query action state for stateful actions
+ (NSDictionary *)getActionState:(NSString *)actionName
                     serviceName:(NSString *)serviceName
                      actionPath:(NSString *)actionPath
                  dbusConnection:(GNUDBusConnection *)dbusConnection;

// Cleanup method
+ (void)cleanup;

@end

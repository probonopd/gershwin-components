#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

// DBus connection wrapper for GNUstep - avoiding glib dependencies
@interface GNUDBusConnection : NSObject
{
    void *_connection; // DBusConnection pointer (opaque)
    BOOL _connected;
    NSMutableDictionary *_messageHandlers;
}

+ (GNUDBusConnection *)sessionBus;
- (BOOL)connect;
- (void)disconnect;
- (BOOL)isConnected;
- (BOOL)registerService:(NSString *)serviceName;
- (BOOL)registerObjectPath:(NSString *)objectPath 
                 interface:(NSString *)interfaceName 
                   handler:(id)handler;
- (id)callMethod:(NSString *)method
      onService:(NSString *)serviceName
    objectPath:(NSString *)objectPath
     interface:(NSString *)interfaceName
     arguments:(NSArray *)arguments;
- (void)processMessages;

@end

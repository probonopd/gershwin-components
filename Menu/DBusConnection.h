#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

// Forward declaration
struct DBusMessage;

// DBus connection wrapper for GNUstep
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
- (id)callGTKActivateMethod:(NSString *)actionName
                  parameter:(NSArray *)parameter
               platformData:(NSDictionary *)platformData
                  onService:(NSString *)serviceName
                 objectPath:(NSString *)objectPath;
- (void)processMessages;
- (void *)rawConnection;
- (int)getFileDescriptor;
- (BOOL)sendReply:(void *)reply;
- (void)handleIncomingMessage:(struct DBusMessage *)message;

@end

#import <Foundation/Foundation.h>
#import <dbus/dbus.h>

@class MBMessage;

@interface MBConnectionDBus : NSObject {
    int _fd;
    NSString *_connectionName;
    BOOL _authenticated;
    
    // libdbus integration
    DBusAuth *_auth;
    DBusString *_authIncoming;
    DBusString *_authOutgoing;
    
    // State
    BOOL _authCompleted;
    NSMutableData *_pendingData;
}

@property (nonatomic, assign) int fd;
@property (nonatomic, copy) NSString *connectionName;
@property (nonatomic, assign) BOOL authenticated;

- (id)initWithFileDescriptor:(int)fd;
- (BOOL)processIncomingData:(NSData *)data;
- (NSData *)getOutgoingData;
- (void)sendMessage:(MBMessage *)message;
- (void)close;

@end

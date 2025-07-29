#import <Foundation/Foundation.h>
#import <dbus/dbus.h>

@interface MBDaemonLibDBus : NSObject {
    DBusServer *_server;
    DBusConnection *_systemBus;
    NSMutableArray *_connections;
    BOOL _running;
}

@property (nonatomic, assign) BOOL running;

- (BOOL)startWithSocketPath:(NSString *)socketPath;
- (void)stop;
- (void)runMainLoop;

@end

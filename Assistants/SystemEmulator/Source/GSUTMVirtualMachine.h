#import <Foundation/Foundation.h>
#import "GSUTMConstants.h"
#import "GSUTMConfiguration.h"

extern NSString *const GSUTMStateDidChangeNotification;
extern NSString *const GSUTMConsoleOutputNotification;
extern NSString *const GSUTMConsoleOutputDataKey;

@interface GSUTMVirtualMachine : NSObject

@property (nonatomic, strong, readonly) GSUTMConfiguration *configuration;
@property (nonatomic, readonly) GSUTMMachineState state;
@property (nonatomic, strong, readonly) NSTask *task;
@property (nonatomic, readonly) pid_t qemuPID;
@property (nonatomic, copy) void (^onStateChange)(GSUTMMachineState newState);
@property (nonatomic, copy) void (^onConsoleOutput)(NSData *data);

- (instancetype)initWithConfiguration:(GSUTMConfiguration *)config;

- (BOOL)startWithError:(NSError **)error;
- (void)stop;
- (void)sendConsoleInput:(NSData *)data;

@end

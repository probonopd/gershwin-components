#ifndef MB_CLIENT_H
#define MB_CLIENT_H

#import <Foundation/Foundation.h>

@class MBMessage;

/**
 * MBClient - High-level D-Bus client API
 * 
 * Provides easy-to-use interface for applications to send/receive D-Bus messages
 */
@interface MBClient : NSObject
{
    int _socket;
    NSString *_uniqueName;
    NSUInteger _nextSerial;
    NSMutableData *_readBuffer;
    NSMutableDictionary *_pendingCalls;
}

@property (nonatomic, readonly) NSString *uniqueName;
@property (nonatomic, readonly) BOOL connected;

/**
 * Connect to D-Bus daemon
 */
- (BOOL)connectToPath:(NSString *)socketPath;

/**
 * Disconnect from D-Bus daemon
 */
- (void)disconnect;

/**
 * Send method call and wait for reply
 */
- (MBMessage *)callMethod:(NSString *)destination
                     path:(NSString *)path
                interface:(NSString *)interface
                   member:(NSString *)member
                arguments:(NSArray *)arguments
                  timeout:(NSTimeInterval)timeout;

/**
 * Send method call asynchronously
 */
- (BOOL)callMethodAsync:(NSString *)destination
                   path:(NSString *)path
              interface:(NSString *)interface
                 member:(NSString *)member
              arguments:(NSArray *)arguments
                  reply:(void(^)(MBMessage *reply))replyBlock;

/**
 * Send signal
 */
- (BOOL)emitSignal:(NSString *)path
         interface:(NSString *)interface
            member:(NSString *)member
         arguments:(NSArray *)arguments;

/**
 * Register well-known name
 */
- (BOOL)requestName:(NSString *)name;

/**
 * Release well-known name
 */
- (BOOL)releaseName:(NSString *)name;

/**
 * Process incoming messages (call periodically or in run loop)
 */
- (NSArray *)processMessages;

/**
 * Send raw message
 */
- (BOOL)sendMessage:(MBMessage *)message;

@end

#endif // MB_CLIENT_H

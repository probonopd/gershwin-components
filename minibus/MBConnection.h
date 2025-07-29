#ifndef MB_CONNECTION_H
#define MB_CONNECTION_H

#import <Foundation/Foundation.h>

@class MBMessage;
@class MBDaemon;

typedef enum {
    MBConnectionStateWaitingForAuth,
    MBConnectionStateWaitingForHello,
    MBConnectionStateActive
} MBConnectionState;

/**
 * MBConnection - Represents a connection to the message bus
 */
@interface MBConnection : NSObject
{
    int _socket;
    MBConnectionState _state;
    NSString *_uniqueName;
    MBDaemon *_daemon;
    NSMutableData *_readBuffer;
    BOOL _authProcessed;  // Track if AUTH command was processed
    
    // Debug counters
    int _processIncomingDataCallCount;
    int _processAuthenticationCallCount;
}

@property (nonatomic, readonly) int socket;
@property (nonatomic, assign) MBConnectionState state;
@property (nonatomic, copy) NSString *uniqueName;
@property (nonatomic, weak) MBDaemon *daemon;

/**
 * Initialize with socket file descriptor
 */
- (instancetype)initWithSocket:(int)socket daemon:(MBDaemon *)daemon;

/**
 * Send message to this connection
 */
- (BOOL)sendMessage:(MBMessage *)message;

/**
 * Send multiple messages atomically in a single write
 */
- (BOOL)sendMessages:(NSArray *)messages;

/**
 * Read and process incoming data
 * Returns array of complete messages received
 */
- (NSArray *)processIncomingData;

/**
 * Handle authentication (simplified)
 */
- (BOOL)handleAuthentication;

/**
 * Close the connection
 */
- (void)close;

@end

#endif // MB_CONNECTION_H

#ifndef MB_TRANSPORT_H
#define MB_TRANSPORT_H

#import <Foundation/Foundation.h>

/**
 * MBTransport - Low-level transport handling
 * 
 * Handles socket creation, connection, and basic I/O
 */
@interface MBTransport : NSObject

/**
 * Create Unix domain socket server
 */
+ (int)createUnixServerSocket:(NSString *)path;

/**
 * Create Unix domain socket client connection
 */
+ (int)connectToUnixSocket:(NSString *)path;

/**
 * Accept connection on server socket
 */
+ (int)acceptConnection:(int)serverSocket;

/**
 * Send data on socket
 */
+ (BOOL)sendData:(NSData *)data onSocket:(int)socket;

/**
 * Receive data from socket (non-blocking)
 */
+ (NSData *)receiveDataFromSocket:(int)socket;

/**
 * Close socket
 */
+ (void)closeSocket:(int)socket;

/**
 * Set socket non-blocking
 */
+ (BOOL)setSocketNonBlocking:(int)socket;

@end

#endif // MB_TRANSPORT_H

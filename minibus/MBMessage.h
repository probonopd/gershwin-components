/*
 * Copyright (c) 2025 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */


#ifndef MB_MESSAGE_H
#define MB_MESSAGE_H

#import <Foundation/Foundation.h>

typedef enum {
    MBMessageTypeMethodCall = 1,
    MBMessageTypeMethodReturn = 2,
    MBMessageTypeError = 3,
    MBMessageTypeSignal = 4
} MBMessageType;

/**
 * MBMessage - D-Bus message representation
 * 
 * Handles serialization/deserialization of D-Bus messages
 * according to the D-Bus wire protocol specification
 */
@interface MBMessage : NSObject
{
    MBMessageType _type;
    NSString *_destination;
    NSString *_sender;
    NSString *_path;
    NSString *_interface;
    NSString *_member;
    NSString *_signature;
    NSArray *_arguments;
    NSUInteger _serial;
    NSUInteger _replySerial;
    NSString *_errorName;
}

@property (nonatomic, assign) MBMessageType type;
@property (nonatomic, copy) NSString *destination;
@property (nonatomic, copy) NSString *sender;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *interface;
@property (nonatomic, copy) NSString *member;
@property (nonatomic, copy) NSString *signature;
@property (nonatomic, copy) NSArray *arguments;
@property (nonatomic, assign) NSUInteger serial;
@property (nonatomic, assign) NSUInteger replySerial;
@property (nonatomic, copy) NSString *errorName;

/**
 * Create method call message
 */
+ (instancetype)methodCallWithDestination:(NSString *)destination
                                     path:(NSString *)path
                                interface:(NSString *)interface
                                   member:(NSString *)member
                                arguments:(NSArray *)arguments;

/**
 * Create method return message
 */
+ (instancetype)methodReturnWithReplySerial:(NSUInteger)replySerial
                                  arguments:(NSArray *)arguments;

/**
 * Create error message
 */
+ (instancetype)errorWithName:(NSString *)errorName
                  replySerial:(NSUInteger)replySerial
                      message:(NSString *)message;

/**
 * Create signal message
 */
+ (instancetype)signalWithPath:(NSString *)path
                     interface:(NSString *)interface
                        member:(NSString *)member
                     arguments:(NSArray *)arguments;

/**
 * Serialize message to data for transmission
 */
- (NSData *)serialize;

/**
 * Deserialize message from data
 */
+ (instancetype)messageFromData:(NSData *)data offset:(NSUInteger *)offset;

/**
 * Parse multiple messages from buffer
 */
+ (NSArray *)messagesFromData:(NSData *)data;

/**
 * Parse multiple messages from buffer with consumed byte tracking
 */
+ (NSArray *)messagesFromData:(NSData *)data consumedBytes:(NSUInteger *)consumedBytes;

/**
 * Parse arguments from body data with specific endianness
 */
+ (NSArray *)parseArgumentsFromBodyData:(NSData *)bodyData signature:(NSString *)signature endianness:(uint8_t)endianness;

/**
 * Infer a D-Bus signature for a list of Foundation values
 */
+ (NSString *)signatureForArguments:(NSArray *)arguments;

/**
 * Infer a D-Bus signature for a single Foundation value
 */
+ (NSString *)signatureForValue:(id)value;

/**
 * Total wire length of the first message in data.
 * Returns 0 if fewer than 16 bytes (fixed header) are available,
 * NSNotFound if the bytes do not start with a valid message header,
 * otherwise the complete message length including header, padding and body.
 */
+ (NSUInteger)messageLengthFromData:(NSData *)data;

@end

#endif // MB_MESSAGE_H

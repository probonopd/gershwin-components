#import "DSPlatform.h"
#import <stdio.h>

@interface DSPlatformLinux : NSObject <DSPlatform>
@end

@implementation DSPlatformLinux

- (NSString *)platformName
{
    return @"Linux";
}

- (BOOL)isAvailable
{
#if defined(__linux__)
    return YES;
#else
    return NO;
#endif
}

- (void)printUnsupported:(const char *)operation
{
    fprintf(stderr, "The '%s' command is not yet supported on Linux.\n", operation);
    fprintf(stderr, "Please follow the manual NFS configuration steps in the README.\n");
}

#pragma mark - Server (Promote) Operations

- (BOOL)configureNFSExports
{
    [self printUnsupported:"promote"];
    return NO;
}

- (BOOL)enableNFSServer
{
    [self printUnsupported:"promote"];
    return NO;
}

- (BOOL)startNFSServer
{
    [self printUnsupported:"promote"];
    return NO;
}

- (BOOL)restartDSHelper
{
    [self printUnsupported:"promote"];
    return NO;
}

- (BOOL)removeNFSExports
{
    [self printUnsupported:"demote"];
    return NO;
}

- (BOOL)stopNFSServer
{
    [self printUnsupported:"demote"];
    return NO;
}

- (BOOL)unregisterService
{
    [self printUnsupported:"demote"];
    return NO;
}

#pragma mark - Client (Join) Operations

- (BOOL)enableNFSClient
{
    [self printUnsupported:"join"];
    return NO;
}

- (BOOL)startNFSClient
{
    [self printUnsupported:"join"];
    return NO;
}

- (BOOL)createNetworkMount:(NSString *)server
{
    [self printUnsupported:"join"];
    return NO;
}

- (BOOL)addFstabEntry:(NSString *)server
{
    [self printUnsupported:"join"];
    return NO;
}

- (BOOL)mountNetwork
{
    [self printUnsupported:"join"];
    return NO;
}

- (BOOL)unmountNetwork
{
    [self printUnsupported:"leave"];
    return NO;
}

- (BOOL)removeFstabEntry
{
    [self printUnsupported:"leave"];
    return NO;
}

- (NSString *)discoverDirectoryServer
{
    [self printUnsupported:"join"];
    return nil;
}

@end

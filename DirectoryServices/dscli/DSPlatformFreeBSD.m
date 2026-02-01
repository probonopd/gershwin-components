#import "DSPlatform.h"
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

@interface DSPlatformFreeBSD : NSObject <DSPlatform>
@end

@implementation DSPlatformFreeBSD

- (NSString *)platformName
{
    return @"FreeBSD";
}

- (BOOL)isAvailable
{
#if defined(__FreeBSD__) || defined(__DragonFly__)
    return YES;
#else
    return NO;
#endif
}

#pragma mark - Helper Methods

- (BOOL)runCommand:(NSString *)command
{
    int result = system([command UTF8String]);
    return (result == 0);
}

- (BOOL)serviceEnable:(NSString *)service
{
    NSString *cmd = [NSString stringWithFormat:@"sysrc %@_enable=YES >/dev/null 2>&1", service];
    return [self runCommand:cmd];
}

- (BOOL)serviceStart:(NSString *)service
{
    NSString *cmd = [NSString stringWithFormat:@"service %@ start >/dev/null 2>&1", service];
    return [self runCommand:cmd];
}

- (BOOL)serviceRestart:(NSString *)service
{
    NSString *cmd = [NSString stringWithFormat:@"service %@ restart >/dev/null 2>&1", service];
    return [self runCommand:cmd];
}

- (NSString *)readFile:(NSString *)path
{
    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];
    return contents;
}

- (BOOL)writeFile:(NSString *)path contents:(NSString *)contents
{
    NSError *error = nil;
    return [contents writeToFile:path
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:&error];
}

- (BOOL)appendToFile:(NSString *)path line:(NSString *)line
{
    NSString *contents = [self readFile:path];
    if (!contents) {
        contents = @"";
    }

    // Check if line already exists
    if ([contents rangeOfString:line].location != NSNotFound) {
        return YES; // Already present
    }

    // Ensure file ends with newline before appending
    if ([contents length] > 0 && ![contents hasSuffix:@"\n"]) {
        contents = [contents stringByAppendingString:@"\n"];
    }

    contents = [contents stringByAppendingFormat:@"%@\n", line];
    return [self writeFile:path contents:contents];
}

#pragma mark - Server (Promote) Operations

- (BOOL)configureNFSExports
{
    NSString *exportLine = @"/Local -alldirs -maproot=root";
    NSString *exportsPath = @"/etc/exports";

    // Check if already configured
    NSString *contents = [self readFile:exportsPath];
    if (contents && [contents rangeOfString:@"/Local"].location != NSNotFound) {
        printf("NFS exports already configured for /Local\n");
        return YES;
    }

    if (![self appendToFile:exportsPath line:exportLine]) {
        fprintf(stderr, "Failed to update /etc/exports\n");
        return NO;
    }

    printf("Added /Local to NFS exports\n");
    return YES;
}

- (BOOL)enableNFSServer
{
    BOOL success = YES;

    if (![self serviceEnable:@"rpcbind"]) {
        fprintf(stderr, "Failed to enable rpcbind\n");
        success = NO;
    } else {
        printf("Enabled rpcbind\n");
    }

    if (![self serviceEnable:@"nfs_server"]) {
        fprintf(stderr, "Failed to enable nfs_server\n");
        success = NO;
    } else {
        printf("Enabled nfs_server\n");
    }

    if (![self serviceEnable:@"mountd"]) {
        fprintf(stderr, "Failed to enable mountd\n");
        success = NO;
    } else {
        printf("Enabled mountd\n");
    }

    return success;
}

- (BOOL)startNFSServer
{
    BOOL success = YES;

    if (![self serviceStart:@"rpcbind"]) {
        // May already be running
        printf("rpcbind: already running or failed to start\n");
    } else {
        printf("Started rpcbind\n");
    }

    if (![self serviceStart:@"mountd"]) {
        printf("mountd: already running or failed to start\n");
    } else {
        printf("Started mountd\n");
    }

    if (![self serviceStart:@"nfsd"]) {
        fprintf(stderr, "Failed to start nfsd\n");
        success = NO;
    } else {
        printf("Started nfsd\n");
    }

    // Reload exports
    [self runCommand:@"exportfs -r >/dev/null 2>&1"];

    return success;
}

#pragma mark - Client (Join) Operations

- (BOOL)enableNFSClient
{
    BOOL success = YES;

    if (![self serviceEnable:@"rpcbind"]) {
        fprintf(stderr, "Failed to enable rpcbind\n");
        success = NO;
    } else {
        printf("Enabled rpcbind\n");
    }

    if (![self serviceEnable:@"nfs_client"]) {
        fprintf(stderr, "Failed to enable nfs_client\n");
        success = NO;
    } else {
        printf("Enabled nfs_client\n");
    }

    return success;
}

- (BOOL)startNFSClient
{
    BOOL success = YES;

    if (![self serviceStart:@"rpcbind"]) {
        printf("rpcbind: already running or failed to start\n");
    } else {
        printf("Started rpcbind\n");
    }

    if (![self serviceStart:@"nfsclient"]) {
        printf("nfsclient: already running or failed to start\n");
    } else {
        printf("Started nfsclient\n");
    }

    return success;
}

- (BOOL)createNetworkMount:(NSString *)server
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;

    if (![fm fileExistsAtPath:@"/Network"]) {
        if (![fm createDirectoryAtPath:@"/Network"
           withIntermediateDirectories:YES
                            attributes:@{NSFilePosixPermissions: @0755}
                                 error:&error]) {
            fprintf(stderr, "Failed to create /Network: %s\n",
                    [[error localizedDescription] UTF8String]);
            return NO;
        }
        printf("Created /Network\n");
    }

    return YES;
}

- (BOOL)addFstabEntry:(NSString *)server
{
    NSString *fstabLine = [NSString stringWithFormat:@"%@:/Local\t/Network\tnfs\trw\t0\t0", server];
    NSString *fstabPath = @"/etc/fstab";

    // Check if already configured
    NSString *contents = [self readFile:fstabPath];
    if (contents && [contents rangeOfString:@"/Network"].location != NSNotFound) {
        printf("fstab already configured for /Network\n");
        return YES;
    }

    if (![self appendToFile:fstabPath line:fstabLine]) {
        fprintf(stderr, "Failed to update /etc/fstab\n");
        return NO;
    }

    printf("Added %s:/Local -> /Network to fstab\n", [server UTF8String]);
    return YES;
}

- (BOOL)mountNetwork
{
    // Check if already mounted
    NSString *cmd = @"mount | grep '/Network' >/dev/null 2>&1";
    if ([self runCommand:cmd]) {
        printf("/Network already mounted\n");
        return YES;
    }

    if (![self runCommand:@"mount /Network"]) {
        fprintf(stderr, "Failed to mount /Network\n");
        return NO;
    }

    printf("Mounted /Network\n");
    return YES;
}

#pragma mark - Leave Operations

- (BOOL)unmountNetwork
{
    // Check if mounted
    NSString *cmd = @"mount | grep '/Network' >/dev/null 2>&1";
    if (![self runCommand:cmd]) {
        printf("/Network not mounted\n");
        return YES;
    }

    if (![self runCommand:@"umount /Network"]) {
        fprintf(stderr, "Failed to unmount /Network (may be in use)\n");
        return NO;
    }

    printf("Unmounted /Network\n");
    return YES;
}

- (BOOL)removeFstabEntry
{
    NSString *fstabPath = @"/etc/fstab";
    NSString *contents = [self readFile:fstabPath];

    if (!contents) {
        return YES;
    }

    NSMutableArray *lines = [[contents componentsSeparatedByString:@"\n"] mutableCopy];
    BOOL modified = NO;

    for (NSInteger i = [lines count] - 1; i >= 0; i--) {
        NSString *line = lines[i];
        if ([line rangeOfString:@"/Network"].location != NSNotFound) {
            [lines removeObjectAtIndex:i];
            modified = YES;
        }
    }

    if (modified) {
        NSString *newContents = [lines componentsJoinedByString:@"\n"];
        if (![self writeFile:fstabPath contents:newContents]) {
            fprintf(stderr, "Failed to update /etc/fstab\n");
            return NO;
        }
        printf("Removed /Network from fstab\n");
    }

    return YES;
}

#pragma mark - Discovery

- (NSString *)discoverDirectoryServer
{
    printf("Searching for directory server...\n");

    // Use NSSocketPortNameServer to find registered GershwinDirectory service
    // The "*" host triggers a broadcast lookup via rpcbind
    NSSocketPortNameServer *ns = [NSSocketPortNameServer sharedInstance];

    @try {
        NSPort *port = [ns portForName:@"GershwinDirectory" onHost:@"*"];
        if (port && [port isKindOfClass:[NSSocketPort class]]) {
            NSSocketPort *socketPort = (NSSocketPort *)port;

            // Get the remote address from the socket port
            NSString *address = [socketPort address];
            if (address && [address length] > 0) {
                // Try to resolve to hostname
                NSHost *remoteHost = [NSHost hostWithAddress:address];
                NSString *hostname = [remoteHost name];
                if (hostname) {
                    printf("Found directory server: %s (%s)\n",
                           [hostname UTF8String], [address UTF8String]);
                    return hostname;
                } else {
                    printf("Found directory server: %s\n", [address UTF8String]);
                    return address;
                }
            }
        }
    } @catch (NSException *e) {
        // Broadcast lookup may throw if rpcbind not available
        NSLog(@"Discovery exception: %@", e);
    }

    return nil;
}

@end

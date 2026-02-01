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

- (BOOL)restartDSHelper
{
    // Restart dshelper so it detects server role and registers with gdomap
    if ([self serviceRestart:@"dshelper"]) {
        printf("Restarted dshelper (service now discoverable)\n");
        return YES;
    }
    fprintf(stderr, "Failed to restart dshelper\n");
    return NO;
}

#pragma mark - Server (Demote) Operations

- (BOOL)removeNFSExports
{
    NSString *exportsPath = @"/etc/exports";
    NSString *contents = [self readFile:exportsPath];

    if (!contents) {
        return YES;
    }

    NSMutableArray *lines = [[contents componentsSeparatedByString:@"\n"] mutableCopy];
    BOOL modified = NO;

    for (NSInteger i = [lines count] - 1; i >= 0; i--) {
        NSString *line = lines[i];
        if ([line rangeOfString:@"/Local"].location != NSNotFound) {
            [lines removeObjectAtIndex:i];
            modified = YES;
        }
    }

    if (modified) {
        NSString *newContents = [lines componentsJoinedByString:@"\n"];
        if (![self writeFile:exportsPath contents:newContents]) {
            fprintf(stderr, "Failed to update /etc/exports\n");
            return NO;
        }
        printf("Removed /Local from NFS exports\n");

        // Reload exports
        [self runCommand:@"exportfs -r >/dev/null 2>&1"];
    }

    return YES;
}

- (BOOL)stopNFSServer
{
    // Stop nfsd but leave rpcbind running (may be needed by other services)
    if ([self runCommand:@"service nfsd stop >/dev/null 2>&1"]) {
        printf("Stopped nfsd\n");
    }

    if ([self runCommand:@"service mountd stop >/dev/null 2>&1"]) {
        printf("Stopped mountd\n");
    }

    return YES;
}

- (BOOL)unregisterService
{
    // Unregister GershwinDirectory from gdomap
    if ([self runCommand:@"/System/Library/Tools/gdomap -U GershwinDirectory -T tcp_gdo >/dev/null 2>&1"]) {
        printf("Unregistered GershwinDirectory from gdomap\n");
        return YES;
    }
    return NO;
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

    // Generate interface config for gdomap if needed
    // gdomap needs to know local interfaces to do broadcast lookups
    const char *ifaceConf = "/tmp/gdomap-iface.conf";
    FILE *ifp = popen(
        "ifconfig -a | awk '"
        "/^[a-z]/ { iface = $1 } "
        "/inet / && !/127\\.0\\.0\\.1/ { "
        "    addr = $2; "
        "    for (i = 1; i <= NF; i++) { "
        "        if ($i == \"netmask\") mask = $(i+1); "
        "        if ($i == \"broadcast\") bcast = $(i+1); "
        "    } "
        "    if (addr && mask) { "
        "        if (mask ~ /^0x/) { "
        "            cmd = \"printf \\\"%d.%d.%d.%d\\\" 0x\" substr(mask,3,2) \" 0x\" substr(mask,5,2) \" 0x\" substr(mask,7,2) \" 0x\" substr(mask,9,2); "
        "            cmd | getline mask; "
        "            close(cmd); "
        "        } "
        "        print addr, mask, (bcast ? bcast : \"0.0.0.0\"); "
        "    } "
        "}'", "r");
    if (ifp) {
        FILE *conf = fopen(ifaceConf, "w");
        if (conf) {
            char buf[256];
            while (fgets(buf, sizeof(buf), ifp)) {
                fputs(buf, conf);
            }
            fclose(conf);
        }
        pclose(ifp);
    }

    // Use gdomap to lookup the GershwinDirectory service
    // -a specifies interface config, -L performs lookup
    char cmd[512];
    snprintf(cmd, sizeof(cmd),
        "/System/Library/Tools/gdomap -a %s -L GershwinDirectory -T tcp_gdo -M '*' 2>/dev/null",
        ifaceConf);

    FILE *fp = popen(cmd, "r");
    if (!fp) {
        unlink(ifaceConf);
        return nil;
    }

    char buffer[512];
    NSString *result = nil;

    while (fgets(buffer, sizeof(buffer), fp)) {
        // gdomap output: "Found GershwinDirectory on '<ip>' port <port>"
        NSString *line = [NSString stringWithUTF8String:buffer];

        // Look for "Found" pattern
        NSRange foundRange = [line rangeOfString:@"Found "];
        if (foundRange.location != NSNotFound) {
            // Extract IP from 'x.x.x.x'
            NSRange quoteStart = [line rangeOfString:@"'"];
            if (quoteStart.location != NSNotFound) {
                NSUInteger start = quoteStart.location + 1;
                NSRange quoteEnd = [line rangeOfString:@"'" options:0
                                                 range:NSMakeRange(start, [line length] - start)];
                if (quoteEnd.location != NSNotFound) {
                    NSString *addr = [line substringWithRange:
                        NSMakeRange(start, quoteEnd.location - start)];
                    if ([addr length] > 0) {
                        printf("Found directory server: %s\n", [addr UTF8String]);
                        result = addr;
                        break;
                    }
                }
            }
        }
    }

    pclose(fp);
    unlink(ifaceConf);
    return result;
}

@end

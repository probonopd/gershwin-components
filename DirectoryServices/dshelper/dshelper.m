#import "dshelper.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/select.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <pthread.h>

@implementation DSHelper {
    int _serverSocket;
    int _discoverySocket;
    BOOL _running;
}

+ (instancetype)sharedHelper {
    static DSHelper *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[DSHelper alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverSocket = -1;
        _discoverySocket = -1;
        _running = NO;
    }
    return self;
}

#pragma mark - Path Resolution

- (NSString *)usersPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    // Check /Network first (client with mounted server)
    if ([fm fileExistsAtPath:DS_NETWORK_USERS_PLIST]) {
        return DS_NETWORK_USERS_PLIST;
    }
    // Fall back to /Local (server or standalone)
    return DS_LOCAL_USERS_PLIST;
}

- (NSString *)groupsPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:DS_NETWORK_GROUPS_PLIST]) {
        return DS_NETWORK_GROUPS_PLIST;
    }
    return DS_LOCAL_GROUPS_PLIST;
}

- (BOOL)isServer {
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm fileExistsAtPath:DS_DOMAIN_PLIST];
}

- (BOOL)isClient {
    // Client = reading from /Network (not server or standalone)
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm fileExistsAtPath:DS_NETWORK_USERS_PLIST];
}

#pragma mark - Plist Loading

- (NSDictionary *)loadUsers {
    NSString *path = [self usersPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    NSDate *modDate = attrs[NSFileModificationDate];

    if (self.usersCache && self.usersCacheDate &&
        [modDate compare:self.usersCacheDate] != NSOrderedDescending) {
        return self.usersCache;
    }

    self.usersCache = [NSDictionary dictionaryWithContentsOfFile:path];
    self.usersCacheDate = modDate;

    if (!self.usersCache) {
        NSLog(@"dshelper: No users found at %@", path);
        self.usersCache = @{};
    } else {
        NSLog(@"dshelper: Loaded %lu users from %@", (unsigned long)[self.usersCache count], path);
    }

    return self.usersCache;
}

- (NSDictionary *)loadGroups {
    NSString *path = [self groupsPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    NSDate *modDate = attrs[NSFileModificationDate];

    if (self.groupsCache && self.groupsCacheDate &&
        [modDate compare:self.groupsCacheDate] != NSOrderedDescending) {
        return self.groupsCache;
    }

    self.groupsCache = [NSDictionary dictionaryWithContentsOfFile:path];
    self.groupsCacheDate = modDate;

    if (!self.groupsCache) {
        self.groupsCache = @{};
    } else {
        NSLog(@"dshelper: Loaded %lu groups from %@", (unsigned long)[self.groupsCache count], path);
    }

    return self.groupsCache;
}

#pragma mark - User Lookups

- (NSDictionary *)userWithName:(NSString *)name {
    NSDictionary *users = [self loadUsers];
    return users[name];
}

- (NSDictionary *)userWithUID:(uid_t)uid {
    NSDictionary *users = [self loadUsers];
    for (NSString *username in users) {
        NSDictionary *user = users[username];
        id uidValue = user[@"uid"];
        uid_t userUid;
        if ([uidValue isKindOfClass:[NSNumber class]]) {
            userUid = [uidValue unsignedIntValue];
        } else {
            userUid = (uid_t)[[uidValue description] intValue];
        }
        if (userUid == uid) {
            return user;
        }
    }
    return nil;
}

- (NSArray *)allUsers {
    NSDictionary *users = [self loadUsers];
    return [users allValues];
}

#pragma mark - Group Lookups

- (NSDictionary *)groupWithName:(NSString *)name {
    NSDictionary *groups = [self loadGroups];
    return groups[name];
}

- (NSDictionary *)groupWithGID:(gid_t)gid {
    NSDictionary *groups = [self loadGroups];
    for (NSString *groupname in groups) {
        NSDictionary *group = groups[groupname];
        id gidValue = group[@"gid"];
        gid_t groupGid;
        if ([gidValue isKindOfClass:[NSNumber class]]) {
            groupGid = [gidValue unsignedIntValue];
        } else {
            groupGid = (gid_t)[[gidValue description] intValue];
        }
        if (groupGid == gid) {
            return group;
        }
    }
    return nil;
}

- (NSArray *)allGroups {
    NSDictionary *groups = [self loadGroups];
    return [groups allValues];
}

#pragma mark - Password Handling

- (NSString *)hashPassword:(NSString *)password {
    // Generate random salt
    uint8_t saltBytes[16];
    arc4random_buf(saltBytes, sizeof(saltBytes));

    static const char *saltChars =
        "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    char saltStr[17];
    for (int i = 0; i < 16; i++) {
        saltStr[i] = saltChars[saltBytes[i] % 64];
    }
    saltStr[16] = '\0';

    // SHA-512 format: $6$rounds=N$salt$
    char setting[64];
    snprintf(setting, sizeof(setting), "$6$rounds=5000$%s$", saltStr);

    char *hash = crypt([password UTF8String], setting);
    if (!hash) return nil;

    return [NSString stringWithUTF8String:hash];
}

- (BOOL)verifyPassword:(NSString *)password againstHash:(NSString *)hash {
    if (!password || !hash) return NO;

    char *computed = crypt([password UTF8String], [hash UTF8String]);
    if (!computed) return NO;

    return strcmp(computed, [hash UTF8String]) == 0;
}

- (BOOL)authenticateUser:(NSString *)username password:(NSString *)password {
    NSDictionary *user = [self userWithName:username];
    if (!user) return NO;

    NSString *storedHash = user[@"passwordHash"];
    if (!storedHash || [storedHash isEqual:[NSNull null]]) return NO;

    return [self verifyPassword:password againstHash:storedHash];
}

#pragma mark - Socket Server

- (BOOL)startServer {
    // Remove old socket if exists
    unlink(DS_SOCKET_PATH);

    // Create UNIX socket for local clients (NSS/PAM)
    _serverSocket = socket(AF_UNIX, SOCK_STREAM, 0);
    if (_serverSocket < 0) {
        NSLog(@"dshelper: Failed to create UNIX socket: %s", strerror(errno));
        return NO;
    }

    // Bind to path
    struct sockaddr_un unixAddr;
    memset(&unixAddr, 0, sizeof(unixAddr));
    unixAddr.sun_family = AF_UNIX;
    strncpy(unixAddr.sun_path, DS_SOCKET_PATH, sizeof(unixAddr.sun_path) - 1);

    if (bind(_serverSocket, (struct sockaddr *)&unixAddr, sizeof(unixAddr)) < 0) {
        NSLog(@"dshelper: Failed to bind UNIX socket: %s", strerror(errno));
        close(_serverSocket);
        _serverSocket = -1;
        return NO;
    }

    // Make socket world-accessible (NSS/PAM run as various users)
    chmod(DS_SOCKET_PATH, 0666);

    if (listen(_serverSocket, 10) < 0) {
        NSLog(@"dshelper: Failed to listen on UNIX socket: %s", strerror(errno));
        close(_serverSocket);
        _serverSocket = -1;
        return NO;
    }

    NSLog(@"dshelper: Listening on %s", DS_SOCKET_PATH);

    // For servers, also create TCP socket for network discovery
    if ([self isServer]) {
        _discoverySocket = socket(AF_INET, SOCK_STREAM, 0);
        if (_discoverySocket < 0) {
            NSLog(@"dshelper: Failed to create TCP socket: %s", strerror(errno));
        } else {
            int reuse = 1;
            setsockopt(_discoverySocket, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

            struct sockaddr_in tcpAddr;
            memset(&tcpAddr, 0, sizeof(tcpAddr));
            tcpAddr.sin_family = AF_INET;
            tcpAddr.sin_addr.s_addr = INADDR_ANY;
            tcpAddr.sin_port = htons(DS_SERVICE_PORT);

            if (bind(_discoverySocket, (struct sockaddr *)&tcpAddr, sizeof(tcpAddr)) < 0) {
                NSLog(@"dshelper: Failed to bind TCP port %d: %s", DS_SERVICE_PORT, strerror(errno));
                close(_discoverySocket);
                _discoverySocket = -1;
            } else if (listen(_discoverySocket, 10) < 0) {
                NSLog(@"dshelper: Failed to listen on TCP port %d: %s", DS_SERVICE_PORT, strerror(errno));
                close(_discoverySocket);
                _discoverySocket = -1;
            } else {
                NSLog(@"dshelper: Listening on TCP port %d", DS_SERVICE_PORT);
            }
        }
    }

    _running = YES;

    // Accept loop using select() to handle both sockets
    while (_running) {
        fd_set readfds;
        FD_ZERO(&readfds);
        FD_SET(_serverSocket, &readfds);

        int maxFd = _serverSocket;
        if (_discoverySocket >= 0) {
            FD_SET(_discoverySocket, &readfds);
            if (_discoverySocket > maxFd) maxFd = _discoverySocket;
        }

        struct timeval tv;
        tv.tv_sec = 1;
        tv.tv_usec = 0;

        int ready = select(maxFd + 1, &readfds, NULL, NULL, &tv);
        if (ready < 0) {
            if (errno == EINTR) continue;
            if (_running) {
                NSLog(@"dshelper: select failed: %s", strerror(errno));
            }
            break;
        }

        if (ready == 0) continue; // Timeout, check _running

        // Check UNIX socket
        if (FD_ISSET(_serverSocket, &readfds)) {
            int clientFd = accept(_serverSocket, NULL, NULL);
            if (clientFd >= 0) {
                [self handleClient:clientFd];
            }
        }

        // Check TCP socket (for network clients)
        if (_discoverySocket >= 0 && FD_ISSET(_discoverySocket, &readfds)) {
            int clientFd = accept(_discoverySocket, NULL, NULL);
            if (clientFd >= 0) {
                [self handleNetworkClient:clientFd];
            }
        }
    }

    return YES;
}

- (void)stopServer {
    _running = NO;
    if (_serverSocket >= 0) {
        close(_serverSocket);
        _serverSocket = -1;
    }
    if (_discoverySocket >= 0) {
        close(_discoverySocket);
        _discoverySocket = -1;
    }
    unlink(DS_SOCKET_PATH);
}

- (void)handleNetworkClient:(int)clientFd {
    // Network clients can only perform limited operations (no credential passing)
    // They can request directory info but cannot modify data
    char buffer[2048];
    ssize_t n = read(clientFd, buffer, sizeof(buffer) - 1);
    if (n <= 0) {
        close(clientFd);
        return;
    }
    buffer[n] = '\0';

    // Remove trailing newline if present
    if (n > 0 && buffer[n-1] == '\n') {
        buffer[n-1] = '\0';
    }

    NSString *request = [NSString stringWithUTF8String:buffer];

    // For network clients, only allow read operations (caller is not trusted)
    // Use a non-root UID to restrict access
    NSString *response = [self processRequest:request callerUid:(uid_t)-1];

    if (response) {
        write(clientFd, [response UTF8String], [response lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    }

    close(clientFd);
}

- (void)handleClient:(int)clientFd {
    // Get peer credentials to check if caller is root
    uid_t peerUid = (uid_t)-1;
    gid_t peerGid = (gid_t)-1;
    if (getpeereid(clientFd, &peerUid, &peerGid) < 0) {
        NSLog(@"dshelper: getpeereid failed: %s", strerror(errno));
        // Default to non-root for safety
        peerUid = (uid_t)-1;
    }

    char buffer[2048];
    ssize_t n = read(clientFd, buffer, sizeof(buffer) - 1);
    if (n <= 0) {
        close(clientFd);
        return;
    }
    buffer[n] = '\0';

    // Remove trailing newline if present
    if (n > 0 && buffer[n-1] == '\n') {
        buffer[n-1] = '\0';
    }

    NSString *request = [NSString stringWithUTF8String:buffer];
    NSString *response = [self processRequest:request callerUid:peerUid];

    if (response) {
        write(clientFd, [response UTF8String], [response lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    }

    close(clientFd);
}

- (NSString *)processRequest:(NSString *)request callerUid:(uid_t)callerUid {
    NSArray *parts = [request componentsSeparatedByString:@":"];
    if (parts.count < 1) return @"ERROR";

    NSString *command = parts[0];
    BOOL callerIsRoot = (callerUid == 0);

    // getpwnam:username -> name:hash_or_star:uid:gid:gecos:home:shell
    // Hash is only returned if caller is root (like /etc/master.passwd)
    if ([command isEqualToString:@"getpwnam"] && parts.count >= 2) {
        NSString *username = parts[1];
        NSDictionary *user = [self userWithName:username];
        if (user) {
            return [self passwdLineForUser:user includeHash:callerIsRoot];
        }
        return @"NOTFOUND";
    }

    // getpwuid:uid -> name:hash_or_star:uid:gid:gecos:home:shell
    if ([command isEqualToString:@"getpwuid"] && parts.count >= 2) {
        uid_t uid = [parts[1] intValue];
        NSDictionary *user = [self userWithUID:uid];
        if (user) {
            return [self passwdLineForUser:user includeHash:callerIsRoot];
        }
        return @"NOTFOUND";
    }

    // getgrnam:groupname -> name:x:gid:members
    if ([command isEqualToString:@"getgrnam"] && parts.count >= 2) {
        NSString *groupname = parts[1];
        // Special handling for wheel and sudo - return with admin members
        if ([groupname isEqualToString:@"wheel"] && [self groupExistsInEtcGroup:@"wheel"]) {
            return [self wheelGroupLine];
        }
        if ([groupname isEqualToString:@"sudo"] && [self groupExistsInEtcGroup:@"sudo"]) {
            return [self sudoGroupLine];
        }
        NSDictionary *group = [self groupWithName:groupname];
        if (group) {
            return [self groupLineForGroup:group];
        }
        return @"NOTFOUND";
    }

    // getgrgid:gid -> name:x:gid:members
    if ([command isEqualToString:@"getgrgid"] && parts.count >= 2) {
        gid_t gid = [parts[1] intValue];
        // Special handling for wheel (0) and sudo (27) - only if they exist in /etc/group
        if (gid == 0 && [self groupExistsInEtcGroup:@"wheel"]) {
            return [self wheelGroupLine];
        }
        if (gid == 27 && [self groupExistsInEtcGroup:@"sudo"]) {
            return [self sudoGroupLine];
        }
        NSDictionary *group = [self groupWithGID:gid];
        if (group) {
            return [self groupLineForGroup:group];
        }
        return @"NOTFOUND";
    }

    // auth:username:password -> 1 or 0
    if ([command isEqualToString:@"auth"] && parts.count >= 3) {
        NSString *username = parts[1];
        // Password might contain colons, so rejoin remaining parts
        NSArray *passwordParts = [parts subarrayWithRange:NSMakeRange(2, parts.count - 2)];
        NSString *password = [passwordParts componentsJoinedByString:@":"];

        BOOL success = [self authenticateUser:username password:password];
        return success ? @"1" : @"0";
    }

    // getpwent - enumerate all users (one per line)
    if ([command isEqualToString:@"getpwent"]) {
        NSMutableArray *lines = [NSMutableArray array];
        for (NSDictionary *user in [self allUsers]) {
            [lines addObject:[self passwdLineForUser:user includeHash:callerIsRoot]];
        }
        return [lines componentsJoinedByString:@"\n"];
    }

    // getgrent - enumerate all groups (one per line)
    if ([command isEqualToString:@"getgrent"]) {
        NSMutableArray *lines = [NSMutableArray array];
        for (NSDictionary *group in [self allGroups]) {
            [lines addObject:[self groupLineForGroup:group]];
        }
        return [lines componentsJoinedByString:@"\n"];
    }

    // getgrouplist:username -> gid1,gid2,gid3,...
    // Returns all groups the user is a member of
    if ([command isEqualToString:@"getgrouplist"] && parts.count >= 2) {
        NSString *username = parts[1];
        NSMutableArray *gids = [NSMutableArray array];

        // Get user's primary group
        NSDictionary *user = [self userWithName:username];
        if (user) {
            id gidValue = user[@"gid"];
            if (gidValue) {
                [gids addObject:gidValue];
            }
        }

        // Check all groups for membership
        NSDictionary *groups = [self loadGroups];
        for (NSString *groupname in groups) {
            NSDictionary *group = groups[groupname];
            NSArray *members = group[@"members"];
            if (members && [members containsObject:username]) {
                id gidValue = group[@"gid"];
                if (gidValue && ![gids containsObject:gidValue]) {
                    [gids addObject:gidValue];
                }
            }
        }

        if ([gids count] == 0) {
            return @"NOTFOUND";
        }

        return [gids componentsJoinedByString:@","];
    }

    // getadminmembers -> user1,user2,...
    // Returns all members of the admin group (gid 5000)
    if ([command isEqualToString:@"getadminmembers"]) {
        NSDictionary *adminGroup = [self groupWithGID:5000];
        if (adminGroup) {
            NSArray *members = adminGroup[@"members"];
            if (members && [members count] > 0) {
                return [members componentsJoinedByString:@","];
            }
        }
        return @"NOTFOUND";
    }

    return @"ERROR";
}

- (NSString *)passwdLineForUser:(NSDictionary *)user includeHash:(BOOL)includeHash {
    // Format: name:password:uid:gid:gecos:home:shell
    // If includeHash is YES (caller is root), return actual hash for pam_unix authentication
    // If includeHash is NO, return "*" (like /etc/passwd vs /etc/master.passwd)
    NSString *passwordField = @"*";
    if (includeHash) {
        NSString *hash = user[@"passwordHash"];
        if (hash && ![hash isEqual:[NSNull null]] && [hash length] > 0) {
            passwordField = hash;
        } else {
            // No password set - account is locked
            passwordField = @"*";
        }
    }

    // Construct home directory from username
    // /Local/Users/<username> on server/standalone, /Network/Users/<username> on client
    NSString *base = [self isClient] ? @"/Network" : @"/Local";
    NSString *username = user[@"username"] ?: @"nobody";
    NSString *homeDir = [NSString stringWithFormat:@"%@/Users/%@", base, username];

    return [NSString stringWithFormat:@"%@:%@:%@:%@:%@:%@:%@",
            user[@"username"] ?: @"",
            passwordField,
            user[@"uid"] ?: @"65534",
            user[@"gid"] ?: @"65534",
            user[@"realName"] ?: @"",
            homeDir,
            user[@"shell"] ?: @"/usr/sbin/nologin"];
}

- (NSString *)groupLineForGroup:(NSDictionary *)group {
    // Format: name:x:gid:member1,member2,...
    NSArray *members = group[@"members"] ?: @[];
    NSString *memberStr = [members componentsJoinedByString:@","];

    return [NSString stringWithFormat:@"%@:x:%@:%@",
            group[@"groupname"] ?: @"",
            group[@"gid"] ?: @"65534",
            memberStr];
}

- (NSArray *)adminMembers {
    NSDictionary *adminGroup = [self groupWithGID:5000];
    if (adminGroup) {
        return adminGroup[@"members"] ?: @[];
    }
    return @[];
}

- (BOOL)groupExistsInEtcGroup:(NSString *)groupname {
    NSString *contents = [NSString stringWithContentsOfFile:@"/etc/group"
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    if (!contents) return NO;

    for (NSString *line in [contents componentsSeparatedByString:@"\n"]) {
        NSArray *parts = [line componentsSeparatedByString:@":"];
        if (parts.count >= 3 && [parts[0] isEqualToString:groupname]) {
            return YES;
        }
    }
    return NO;
}

- (NSArray *)membersFromEtcGroup:(NSString *)groupname {
    // Read /etc/group and extract members for a group
    NSString *contents = [NSString stringWithContentsOfFile:@"/etc/group"
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    if (!contents) return @[];

    for (NSString *line in [contents componentsSeparatedByString:@"\n"]) {
        NSArray *parts = [line componentsSeparatedByString:@":"];
        if (parts.count >= 4 && [parts[0] isEqualToString:groupname]) {
            NSString *memberStr = parts[3];
            if (memberStr.length > 0) {
                return [memberStr componentsSeparatedByString:@","];
            }
            return @[];
        }
    }
    return @[];
}

- (NSString *)wheelGroupLine {
    // Merge /etc/group wheel members with admin members
    NSMutableSet *members = [NSMutableSet setWithArray:[self membersFromEtcGroup:@"wheel"]];
    [members addObjectsFromArray:[self adminMembers]];
    NSString *memberStr = [[members allObjects] componentsJoinedByString:@","];
    return [NSString stringWithFormat:@"wheel:x:0:%@", memberStr];
}

- (NSString *)sudoGroupLine {
    // Merge /etc/group sudo members with admin members
    NSMutableSet *members = [NSMutableSet setWithArray:[self membersFromEtcGroup:@"sudo"]];
    [members addObjectsFromArray:[self adminMembers]];
    NSString *memberStr = [[members allObjects] componentsJoinedByString:@","];
    return [NSString stringWithFormat:@"sudo:x:27:%@", memberStr];
}

#pragma mark - Service Registration (gdomap)

- (BOOL)registerService {
    // Only register if we're a server (have Domain.plist)
    if (![self isServer]) {
        NSLog(@"dshelper: Not a server, skipping service registration");
        return YES;
    }

    // Register with gdomap using command line
    // IMPORTANT: -P must come before -R because -R triggers immediate action
    NSString *cmd = [NSString stringWithFormat:
        @"/System/Library/Tools/gdomap -P %d -T tcp_gdo -R %@",
        DS_SERVICE_PORT, DS_SERVICE_NAME];

    int result = system([cmd UTF8String]);
    if (result != 0) {
        NSLog(@"dshelper: Failed to register with gdomap (exit %d)", result);
        return NO;
    }

    NSLog(@"dshelper: Registered '%@' with gdomap on port %d", DS_SERVICE_NAME, DS_SERVICE_PORT);
    return YES;
}

- (void)unregisterService {
    if (![self isServer]) {
        return;
    }

    // Unregister from gdomap
    NSString *cmd = [NSString stringWithFormat:
        @"/System/Library/Tools/gdomap -U %@ -T tcp_gdo",
        DS_SERVICE_NAME];

    system([cmd UTF8String]);
    NSLog(@"dshelper: Unregistered '%@' from gdomap", DS_SERVICE_NAME);
}

@end

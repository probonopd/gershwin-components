#import "gsdh.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

@implementation GSDirectoryHelper {
    int _serverSocket;
    BOOL _running;
}

+ (instancetype)sharedHelper {
    static GSDirectoryHelper *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[GSDirectoryHelper alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverSocket = -1;
        _running = NO;
    }
    return self;
}

#pragma mark - Path Resolution

- (NSString *)usersPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    // Check /Network first (client with mounted server)
    if ([fm fileExistsAtPath:GSDH_NETWORK_USERS_PLIST]) {
        return GSDH_NETWORK_USERS_PLIST;
    }
    // Fall back to /Local (server or standalone)
    return GSDH_LOCAL_USERS_PLIST;
}

- (NSString *)groupsPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:GSDH_NETWORK_GROUPS_PLIST]) {
        return GSDH_NETWORK_GROUPS_PLIST;
    }
    return GSDH_LOCAL_GROUPS_PLIST;
}

- (BOOL)isServer {
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm fileExistsAtPath:GSDH_DOMAIN_PLIST];
}

- (BOOL)isClient {
    // Client = reading from /Network (not server or standalone)
    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm fileExistsAtPath:GSDH_NETWORK_USERS_PLIST];
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
        NSLog(@"gsdh: No users found at %@", path);
        self.usersCache = @{};
    } else {
        NSLog(@"gsdh: Loaded %lu users from %@", (unsigned long)[self.usersCache count], path);
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
        NSLog(@"gsdh: Loaded %lu groups from %@", (unsigned long)[self.groupsCache count], path);
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

    // Check if account can login
    NSNumber *canLogin = user[@"canLogin"];
    if (canLogin && ![canLogin boolValue]) return NO;

    return [self verifyPassword:password againstHash:storedHash];
}

#pragma mark - Socket Server

- (BOOL)startServer {
    // Remove old socket if exists
    unlink(GSDH_SOCKET_PATH);

    // Create socket
    _serverSocket = socket(AF_UNIX, SOCK_STREAM, 0);
    if (_serverSocket < 0) {
        NSLog(@"gsdh: Failed to create socket: %s", strerror(errno));
        return NO;
    }

    // Bind to path
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, GSDH_SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (bind(_serverSocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"gsdh: Failed to bind socket: %s", strerror(errno));
        close(_serverSocket);
        _serverSocket = -1;
        return NO;
    }

    // Make socket world-accessible (NSS/PAM run as various users)
    chmod(GSDH_SOCKET_PATH, 0666);

    // Listen
    if (listen(_serverSocket, 10) < 0) {
        NSLog(@"gsdh: Failed to listen: %s", strerror(errno));
        close(_serverSocket);
        _serverSocket = -1;
        return NO;
    }

    NSLog(@"gsdh: Listening on %s", GSDH_SOCKET_PATH);

    _running = YES;

    // Accept loop
    while (_running) {
        int clientFd = accept(_serverSocket, NULL, NULL);
        if (clientFd < 0) {
            if (_running) {
                NSLog(@"gsdh: Accept failed: %s", strerror(errno));
            }
            continue;
        }

        [self handleClient:clientFd];
    }

    return YES;
}

- (void)stopServer {
    _running = NO;
    if (_serverSocket >= 0) {
        close(_serverSocket);
        _serverSocket = -1;
    }
    unlink(GSDH_SOCKET_PATH);
}

- (void)handleClient:(int)clientFd {
    // Get peer credentials to check if caller is root
    uid_t peerUid = (uid_t)-1;
    gid_t peerGid = (gid_t)-1;
    if (getpeereid(clientFd, &peerUid, &peerGid) < 0) {
        NSLog(@"gsdh: getpeereid failed: %s", strerror(errno));
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

@end

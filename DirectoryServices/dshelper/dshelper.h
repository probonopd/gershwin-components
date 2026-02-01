#import <Foundation/Foundation.h>

#define DS_SOCKET_PATH "/var/run/dshelper.sock"
#define DS_SERVICE_NAME @"GershwinDirectory"
#define DS_SERVICE_PORT 4721
#define DS_DISCOVERY_PORT 4720
#define DS_DISCOVERY_MAGIC "DSDISC"
#define DS_DISCOVERY_PORT 4720
#define DS_DISCOVERY_MAGIC "DSDISC"

// Network paths (checked first - used when mounted from server)
#define DS_NETWORK_USERS_PLIST @"/Network/Library/DirectoryServices/Users.plist"
#define DS_NETWORK_GROUPS_PLIST @"/Network/Library/DirectoryServices/Groups.plist"

// Local paths (fallback - used on server or standalone)
#define DS_LOCAL_USERS_PLIST @"/Local/Library/DirectoryServices/Users.plist"
#define DS_LOCAL_GROUPS_PLIST @"/Local/Library/DirectoryServices/Groups.plist"

// Domain.plist marks a machine as a server
#define DS_DOMAIN_PLIST @"/Local/Library/DirectoryServices/Domain.plist"

@interface DSHelper : NSObject

@property (strong) NSDictionary *usersCache;
@property (strong) NSDictionary *groupsCache;
@property (strong) NSDate *usersCacheDate;
@property (strong) NSDate *groupsCacheDate;

// Singleton
+ (instancetype)sharedHelper;

// Role detection
- (BOOL)isServer;
- (NSString *)usersPath;
- (NSString *)groupsPath;

// Start listening on socket
- (BOOL)startServer;
- (void)stopServer;

// Service registration for discovery
- (BOOL)registerService;
- (void)unregisterService;

// User lookups
- (NSDictionary *)userWithName:(NSString *)name;
- (NSDictionary *)userWithUID:(uid_t)uid;
- (NSArray *)allUsers;

// Group lookups
- (NSDictionary *)groupWithName:(NSString *)name;
- (NSDictionary *)groupWithGID:(gid_t)gid;
- (NSArray *)allGroups;

// Authentication
- (BOOL)authenticateUser:(NSString *)username password:(NSString *)password;

// Password hashing
- (NSString *)hashPassword:(NSString *)password;
- (BOOL)verifyPassword:(NSString *)password againstHash:(NSString *)hash;

@end

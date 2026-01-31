#import <Foundation/Foundation.h>

#define GSDH_SOCKET_PATH "/var/run/gershwin-directory.sock"
#define GSDH_USERS_PLIST @"/Local/Library/DirectoryServices/Users.plist"
#define GSDH_GROUPS_PLIST @"/Local/Library/DirectoryServices/Groups.plist"

@interface GSDirectoryHelper : NSObject

@property (strong) NSDictionary *usersCache;
@property (strong) NSDictionary *groupsCache;
@property (strong) NSDate *usersCacheDate;
@property (strong) NSDate *groupsCacheDate;

// Singleton
+ (instancetype)sharedHelper;

// Start listening on socket
- (BOOL)startServer;
- (void)stopServer;

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

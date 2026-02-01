#import <Foundation/Foundation.h>
#import <unistd.h>
#import <pwd.h>
#import <grp.h>
#import "DSPlatform.h"

// Network paths (checked first - used when mounted from server)
#define DS_NETWORK_USERS_PLIST @"/Network/Library/DirectoryServices/Users.plist"
#define DS_NETWORK_GROUPS_PLIST @"/Network/Library/DirectoryServices/Groups.plist"

// Local paths (fallback - used on server or standalone)
#define DS_LOCAL_USERS_PLIST @"/Local/Library/DirectoryServices/Users.plist"
#define DS_LOCAL_GROUPS_PLIST @"/Local/Library/DirectoryServices/Groups.plist"
#define DS_DOMAIN_PLIST @"/Local/Library/DirectoryServices/Domain.plist"

// Get the appropriate users plist path (Network first, then Local)
static NSString *getUsersPlistPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:DS_NETWORK_USERS_PLIST]) {
        return DS_NETWORK_USERS_PLIST;
    }
    return DS_LOCAL_USERS_PLIST;
}

// Get the appropriate groups plist path (Network first, then Local)
static NSString *getGroupsPlistPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:DS_NETWORK_GROUPS_PLIST]) {
        return DS_NETWORK_GROUPS_PLIST;
    }
    return DS_LOCAL_GROUPS_PLIST;
}


static void printUsage(const char *progname) {
    fprintf(stderr, "Usage: %s <command> [options]\n\n", progname);
    fprintf(stderr, "User Commands:\n");
    fprintf(stderr, "  user list                     List all users\n");
    fprintf(stderr, "  user show <username>          Show user details\n");
    fprintf(stderr, "  user add <username> [options] Add a new user\n");
    fprintf(stderr, "    --uid <uid>                 User ID (auto-assigned if omitted)\n");
    fprintf(stderr, "    --gid <gid>                 Primary group ID (auto-assigned if omitted)\n");
    fprintf(stderr, "    --realname <name>           Real name / GECOS\n");
    fprintf(stderr, "    --shell <shell>             Login shell (default: /bin/sh)\n");
    fprintf(stderr, "    --admin                     Add user to admin group\n");
    fprintf(stderr, "  user delete <username>        Delete a user\n");
    fprintf(stderr, "  user passwd <username>        Set user password\n");
    fprintf(stderr, "  user edit <username> [options] Modify user attributes\n");
    fprintf(stderr, "    --realname <name>           Change real name\n");
    fprintf(stderr, "    --shell <shell>             Change shell\n");
    fprintf(stderr, "    --uid <uid>                 Change UID\n");
    fprintf(stderr, "    --gid <gid>                 Change primary GID\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Group Commands:\n");
    fprintf(stderr, "  group list                    List all groups\n");
    fprintf(stderr, "  group show <groupname>        Show group details\n");
    fprintf(stderr, "  group add <groupname> [--gid <gid>]  Add a new group\n");
    fprintf(stderr, "  group delete <groupname>      Delete a group\n");
    fprintf(stderr, "  group addmember <group> <user>    Add user to group\n");
    fprintf(stderr, "  group removemember <group> <user> Remove user from group\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Other Commands:\n");
    fprintf(stderr, "  list                          List all users, groups, and status\n");
    fprintf(stderr, "  passwd <username>             Set user password (alias for user passwd)\n");
    fprintf(stderr, "  verify <username>             Verify user can authenticate\n");
    fprintf(stderr, "  init                          Initialize directory structure\n");
    fprintf(stderr, "  promote                       Promote to directory server (configure NFS)\n");
    fprintf(stderr, "  demote                        Demote from directory server\n");
    fprintf(stderr, "  join [server]                 Join a directory server (auto-discovers if omitted)\n");
    fprintf(stderr, "  leave                         Leave a directory server\n");
    fprintf(stderr, "\n");
}

static NSMutableDictionary *loadPlist(NSString *path) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!dict) {
        dict = [NSMutableDictionary dictionary];
    }
    return dict;
}

static BOOL savePlist(NSDictionary *dict, NSString *path) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:&error];
    if (error) {
        fprintf(stderr, "Error serializing plist: %s\n", [[error localizedDescription] UTF8String]);
        return NO;
    }

    if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "Error writing plist: %s\n", [[error localizedDescription] UTF8String]);
        return NO;
    }

    return YES;
}

static NSString *hashPassword(NSString *password) {
    uint8_t saltBytes[16];
    arc4random_buf(saltBytes, sizeof(saltBytes));

    static const char *saltChars =
        "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    char saltStr[17];
    for (int i = 0; i < 16; i++) {
        saltStr[i] = saltChars[saltBytes[i] % 64];
    }
    saltStr[16] = '\0';

    char setting[64];
    snprintf(setting, sizeof(setting), "$6$rounds=5000$%s$", saltStr);

    char *hash = crypt([password UTF8String], setting);
    if (!hash) return nil;

    return [NSString stringWithUTF8String:hash];
}

static NSString *readPassword(const char *prompt) {
    char *pass = getpass(prompt);
    if (!pass) return nil;
    return [NSString stringWithUTF8String:pass];
}

static uid_t getUIDValue(id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value unsignedIntValue];
    } else if (value) {
        return (uid_t)[[value description] intValue];
    }
    return 0;
}

static gid_t getGIDValue(id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value unsignedIntValue];
    } else if (value) {
        return (gid_t)[[value description] intValue];
    }
    return 0;
}

static uid_t findNextUID(NSDictionary *users) {
    uid_t maxUID = 5000;
    for (NSString *username in users) {
        NSDictionary *user = users[username];
        uid_t uid = getUIDValue(user[@"uid"]);
        if (uid > maxUID) {
            maxUID = uid;
        }
    }
    return maxUID + 1;
}

static gid_t findNextGID(NSDictionary *groups) {
    gid_t maxGID = 5000;
    for (NSString *groupname in groups) {
        NSDictionary *group = groups[groupname];
        gid_t gid = getGIDValue(group[@"gid"]);
        if (gid > maxGID) {
            maxGID = gid;
        }
    }
    return maxGID + 1;
}

#pragma mark - List All Command

static int cmdList(void) {
    NSFileManager *fm = [NSFileManager defaultManager];

    // Determine role
    BOOL isServer = [fm fileExistsAtPath:DS_DOMAIN_PLIST];
    BOOL isClient = [fm fileExistsAtPath:@"/Network/Library/DirectoryServices"];

    // Show role
    printf("=== Directory Services Status ===\n");
    if (isServer) {
        printf("Role: Server\n");

        // Show connected clients using showmount
        printf("\nConnected Clients:\n");
        FILE *fp = popen("showmount -a 2>/dev/null | tail -n +2 | grep -v '^$'", "r");
        if (fp) {
            char buf[256];
            int count = 0;
            while (fgets(buf, sizeof(buf), fp)) {
                // Format: "host:mountpoint"
                char *colon = strchr(buf, ':');
                if (colon) {
                    *colon = '\0';
                    printf("  %s\n", buf);
                    count++;
                }
            }
            pclose(fp);
            if (count == 0) {
                printf("  (none)\n");
            }
        }
    } else if (isClient) {
        printf("Role: Client\n");

        // Show which server we're connected to from fstab
        printf("\nConnected to Server:\n");
        FILE *fp = popen("grep '/Network' /etc/fstab 2>/dev/null | awk '{print $1}' | cut -d: -f1", "r");
        if (fp) {
            char buf[256];
            if (fgets(buf, sizeof(buf), fp)) {
                buf[strcspn(buf, "\n")] = 0;
                printf("  %s\n", buf);
            } else {
                printf("  (unknown)\n");
            }
            pclose(fp);
        }
    } else {
        printf("Role: Standalone\n");
    }

    // Show users
    NSDictionary *users = loadPlist(getUsersPlistPath());
    printf("\n=== Users (%lu) ===\n", (unsigned long)[users count]);
    if ([users count] > 0) {
        printf("%-20s %-6s %-6s %s\n", "USERNAME", "UID", "GID", "REAL NAME");
        printf("%-20s %-6s %-6s %s\n", "--------", "---", "---", "---------");

        NSArray *sortedUsers = [[users allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSInteger uidA = [users[a][@"uid"] integerValue];
            NSInteger uidB = [users[b][@"uid"] integerValue];
            if (uidA < uidB) return NSOrderedAscending;
            if (uidA > uidB) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        for (NSString *username in sortedUsers) {
            NSDictionary *user = users[username];
            printf("%-20s %-6d %-6d %s\n",
                   [username UTF8String],
                   [user[@"uid"] intValue],
                   [user[@"gid"] intValue],
                   [user[@"realName"] UTF8String] ?: "");
        }
    }

    // Show groups
    NSDictionary *groups = loadPlist(getGroupsPlistPath());
    printf("\n=== Groups (%lu) ===\n", (unsigned long)[groups count]);
    if ([groups count] > 0) {
        printf("%-20s %-6s %s\n", "GROUPNAME", "GID", "MEMBERS");
        printf("%-20s %-6s %s\n", "---------", "---", "-------");

        NSArray *sortedGroups = [[groups allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSInteger gidA = [groups[a][@"gid"] integerValue];
            NSInteger gidB = [groups[b][@"gid"] integerValue];
            if (gidA < gidB) return NSOrderedAscending;
            if (gidA > gidB) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        for (NSString *groupname in sortedGroups) {
            NSDictionary *group = groups[groupname];
            NSArray *members = group[@"members"] ?: @[];
            printf("%-20s %-6d %s\n",
                   [groupname UTF8String],
                   [group[@"gid"] intValue],
                   [[members componentsJoinedByString:@","] UTF8String]);
        }
    }

    return 0;
}

#pragma mark - User Commands

static int cmdUserList(void) {
    NSDictionary *users = loadPlist(getUsersPlistPath());

    if ([users count] == 0) {
        printf("No users defined.\n");
        return 0;
    }

    printf("%-20s %-6s %-6s %s\n", "USERNAME", "UID", "GID", "REAL NAME");
    printf("%-20s %-6s %-6s %s\n", "--------", "---", "---", "---------");

    // Sort by UID
    NSArray *sortedKeys = [[users allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger uidA = [users[a][@"uid"] integerValue];
        NSInteger uidB = [users[b][@"uid"] integerValue];
        if (uidA < uidB) return NSOrderedAscending;
        if (uidA > uidB) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    for (NSString *username in sortedKeys) {
        NSDictionary *user = users[username];
        printf("%-20s %-6d %-6d %s\n",
               [username UTF8String],
               [user[@"uid"] intValue],
               [user[@"gid"] intValue],
               [user[@"realName"] UTF8String] ?: "");
    }

    return 0;
}

static int cmdUserShow(NSString *username) {
    NSDictionary *users = loadPlist(getUsersPlistPath());
    NSDictionary *user = users[username];

    if (!user) {
        fprintf(stderr, "User not found: %s\n", [username UTF8String]);
        return 1;
    }

    printf("Username:   %s\n", [user[@"username"] UTF8String]);
    printf("UID:        %d\n", [user[@"uid"] intValue]);
    printf("GID:        %d\n", [user[@"gid"] intValue]);
    printf("Real Name:  %s\n", [user[@"realName"] UTF8String] ?: "");
    printf("Shell:      %s\n", [user[@"shell"] UTF8String] ?: "/usr/sbin/nologin");
    printf("Password:   %s\n", user[@"passwordHash"] ? "set" : "not set");

    // Show group memberships
    NSDictionary *groups = loadPlist(getGroupsPlistPath());
    NSMutableArray *memberOf = [NSMutableArray array];
    for (NSString *groupname in groups) {
        NSDictionary *group = groups[groupname];
        NSArray *members = group[@"members"];
        if ([members containsObject:username]) {
            [memberOf addObject:groupname];
        }
    }
    if ([memberOf count] > 0) {
        printf("Groups:     %s\n", [[memberOf componentsJoinedByString:@", "] UTF8String]);
    }

    return 0;
}

static int cmdUserAdd(NSArray *args) {
    if ([args count] < 1) {
        fprintf(stderr, "Usage: dscli user add <username> [options]\n");
        return 1;
    }

    NSString *username = args[0];
    NSMutableDictionary *users = loadPlist(getUsersPlistPath());
    NSMutableDictionary *groups = loadPlist(getGroupsPlistPath());

    if (users[username]) {
        fprintf(stderr, "User already exists: %s\n", [username UTF8String]);
        return 1;
    }

    // Parse options
    uid_t uid = 0;
    gid_t gid = 0;
    NSString *realName = nil;
    NSString *shell = @"/bin/sh";
    BOOL addToAdmin = NO;

    for (NSUInteger i = 1; i < [args count]; i++) {
        NSString *arg = args[i];
        if ([arg isEqualToString:@"--uid"] && i + 1 < [args count]) {
            uid = [args[++i] intValue];
        } else if ([arg isEqualToString:@"--gid"] && i + 1 < [args count]) {
            gid = [args[++i] intValue];
        } else if ([arg isEqualToString:@"--realname"] && i + 1 < [args count]) {
            realName = args[++i];
        } else if ([arg isEqualToString:@"--shell"] && i + 1 < [args count]) {
            shell = args[++i];
        } else if ([arg isEqualToString:@"--admin"]) {
            addToAdmin = YES;
        }
    }

    // Auto-assign UID if not specified
    if (uid == 0) {
        uid = findNextUID(users);
    }

    // Auto-assign GID (create user's private group) if not specified
    if (gid == 0) {
        gid = findNextGID(groups);
    }

    // Create user record
    NSMutableDictionary *user = [NSMutableDictionary dictionary];
    user[@"username"] = username;
    user[@"uid"] = @(uid);
    user[@"gid"] = @(gid);
    user[@"shell"] = shell;
    if (realName) {
        user[@"realName"] = realName;
    }

    users[username] = user;

    // Create user's private group if it doesn't exist
    if (!groups[username]) {
        NSMutableDictionary *userGroup = [NSMutableDictionary dictionary];
        userGroup[@"groupname"] = username;
        userGroup[@"gid"] = @(gid);
        groups[username] = userGroup;
    }

    // Add to admin group if requested
    if (addToAdmin) {
        NSMutableDictionary *adminGroup = [groups[@"admin"] mutableCopy];
        if (!adminGroup) {
            adminGroup = [NSMutableDictionary dictionary];
            adminGroup[@"groupname"] = @"admin";
            adminGroup[@"gid"] = @5000;
        }
        NSMutableArray *members = [adminGroup[@"members"] mutableCopy] ?: [NSMutableArray array];
        if (![members containsObject:username]) {
            [members addObject:username];
        }
        adminGroup[@"members"] = members;
        groups[@"admin"] = adminGroup;
    }

    // Save both files
    if (!savePlist(users, getUsersPlistPath())) {
        return 1;
    }
    if (!savePlist(groups, getGroupsPlistPath())) {
        return 1;
    }

    // Create home directory
    NSString *homeDir = [NSString stringWithFormat:@"/Local/Users/%@", username];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;

    if (![fm fileExistsAtPath:homeDir]) {
        [fm createDirectoryAtPath:homeDir
      withIntermediateDirectories:YES
                       attributes:@{
                           NSFilePosixPermissions: @0755,
                           NSFileOwnerAccountID: @(uid),
                           NSFileGroupOwnerAccountID: @(gid)
                       }
                            error:&error];
        if (error) {
            fprintf(stderr, "Warning: Failed to create home directory: %s\n",
                    [[error localizedDescription] UTF8String]);
        } else {
            printf("Created home directory: %s\n", [homeDir UTF8String]);
        }
    }

    printf("User created: %s (uid=%d, gid=%d)\n", [username UTF8String], uid, gid);
    printf("Run 'dscli passwd %s' to set password.\n", [username UTF8String]);

    return 0;
}

static int cmdUserDelete(NSString *username) {
    NSMutableDictionary *users = loadPlist(getUsersPlistPath());

    if (!users[username]) {
        fprintf(stderr, "User not found: %s\n", [username UTF8String]);
        return 1;
    }

    [users removeObjectForKey:username];

    if (!savePlist(users, getUsersPlistPath())) {
        return 1;
    }

    // Remove from all groups
    NSMutableDictionary *groups = loadPlist(getGroupsPlistPath());
    BOOL groupsModified = NO;

    for (NSString *groupname in [groups allKeys]) {
        NSMutableDictionary *group = [groups[groupname] mutableCopy];
        NSMutableArray *members = [group[@"members"] mutableCopy];
        if (members && [members containsObject:username]) {
            [members removeObject:username];
            group[@"members"] = members;
            groups[groupname] = group;
            groupsModified = YES;
        }
    }

    if (groupsModified) {
        savePlist(groups, getGroupsPlistPath());
    }

    printf("User deleted: %s\n", [username UTF8String]);
    printf("Note: Home directory was not removed.\n");

    return 0;
}

static int cmdUserPasswd(NSString *username) {
    NSMutableDictionary *users = loadPlist(getUsersPlistPath());
    NSMutableDictionary *user = [users[username] mutableCopy];

    if (!user) {
        fprintf(stderr, "User not found: %s\n", [username UTF8String]);
        return 1;
    }

    NSString *pass1 = readPassword("New password: ");
    if (!pass1 || [pass1 length] == 0) {
        fprintf(stderr, "Password cannot be empty.\n");
        return 1;
    }

    NSString *pass2 = readPassword("Confirm password: ");
    if (![pass1 isEqualToString:pass2]) {
        fprintf(stderr, "Passwords do not match.\n");
        return 1;
    }

    NSString *hash = hashPassword(pass1);
    if (!hash) {
        fprintf(stderr, "Failed to hash password.\n");
        return 1;
    }

    user[@"passwordHash"] = hash;
    users[username] = user;

    if (!savePlist(users, getUsersPlistPath())) {
        return 1;
    }

    printf("Password set for user: %s\n", [username UTF8String]);
    return 0;
}

static int cmdUserEdit(NSArray *args) {
    if ([args count] < 1) {
        fprintf(stderr, "Usage: dscli user edit <username> [options]\n");
        return 1;
    }

    NSString *username = args[0];
    NSMutableDictionary *users = loadPlist(getUsersPlistPath());
    NSMutableDictionary *user = [users[username] mutableCopy];

    if (!user) {
        fprintf(stderr, "User not found: %s\n", [username UTF8String]);
        return 1;
    }

    BOOL modified = NO;

    for (NSUInteger i = 1; i < [args count]; i++) {
        NSString *arg = args[i];
        if ([arg isEqualToString:@"--uid"] && i + 1 < [args count]) {
            user[@"uid"] = @([args[++i] intValue]);
            modified = YES;
        } else if ([arg isEqualToString:@"--gid"] && i + 1 < [args count]) {
            user[@"gid"] = @([args[++i] intValue]);
            modified = YES;
        } else if ([arg isEqualToString:@"--realname"] && i + 1 < [args count]) {
            user[@"realName"] = args[++i];
            modified = YES;
        } else if ([arg isEqualToString:@"--shell"] && i + 1 < [args count]) {
            user[@"shell"] = args[++i];
            modified = YES;
        }
    }

    if (!modified) {
        fprintf(stderr, "No changes specified.\n");
        return 1;
    }

    users[username] = user;

    if (!savePlist(users, getUsersPlistPath())) {
        return 1;
    }

    printf("User modified: %s\n", [username UTF8String]);
    return 0;
}

#pragma mark - Group Commands

static int cmdGroupList(void) {
    NSDictionary *groups = loadPlist(getGroupsPlistPath());

    if ([groups count] == 0) {
        printf("No groups defined.\n");
        return 0;
    }

    printf("%-20s %-6s %s\n", "GROUPNAME", "GID", "MEMBERS");
    printf("%-20s %-6s %s\n", "---------", "---", "-------");

    // Sort by GID
    NSArray *sortedKeys = [[groups allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger gidA = [groups[a][@"gid"] integerValue];
        NSInteger gidB = [groups[b][@"gid"] integerValue];
        if (gidA < gidB) return NSOrderedAscending;
        if (gidA > gidB) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    for (NSString *groupname in sortedKeys) {
        NSDictionary *group = groups[groupname];
        NSArray *members = group[@"members"] ?: @[];
        printf("%-20s %-6d %s\n",
               [groupname UTF8String],
               [group[@"gid"] intValue],
               [[members componentsJoinedByString:@","] UTF8String]);
    }

    return 0;
}

static int cmdGroupShow(NSString *groupname) {
    NSDictionary *groups = loadPlist(getGroupsPlistPath());
    NSDictionary *group = groups[groupname];

    if (!group) {
        fprintf(stderr, "Group not found: %s\n", [groupname UTF8String]);
        return 1;
    }

    printf("Group Name: %s\n", [group[@"groupname"] UTF8String]);
    printf("GID:        %d\n", [group[@"gid"] intValue]);

    NSArray *members = group[@"members"] ?: @[];
    if ([members count] > 0) {
        printf("Members:    %s\n", [[members componentsJoinedByString:@", "] UTF8String]);
    } else {
        printf("Members:    (none)\n");
    }

    return 0;
}

static int cmdGroupAdd(NSArray *args) {
    if ([args count] < 1) {
        fprintf(stderr, "Usage: dscli group add <groupname> [--gid <gid>]\n");
        return 1;
    }

    NSString *groupname = args[0];
    NSMutableDictionary *groups = loadPlist(getGroupsPlistPath());

    if (groups[groupname]) {
        fprintf(stderr, "Group already exists: %s\n", [groupname UTF8String]);
        return 1;
    }

    gid_t gid = 0;
    for (NSUInteger i = 1; i < [args count]; i++) {
        NSString *arg = args[i];
        if ([arg isEqualToString:@"--gid"] && i + 1 < [args count]) {
            gid = [args[++i] intValue];
        }
    }

    if (gid == 0) {
        gid = findNextGID(groups);
    }

    NSMutableDictionary *group = [NSMutableDictionary dictionary];
    group[@"groupname"] = groupname;
    group[@"gid"] = @(gid);

    groups[groupname] = group;

    if (!savePlist(groups, getGroupsPlistPath())) {
        return 1;
    }

    printf("Group created: %s (gid=%d)\n", [groupname UTF8String], gid);
    return 0;
}

static int cmdGroupDelete(NSString *groupname) {
    NSMutableDictionary *groups = loadPlist(getGroupsPlistPath());

    if (!groups[groupname]) {
        fprintf(stderr, "Group not found: %s\n", [groupname UTF8String]);
        return 1;
    }

    // Prevent deleting admin group
    if ([groupname isEqualToString:@"admin"]) {
        fprintf(stderr, "Cannot delete the admin group.\n");
        return 1;
    }

    [groups removeObjectForKey:groupname];

    if (!savePlist(groups, getGroupsPlistPath())) {
        return 1;
    }

    printf("Group deleted: %s\n", [groupname UTF8String]);
    return 0;
}

static int cmdGroupAddMember(NSString *groupname, NSString *username) {
    NSMutableDictionary *groups = loadPlist(getGroupsPlistPath());
    NSMutableDictionary *group = [groups[groupname] mutableCopy];

    if (!group) {
        fprintf(stderr, "Group not found: %s\n", [groupname UTF8String]);
        return 1;
    }

    // Verify user exists
    NSDictionary *users = loadPlist(getUsersPlistPath());
    if (!users[username]) {
        fprintf(stderr, "User not found: %s\n", [username UTF8String]);
        return 1;
    }

    NSMutableArray *members = [group[@"members"] mutableCopy] ?: [NSMutableArray array];
    if ([members containsObject:username]) {
        fprintf(stderr, "User %s is already a member of %s\n",
                [username UTF8String], [groupname UTF8String]);
        return 1;
    }

    [members addObject:username];
    group[@"members"] = members;
    groups[groupname] = group;

    if (!savePlist(groups, getGroupsPlistPath())) {
        return 1;
    }

    printf("Added %s to group %s\n", [username UTF8String], [groupname UTF8String]);
    return 0;
}

static int cmdGroupRemoveMember(NSString *groupname, NSString *username) {
    NSMutableDictionary *groups = loadPlist(getGroupsPlistPath());
    NSMutableDictionary *group = [groups[groupname] mutableCopy];

    if (!group) {
        fprintf(stderr, "Group not found: %s\n", [groupname UTF8String]);
        return 1;
    }

    NSMutableArray *members = [group[@"members"] mutableCopy];
    if (!members || ![members containsObject:username]) {
        fprintf(stderr, "User %s is not a member of %s\n",
                [username UTF8String], [groupname UTF8String]);
        return 1;
    }

    [members removeObject:username];
    group[@"members"] = members;
    groups[groupname] = group;

    if (!savePlist(groups, getGroupsPlistPath())) {
        return 1;
    }

    printf("Removed %s from group %s\n", [username UTF8String], [groupname UTF8String]);
    return 0;
}

#pragma mark - Other Commands

static int cmdVerify(NSString *username) {
    NSDictionary *users = loadPlist(getUsersPlistPath());
    NSDictionary *user = users[username];

    if (!user) {
        fprintf(stderr, "User not found: %s\n", [username UTF8String]);
        return 1;
    }

    NSString *storedHash = user[@"passwordHash"];
    if (!storedHash) {
        fprintf(stderr, "User has no password set.\n");
        return 1;
    }

    NSString *password = readPassword("Password: ");
    if (!password) {
        return 1;
    }

    char *computed = crypt([password UTF8String], [storedHash UTF8String]);
    if (computed && strcmp(computed, [storedHash UTF8String]) == 0) {
        printf("Authentication successful.\n");
        return 0;
    } else {
        printf("Authentication failed.\n");
        return 1;
    }
}

static void configureNsswitch(void) {
    NSString *path = @"/etc/nsswitch.conf";
    NSError *error = nil;

    NSString *contents = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];
    if (!contents) {
        fprintf(stderr, "Warning: Could not read %s: %s\n",
                [path UTF8String], [[error localizedDescription] UTF8String]);
        return;
    }

    NSMutableArray *lines = [[contents componentsSeparatedByString:@"\n"] mutableCopy];
    BOOL modified = NO;

    for (NSUInteger i = 0; i < [lines count]; i++) {
        NSString *line = lines[i];
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]];

        // Skip comments
        if ([trimmed hasPrefix:@"#"]) continue;

        // Check for passwd: or group: lines
        if ([trimmed hasPrefix:@"passwd:"]) {
            if (![trimmed isEqualToString:@"passwd: gershwin files"]) {
                printf("nsswitch.conf: %s -> passwd: gershwin files\n", [trimmed UTF8String]);
                lines[i] = @"passwd: gershwin files";
                modified = YES;
            }
        } else if ([trimmed hasPrefix:@"group:"] && ![trimmed hasPrefix:@"group_compat"]) {
            if (![trimmed isEqualToString:@"group: gershwin files"]) {
                printf("nsswitch.conf: %s -> group: gershwin files\n", [trimmed UTF8String]);
                lines[i] = @"group: gershwin files";
                modified = YES;
            }
        }
    }

    if (modified) {
        NSString *newContents = [lines componentsJoinedByString:@"\n"];
        [newContents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (error) {
            fprintf(stderr, "Warning: Could not write %s: %s\n",
                    [path UTF8String], [[error localizedDescription] UTF8String]);
        }
    }
}

static int cmdInit(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;

    // Create directories
    NSArray *dirs = @[
        @"/Local/Library/DirectoryServices",
        @"/Local/Users"
    ];

    for (NSString *dir in dirs) {
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir
          withIntermediateDirectories:YES
                           attributes:@{NSFilePosixPermissions: @0755}
                                error:&error];
            if (error) {
                fprintf(stderr, "Failed to create %s: %s\n",
                        [dir UTF8String], [[error localizedDescription] UTF8String]);
                return 1;
            }
            printf("Created: %s\n", [dir UTF8String]);
        }
    }

    // Create empty plists if they don't exist
    if (![fm fileExistsAtPath:DS_LOCAL_USERS_PLIST]) {
        savePlist(@{}, DS_LOCAL_USERS_PLIST);
        printf("Created: %s\n", [DS_LOCAL_USERS_PLIST UTF8String]);
    }

    if (![fm fileExistsAtPath:DS_LOCAL_GROUPS_PLIST]) {
        // Create with admin group
        NSDictionary *groups = @{
            @"admin": @{
                @"groupname": @"admin",
                @"gid": @5000
            }
        };
        savePlist(groups, DS_LOCAL_GROUPS_PLIST);
        printf("Created: %s\n", [DS_LOCAL_GROUPS_PLIST UTF8String]);
    }

    // Configure nsswitch.conf
    configureNsswitch();

    printf("Directory Services initialized.\n");
    return 0;
}

static int cmdPromote(void) {
    id<DSPlatform> platform = DSPlatformCreate();
    if (!platform) {
        fprintf(stderr, "No platform backend available\n");
        return 1;
    }

    if (![platform isAvailable]) {
        fprintf(stderr, "The 'promote' command is not yet supported on %s.\n",
                [[platform platformName] UTF8String]);
        fprintf(stderr, "Please follow the manual NFS configuration steps in the README.\n");
        return 1;
    }

    NSFileManager *fm = [NSFileManager defaultManager];

    // Check if already a server
    if ([fm fileExistsAtPath:DS_DOMAIN_PLIST]) {
        fprintf(stderr, "This machine is already a directory server.\n");
        return 1;
    }

    // Check if /Local/Library/DirectoryServices exists
    if (![fm fileExistsAtPath:@"/Local/Library/DirectoryServices"]) {
        fprintf(stderr, "Directory Services not initialized. Run 'dscli init' first.\n");
        return 1;
    }

    // Check if another server is already on the network
    NSString *existingServer = [platform discoverDirectoryServer];
    if (existingServer) {
        fprintf(stderr, "A directory server already exists: %s\n", [existingServer UTF8String]);
        fprintf(stderr, "Only one directory server is allowed per network.\n");
        return 1;
    }

    printf("Promoting to directory server...\n\n");

    // Configure NFS exports
    if (![platform configureNFSExports]) {
        return 1;
    }

    // Enable NFS services
    if (![platform enableNFSServer]) {
        return 1;
    }

    // Start NFS services
    if (![platform startNFSServer]) {
        return 1;
    }

    // Create Domain.plist to mark as server
    if (![@{} writeToFile:DS_DOMAIN_PLIST atomically:YES]) {
        fprintf(stderr, "Failed to create Domain.plist\n");
        return 1;
    }
    printf("Created Domain.plist\n");

    // Restart dshelper so it registers with gdomap
    [platform restartDSHelper];

    printf("\nServer promotion complete.\n");
    printf("Clients can now join with: dscli join\n");
    return 0;
}

static int cmdDemote(void) {
    id<DSPlatform> platform = DSPlatformCreate();
    if (!platform) {
        fprintf(stderr, "No platform backend available\n");
        return 1;
    }

    if (![platform isAvailable]) {
        fprintf(stderr, "The 'demote' command is not yet supported on %s.\n",
                [[platform platformName] UTF8String]);
        return 1;
    }

    NSFileManager *fm = [NSFileManager defaultManager];

    // Check if we're a server
    if (![fm fileExistsAtPath:DS_DOMAIN_PLIST]) {
        fprintf(stderr, "This machine is not a directory server.\n");
        return 1;
    }

    // Check if any clients are still connected by looking at NFS exports
    // We check if showmount shows any connected clients (skip header line with tail -n +2)
    FILE *fp = popen("showmount -a 2>/dev/null | tail -n +2 | grep -v '^$' | wc -l", "r");
    if (fp) {
        char buf[64];
        if (fgets(buf, sizeof(buf), fp)) {
            int clientCount = atoi(buf);
            if (clientCount > 0) {
                fprintf(stderr, "Cannot demote: %d client(s) still connected.\n", clientCount);
                fprintf(stderr, "All clients must run 'dscli leave' before demoting.\n");
                pclose(fp);
                return 1;
            }
        }
        pclose(fp);
    }

    printf("Demoting directory server...\n\n");

    // Remove Domain.plist first (stops dshelper from advertising)
    if ([fm removeItemAtPath:DS_DOMAIN_PLIST error:nil]) {
        printf("Removed Domain.plist\n");
    }

    // Unregister service from gdomap (so clients can't discover us)
    [platform unregisterService];

    // Stop NFS server
    [platform stopNFSServer];

    // Remove NFS exports
    [platform removeNFSExports];

    printf("\nServer demotion complete.\n");
    return 0;
}

static int cmdJoin(NSString *server) {
    id<DSPlatform> platform = DSPlatformCreate();
    if (!platform) {
        fprintf(stderr, "No platform backend available\n");
        return 1;
    }

    if (![platform isAvailable]) {
        fprintf(stderr, "The 'join' command is not yet supported on %s.\n",
                [[platform platformName] UTF8String]);
        fprintf(stderr, "Please follow the manual NFS configuration steps in the README.\n");
        return 1;
    }

    NSFileManager *fm = [NSFileManager defaultManager];

    // Check if already a server
    if ([fm fileExistsAtPath:DS_DOMAIN_PLIST]) {
        fprintf(stderr, "This machine is a directory server. Cannot join another server.\n");
        return 1;
    }

    // Check if /Network is already mounted
    if ([fm fileExistsAtPath:@"/Network/Library/DirectoryServices"]) {
        fprintf(stderr, "Already joined to a directory server.\n");
        return 1;
    }

    // If no server specified, try to discover one
    if (!server) {
        server = [platform discoverDirectoryServer];
        if (!server) {
            fprintf(stderr, "No directory server found on network.\n");
            return 1;
        }
    }

    printf("Joining directory server: %s\n\n", [server UTF8String]);

    // Enable NFS client
    if (![platform enableNFSClient]) {
        return 1;
    }

    // Start NFS client
    if (![platform startNFSClient]) {
        return 1;
    }

    // Create /Network mount point
    if (![platform createNetworkMount:server]) {
        return 1;
    }

    // Add fstab entry
    if (![platform addFstabEntry:server]) {
        return 1;
    }

    // Mount /Network
    if (![platform mountNetwork]) {
        return 1;
    }

    // Verify the mount has DirectoryServices
    if (![fm fileExistsAtPath:@"/Network/Library/DirectoryServices"]) {
        fprintf(stderr, "\nWarning: /Network/Library/DirectoryServices not found.\n");
        fprintf(stderr, "Verify the server has been promoted with 'dscli promote'.\n");
        return 1;
    }

    printf("\nJoin complete. Start dshelper to enable directory users.\n");
    return 0;
}

static int cmdLeave(void) {
    id<DSPlatform> platform = DSPlatformCreate();
    if (!platform) {
        fprintf(stderr, "No platform backend available\n");
        return 1;
    }

    if (![platform isAvailable]) {
        fprintf(stderr, "The 'leave' command is not yet supported on %s.\n",
                [[platform platformName] UTF8String]);
        return 1;
    }

    NSFileManager *fm = [NSFileManager defaultManager];

    // Check if we're a client
    if (![fm fileExistsAtPath:@"/Network"]) {
        fprintf(stderr, "This machine is not joined to a directory server.\n");
        return 1;
    }

    printf("Leaving directory server...\n\n");

    // Unmount /Network
    if (![platform unmountNetwork]) {
        return 1;
    }

    // Remove fstab entry
    if (![platform removeFstabEntry]) {
        return 1;
    }

    printf("\nLeave complete.\n");
    return 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            printUsage(argv[0]);
            return 1;
        }

        // Check for root
        if (getuid() != 0) {
            fprintf(stderr, "dscli: Must run as root\n");
            return 1;
        }

        NSMutableArray *args = [NSMutableArray array];
        for (int i = 1; i < argc; i++) {
            [args addObject:[NSString stringWithUTF8String:argv[i]]];
        }

        NSString *command = args[0];

        // Handle "passwd" as alias for "user passwd"
        if ([command isEqualToString:@"passwd"]) {
            if ([args count] < 2) {
                fprintf(stderr, "Usage: dscli passwd <username>\n");
                return 1;
            }
            return cmdUserPasswd(args[1]);
        }

        // Handle "verify"
        if ([command isEqualToString:@"verify"]) {
            if ([args count] < 2) {
                fprintf(stderr, "Usage: dscli verify <username>\n");
                return 1;
            }
            return cmdVerify(args[1]);
        }

        // Handle "list"
        if ([command isEqualToString:@"list"]) {
            return cmdList();
        }

        // Handle "init"
        if ([command isEqualToString:@"init"]) {
            return cmdInit();
        }

        // Handle "promote"
        if ([command isEqualToString:@"promote"]) {
            return cmdPromote();
        }

        // Handle "demote"
        if ([command isEqualToString:@"demote"]) {
            return cmdDemote();
        }

        // Handle "join"
        if ([command isEqualToString:@"join"]) {
            NSString *server = ([args count] >= 2) ? args[1] : nil;
            return cmdJoin(server);
        }

        // Handle "leave"
        if ([command isEqualToString:@"leave"]) {
            return cmdLeave();
        }

        // Handle "user" commands
        if ([command isEqualToString:@"user"]) {
            if ([args count] < 2) {
                fprintf(stderr, "Usage: dscli user <command> [options]\n");
                return 1;
            }

            NSString *subcommand = args[1];

            if ([subcommand isEqualToString:@"list"]) {
                return cmdUserList();
            } else if ([subcommand isEqualToString:@"show"]) {
                if ([args count] < 3) {
                    fprintf(stderr, "Usage: dscli user show <username>\n");
                    return 1;
                }
                return cmdUserShow(args[2]);
            } else if ([subcommand isEqualToString:@"add"]) {
                return cmdUserAdd([args subarrayWithRange:NSMakeRange(2, [args count] - 2)]);
            } else if ([subcommand isEqualToString:@"delete"]) {
                if ([args count] < 3) {
                    fprintf(stderr, "Usage: dscli user delete <username>\n");
                    return 1;
                }
                return cmdUserDelete(args[2]);
            } else if ([subcommand isEqualToString:@"passwd"]) {
                if ([args count] < 3) {
                    fprintf(stderr, "Usage: dscli user passwd <username>\n");
                    return 1;
                }
                return cmdUserPasswd(args[2]);
            } else if ([subcommand isEqualToString:@"edit"]) {
                return cmdUserEdit([args subarrayWithRange:NSMakeRange(2, [args count] - 2)]);
            } else {
                fprintf(stderr, "Unknown user command: %s\n", [subcommand UTF8String]);
                return 1;
            }
        }

        // Handle "group" commands
        if ([command isEqualToString:@"group"]) {
            if ([args count] < 2) {
                fprintf(stderr, "Usage: dscli group <command> [options]\n");
                return 1;
            }

            NSString *subcommand = args[1];

            if ([subcommand isEqualToString:@"list"]) {
                return cmdGroupList();
            } else if ([subcommand isEqualToString:@"show"]) {
                if ([args count] < 3) {
                    fprintf(stderr, "Usage: dscli group show <groupname>\n");
                    return 1;
                }
                return cmdGroupShow(args[2]);
            } else if ([subcommand isEqualToString:@"add"]) {
                return cmdGroupAdd([args subarrayWithRange:NSMakeRange(2, [args count] - 2)]);
            } else if ([subcommand isEqualToString:@"delete"]) {
                if ([args count] < 3) {
                    fprintf(stderr, "Usage: dscli group delete <groupname>\n");
                    return 1;
                }
                return cmdGroupDelete(args[2]);
            } else if ([subcommand isEqualToString:@"addmember"]) {
                if ([args count] < 4) {
                    fprintf(stderr, "Usage: dscli group addmember <group> <user>\n");
                    return 1;
                }
                return cmdGroupAddMember(args[2], args[3]);
            } else if ([subcommand isEqualToString:@"removemember"]) {
                if ([args count] < 4) {
                    fprintf(stderr, "Usage: dscli group removemember <group> <user>\n");
                    return 1;
                }
                return cmdGroupRemoveMember(args[2], args[3]);
            } else {
                fprintf(stderr, "Unknown group command: %s\n", [subcommand UTF8String]);
                return 1;
            }
        }

        fprintf(stderr, "Unknown command: %s\n", [command UTF8String]);
        printUsage(argv[0]);
        return 1;
    }
}

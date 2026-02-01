# Gershwin Directory Services

NSS module and helper daemon for managing users and groups via plist files.

## Components

- **dshelper** - Directory helper daemon (`/System/Library/Tools/dshelper`)
- **dscli** - User and group management CLI (`/System/Library/Tools/dscli`)
- **nss_gershwin** - NSS module (`/System/Library/Libraries/nss_gershwin.so.1`)

## Building

```sh
. /System/Library/Makefiles/GNUstep.sh
gmake
sudo -E gmake install
```

## Enabling the Service

To start dshelper automatically at boot:

| Platform | Enable | Start |
|----------|--------|-------|
| FreeBSD | `sudo sysrc dshelper_enable=YES` | `sudo service dshelper start` |
| Linux (sysvinit) | `sudo update-rc.d dshelper defaults` | `sudo service dshelper start` |
| Linux (systemd) | `sudo systemctl enable gdomap dshelper` | `sudo systemctl start gdomap dshelper` |

The service runs before the login manager, ensuring directory users can log in.

**Note:** The dshelper service requires **gdomap** (GNUstep Distributed Objects name server) for network service discovery. On FreeBSD and Linux sysvinit, gdomap is bundled with the dshelper service and starts/stops automatically. On Linux systemd, gdomap runs as a separate service unit—enable both as shown above.

## Quick Start

```sh
sudo dscli init
sudo dscli user add jsmith --realname "John Smith" --admin
sudo dscli passwd jsmith
sudo dshelper

# Verify
getent passwd jsmith
id jsmith
```

## Server Setup

To share users with clients over NFS:

```sh
# Complete quick start first, then:
sudo dscli promote

# Verify
showmount -e localhost
```

This configures NFS exports, starts NFS services, creates `Domain.plist`, and restarts dshelper. When dshelper starts on a server (where `Domain.plist` exists), it registers the `GershwinDirectory` service with gdomap for client auto-discovery.

Only one directory server is allowed per network. The promote command checks for existing servers and prevents duplicates.

## Client Setup

To use users from a directory server:

```sh
sudo dscli init
sudo dscli join
sudo dshelper

# Verify
getent passwd jsmith
```

The `join` command auto-discovers directory servers on the network.

## Managing Users from Clients

Since the user database is shared over NFS, admin users can manage accounts from any client machine:

```sh
sudo dscli user add newuser --realname "New User" --admin
sudo dscli passwd newuser
sudo dscli user delete olduser
```

Changes are written directly to the server's plist files via the NFS mount and take effect immediately across all machines.

## Leaving the Directory

To disconnect from a directory server:

```sh
sudo dscli leave
```

This unmounts `/Network` and removes the server entry from `/etc/fstab`.

If a directory server goes offline permanently, all clients must run `dscli leave` before a new server can be promoted.

## Demoting the Server

To stop being a directory server:

```sh
sudo dscli demote
```

This unregisters the service from gdomap (so clients can no longer discover it), removes `Domain.plist`, stops NFS services, and removes `/Local` from NFS exports.

All clients must run `dscli leave` before a server can be demoted.

## dscli Reference

### User Commands

```sh
dscli user list                     # List all users
dscli user show <username>          # Show user details
dscli user add <username> [options] # Add a new user
dscli user delete <username>        # Delete a user
dscli user passwd <username>        # Set user password
dscli user edit <username> [options] # Modify user attributes
```

Options for `user add` and `user edit`:
```
--uid <uid>           User ID (auto-assigned if omitted)
--gid <gid>           Primary group ID (auto-assigned if omitted)
--realname <name>     Real name / GECOS field
--shell <shell>       Login shell (default: /bin/sh)
--admin               Add user to admin group
```

### Group Commands

```sh
dscli group list                        # List all groups
dscli group show <groupname>            # Show group details
dscli group add <groupname> [--gid N]   # Add a new group
dscli group delete <groupname>          # Delete a group
dscli group addmember <group> <user>    # Add user to group
dscli group removemember <group> <user> # Remove user from group
```

### Other Commands

```sh
dscli list              # List all users, groups, and status
dscli init              # Initialize directory structure
dscli promote           # Promote to directory server
dscli demote            # Demote from directory server
dscli join              # Join a directory (auto-discovers)
dscli leave             # Leave a directory
dscli passwd <username> # Set password (alias for user passwd)
dscli verify <username> # Verify user can authenticate
```

The `list` command provides a comprehensive overview:
- **Role**: Server, Client, or Standalone
- **Connected Clients**: (on server) machines with active NFS mounts
- **Connected Server**: (on client) which server this machine is joined to
- **Users**: All users sorted by UID
- **Groups**: All groups sorted by GID

## dshelper Reference

```sh
dshelper      # Run as daemon (background)
dshelper -d   # Run in foreground (debug mode)
```

## How It Works

### Data Files

dshelper checks for plists in this order:
1. `/Network/Library/DirectoryServices/` (client with server mounted)
2. `/Local/Library/DirectoryServices/` (server or standalone)

### Machine Roles

| Machine | /Network mounted? | Domain.plist exists? | dshelper reads from |
|---------|-------------------|---------------------|---------------------|
| Server | No | Yes | /Local |
| Client | Yes | No | /Network |
| Standalone | No | No | /Local |

## Service Discovery

Directory servers are discovered automatically using GNUstep's network services API.

### Server Registration

When dshelper starts on a server (where `Domain.plist` exists), it registers itself with the network portmapper:

```objc
NSSocketPortNameServer *ns = [NSSocketPortNameServer sharedInstance];
NSSocketPort *port = [NSSocketPort portWithNumber:4721
                                           onHost:nil
                                     forceAddress:nil
                                         listener:YES];
[ns registerPort:port forName:@"GershwinDirectory"];
```

- **NSSocketPortNameServer** provides network-wide name registration via the system's `rpcbind` service
- **NSSocketPort** creates a TCP listener socket on port 4721
- `registerPort:forName:` binds the name "GershwinDirectory" to this port across the network

### Client Discovery

When a client runs `dscli join`, it searches for registered servers:

```objc
NSSocketPortNameServer *ns = [NSSocketPortNameServer sharedInstance];
NSPort *port = [ns portForName:@"GershwinDirectory" onHost:@"*"];
```

- `portForName:onHost:` with host `@"*"` broadcasts a lookup across the local network
- Returns the port registered by the server, or nil if no server is found

### Getting the Server Hostname

Once discovered, the server's address is resolved to a hostname:

```objc
NSSocketPort *socketPort = (NSSocketPort *)port;
NSString *address = [socketPort address];  // IP address string
NSHost *remoteHost = [NSHost hostWithAddress:address];
NSString *hostname = [remoteHost name];    // DNS hostname
```

- **NSSocketPort** `-address` returns the server's IP address as a string
- **NSHost** `-hostWithAddress:` creates a host object from an IP
- **NSHost** `-name` performs reverse DNS lookup to get the hostname

This allows clients to discover and connect to directory servers without manual configuration.

## Authentication

Directory Services uses plist files instead of traditional Unix configuration files (`/etc/passwd`, `/etc/group`, `/etc/shadow`). This separation keeps directory-managed users distinct from local system accounts.

On the server, user and group plists are stored in `/Local/Library/DirectoryServices/`. When clients join the directory, the server's `/Local` is NFS-mounted at `/Network` on the client. The dshelper daemon reads from `/Network/Library/DirectoryServices/` when the mount is present, giving clients access to the same user database as the server.

The **nss_gershwin** NSS module integrates with the system's name service switch. When configured in `/etc/nsswitch.conf`:

```
passwd: gershwin files
group:  gershwin files
```

The system queries dshelper for directory users first, then falls back to local files (`/etc/passwd`, `/etc/group`). This allows directory accounts to take precedence while still supporting local system accounts.

Authentication works through standard `pam_unix`. The daemon returns password hashes only to root callers (verified via `getpeereid`), matching FreeBSD's `/etc/master.passwd` security model. No PAM configuration changes are required—pam_unix automatically uses NSS to resolve users, so directory users authenticate seamlessly.

## Admin Access

Members of the `admin` group (gid 5000) are automatically nested into `wheel` and `sudo` groups if they exist on the system. This enables `su` access on FreeBSD (wheel) and sudo access on Linux (sudo group).

For explicit control, add to sudoers:

```
# FreeBSD: /usr/local/etc/sudoers.d/gershwin
# Linux:   /etc/sudoers.d/gershwin
%admin ALL = (ALL) ALL
```

## Plist Fields

### User Fields

| Field | Required | Description |
|-------|----------|-------------|
| username | yes | Login name |
| uid | yes | User ID |
| gid | yes | Primary group ID |
| realName | no | GECOS field |
| shell | no | Login shell (default: /usr/sbin/nologin) |
| passwordHash | yes* | SHA-512 hash (*for login) |

Home directory is derived automatically: `/Local/Users/<username>` on server, `/Network/Users/<username>` on client.

### Group Fields

| Field | Required | Description |
|-------|----------|-------------|
| groupname | yes | Group name |
| gid | yes | Group ID |
| members | no | Array of usernames |

## Troubleshooting

Run dshelper in foreground mode to see debug output:

```sh
sudo dshelper -d
# Look for "Loaded N users from /path" in output
```

Test NSS lookups:

```sh
getent passwd testuser
id testuser
```

Direct socket query (as root to see password hash):

```sh
sudo sh -c 'echo "getpwnam:testuser" | nc -U /var/run/dshelper.sock'
```

## Developer Guide

### Platform Backends

The `dscli promote`, `demote`, `join`, and `leave` commands use platform-specific backends to configure NFS and network mounts. Backends are defined in `dscli/` with a protocol and per-platform implementations.

**DSPlatform.h** defines the protocol:

```objc
@protocol DSPlatform <NSObject>
- (NSString *)platformName;
- (BOOL)isAvailable;

// Server (promote) operations
- (BOOL)configureNFSExports;
- (BOOL)enableNFSServer;
- (BOOL)startNFSServer;
- (BOOL)restartDSHelper;

// Server (demote) operations
- (BOOL)removeNFSExports;
- (BOOL)stopNFSServer;
- (BOOL)unregisterService;

// Client (join) operations
- (BOOL)enableNFSClient;
- (BOOL)startNFSClient;
- (BOOL)createNetworkMount:(NSString *)server;
- (BOOL)addFstabEntry:(NSString *)server;
- (BOOL)mountNetwork;

// Client (leave) operations
- (BOOL)unmountNetwork;
- (BOOL)removeFstabEntry;

// Discovery
- (NSString *)discoverDirectoryServer;
@end
```

**Current implementations:**

| File | Platform | Status |
|------|----------|--------|
| DSPlatformFreeBSD.m | FreeBSD | Complete |
| DSPlatformLinux.m | Linux | Stub |

The factory function `DSPlatformCreate()` returns the appropriate backend based on compile-time platform detection.

**Note:** On Linux, only standalone mode is currently supported. The `promote`, `demote`, `join`, and `leave` commands will fail until the Linux backend is completed. Linux users can still use `dscli init` and manage local users/groups via plist files.

### Adding a New Backend

1. Create `DSPlatform<Name>.m` implementing the `DSPlatform` protocol
2. Update `DSPlatform.m` to return your backend for the appropriate platform
3. Implement all required methods for NFS server/client configuration

Example for a new platform:

```objc
// DSPlatformNetBSD.m
#import "DSPlatform.h"

@interface DSPlatformNetBSD : NSObject <DSPlatform>
@end

@implementation DSPlatformNetBSD

- (NSString *)platformName { return @"NetBSD"; }
- (BOOL)isAvailable { return YES; }

- (BOOL)configureNFSExports {
    // Add /Local to /etc/exports
    // NetBSD-specific format
}

// ... implement remaining methods

@end
```

### Completing the Linux Backend

The Linux backend in `DSPlatformLinux.m` is currently a stub. To complete it:

1. Implement `configureNFSExports` to write `/etc/exports` (Linux format)
2. Implement `enableNFSServer`/`startNFSServer` using systemctl or service commands
3. Implement `addFstabEntry` with Linux NFS mount options
4. Test on both systemd and sysvinit systems

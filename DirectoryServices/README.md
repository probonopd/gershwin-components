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
dscli init              # Initialize directory structure
dscli promote           # Promote to directory server
dscli join              # Join a directory server (auto-discovers)
dscli passwd <username> # Set password (alias for user passwd)
dscli verify <username> # Verify user can authenticate
```

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

### What dscli init Does

1. Creates `/Local/Library/DirectoryServices/` directory
2. Creates `/Local/Users/` directory for home directories
3. Creates empty `Users.plist` and `Groups.plist` (with admin group gid 5000)
4. Configures `/etc/nsswitch.conf` to use `gershwin files` for passwd and group

The `gershwin` module must come before `files` so that admin group members appear in the `wheel` group (required for `su`). If dshelper is not running, NSS falls back to `files` automatically.

### What dscli promote Does

1. Adds `/Local` to NFS exports
2. Enables and starts NFS server services (rpcbind, mountd, nfsd)
3. Creates `Domain.plist` to mark as server

### What dscli join Does

1. Auto-discovers directory server via `NSSocketPortNameServer` broadcast
2. Enables and starts NFS client services
3. Creates `/Network` mount point
4. Adds server to `/etc/fstab`
5. Mounts `/Network` from server

## Authentication

Authentication works through standard `pam_unix`. The daemon returns password hashes only to root callers (verified via `getpeereid`), matching FreeBSD's `/etc/master.passwd` security model.

No PAM configuration changes required.

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

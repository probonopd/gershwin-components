# Gershwin Directory Services

NSS module and helper daemon for managing users and groups via plist files.

## Components

- **dshelper** - Directory helper daemon (`/System/Library/Tools/dshelper`)
- **dscli** - User and group management CLI (`/System/Library/Tools/dscli`)
- **nss_gershwin** - NSS module (`/System/Library/Libraries/nss_gershwin.so.1`)

## Data Files

dshelper checks for plists in this order:
1. `/Network/Library/DirectoryServices/` (client with server mounted)
2. `/Local/Library/DirectoryServices/` (server or standalone)

## Building

```sh
. /System/Library/Makefiles/GNUstep.sh
gmake
sudo -E gmake install
```

## Quick Start

```sh
# Initialize directory structure
sudo dscli init

# Add a user
sudo dscli user add jsmith --realname "John Smith" --admin

# Set password
sudo dscli passwd jsmith

# Start the daemon
sudo dshelper

# Verify
getent passwd jsmith
id jsmith
```

## dscli Reference

### User Commands

```sh
# List all users
dscli user list

# Show user details
dscli user show <username>

# Add a new user
dscli user add <username> [options]
  --uid <uid>           User ID (auto-assigned if omitted)
  --gid <gid>           Primary group ID (auto-assigned if omitted)
  --realname <name>     Real name / GECOS field
  --shell <shell>       Login shell (default: /bin/sh)
  --admin               Add user to admin group

# Delete a user
dscli user delete <username>

# Set user password
dscli user passwd <username>
# or
dscli passwd <username>

# Modify user attributes
dscli user edit <username> [options]
  --realname <name>     Change real name
  --shell <shell>       Change shell
  --uid <uid>           Change UID
  --gid <gid>           Change primary GID
```

### Group Commands

```sh
# List all groups
dscli group list

# Show group details
dscli group show <groupname>

# Add a new group
dscli group add <groupname> [--gid <gid>]

# Delete a group
dscli group delete <groupname>

# Add user to group
dscli group addmember <groupname> <username>

# Remove user from group
dscli group removemember <groupname> <username>
```

### Server/Client Commands

```sh
# Promote to directory server (configures NFS exports)
dscli promote

# Join a directory server (configures NFS client mount)
dscli join <server>
```

Note: `promote` and `join` are currently only supported on FreeBSD.

### Other Commands

```sh
# Verify user can authenticate
dscli verify <username>

# Initialize directory structure and configure nsswitch.conf
dscli init
```

### Examples

```sh
# Create an admin user with all options
sudo dscli user add jsmith \
  --realname "John Smith" \
  --shell /bin/zsh \
  --admin
sudo dscli passwd jsmith

# Create a regular user
sudo dscli user add webdev --realname "Web Developer"
sudo dscli passwd webdev

# Create a group and add members
sudo dscli group add developers
sudo dscli group addmember developers jsmith
sudo dscli group addmember developers webdev

# Change user's shell
sudo dscli user edit jsmith --shell /usr/local/bin/bash

# Remove user from admin group
sudo dscli group removemember admin jsmith

# View user's group memberships
sudo dscli user show jsmith

# Delete a user
sudo dscli user delete webdev
```

## Standalone Setup

For a single machine with local users only.

### 1. Initialize and create users

```sh
sudo dscli init
sudo dscli user add testuser --realname "Test User" --admin
sudo dscli passwd testuser
```

### 2. Start dshelper

```sh
sudo dshelper
```

## Server Setup

A server stores users in `/Local` and exports via NFS for clients.

### FreeBSD

```sh
# Complete standalone setup first, then:
sudo dscli promote
```

This configures NFS exports, enables and starts NFS services, and creates `Domain.plist`.

### Linux (Manual)

On Linux, `dscli promote` is not yet supported. Configure manually:

1. Add to `/etc/exports`:
   ```
   /Local *(rw,sync,no_subtree_check,no_root_squash)
   ```

2. Enable and start NFS:
   ```sh
   sudo apt install nfs-kernel-server
   sudo systemctl enable nfs-kernel-server
   sudo systemctl start nfs-kernel-server
   sudo exportfs -ra
   ```

3. Mark as server:
   ```sh
   sudo touch /Local/Library/DirectoryServices/Domain.plist
   ```

### Verify

```sh
showmount -e localhost
```

## Client Setup

A client mounts `/Network` from the server and uses those users.

### FreeBSD

```sh
# Build and install, then:
sudo dscli init
sudo dscli join <server-hostname>
sudo dshelper
```

This configures NFS client, mounts `/Network`, and adds to `/etc/fstab`.

### Linux (Manual)

On Linux, `dscli join` is not yet supported. Configure manually:

1. Install NFS client:
   ```sh
   sudo apt install nfs-common
   ```

2. Mount the server:
   ```sh
   sudo mkdir -p /Network
   sudo mount -t nfs server:/Local /Network
   ```

3. Add to `/etc/fstab` for persistent mount:
   ```
   server:/Local    /Network    nfs    rw    0    0
   ```

4. Start dshelper:
   ```sh
   sudo dshelper
   ```

### Verify

```sh
getent passwd testuser
# Should show: testuser:*:5001:5001:Test User:/Network/Users/testuser:/bin/sh
```

## How It Works

### dscli init

The `dscli init` command prepares a machine to use Directory Services:

1. Creates `/Local/Library/DirectoryServices/` directory
2. Creates `/Local/Users/` directory for home directories
3. Creates empty `Users.plist` and `Groups.plist` (with admin group gid 5000)
4. Configures `/etc/nsswitch.conf` to use `gershwin files` for passwd and group

The `gershwin` module must come before `files` so that admin group members appear in the `wheel` group (required for `su`). If dshelper is not running, NSS falls back to `files` automatically.

### dscli promote

The `dscli promote` command configures a machine as a directory server:

1. Adds `/Local` to NFS exports
2. Enables and starts NFS server services (rpcbind, mountd, nfsd)
3. Creates `Domain.plist` to mark as server

### dscli join

The `dscli join <server>` command configures a machine as a directory client:

1. Enables and starts NFS client services
2. Creates `/Network` mount point
3. Adds server to `/etc/fstab`
4. Mounts `/Network` from server

### Machine Roles

| Machine | /Network mounted? | Domain.plist exists? | dshelper reads from |
|---------|-------------------|---------------------|---------------------|
| Server | No | Yes | /Local |
| Client | Yes | No | /Network |
| Standalone | No | No | /Local |

## Authentication

Authentication works through standard `pam_unix`. The daemon returns password hashes only to root callers (verified via `getpeereid`), matching FreeBSD's `/etc/master.passwd` security model.

No PAM configuration changes required.

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

## User Fields

| Field | Required | Description |
|-------|----------|-------------|
| username | yes | Login name |
| uid | yes | User ID |
| gid | yes | Primary group ID |
| realName | no | GECOS field |
| shell | no | Login shell (default: /usr/sbin/nologin) |
| passwordHash | yes* | SHA-512 hash (*for login) |

Home directory is derived automatically: `/Local/Users/<username>` on server, `/Network/Users/<username>` on client.

## Group Fields

| Field | Required | Description |
|-------|----------|-------------|
| groupname | yes | Group name |
| gid | yes | Group ID |
| members | no | Array of usernames |

## Admin Access

Members of the `admin` group (gid 5000) are automatically nested into `wheel` and `sudo` groups if they exist on the system. This enables `su` access on FreeBSD (wheel) and sudo access on Linux (sudo group).

For distributions without these groups, or for explicit control, add to sudoers:

```
# FreeBSD: /usr/local/etc/sudoers.d/gershwin
# Linux:   /etc/sudoers.d/gershwin
%admin ALL = (ALL) ALL
```

# Gershwin Directory Services

NSS module and helper daemon for managing users and groups via plist files.

## Components

- **gsdh** - Directory helper daemon (`/System/Library/Tools/gsdh`)
- **nss_gershwin** - NSS module (`/System/Library/Libraries/nss_gershwin.so.1`)

## Data Files

gsdh checks for plists in this order:
1. `/Network/Library/DirectoryServices/` (client with server mounted)
2. `/Local/Library/DirectoryServices/` (server or standalone)

## nsswitch.conf

Required on all machines (server, client, standalone):

```
passwd: files gershwin
group: files gershwin
```

## Building

```sh
. /System/Library/Makefiles/GNUstep.sh
gmake
sudo -E gmake install
```

## Standalone Setup

For a single machine with local users only.

### 1. Create Users.plist

```sh
sudo mkdir -p /Local/Library/DirectoryServices
```

`/Local/Library/DirectoryServices/Users.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>testuser</key>
    <dict>
        <key>username</key>
        <string>testuser</string>
        <key>uid</key>
        <integer>5001</integer>
        <key>gid</key>
        <integer>5001</integer>
        <key>realName</key>
        <string>Test User</string>
        <key>shell</key>
        <string>/bin/sh</string>
        <key>passwordHash</key>
        <string>$6$...</string>
    </dict>
</dict>
</plist>
```

Generate password hash:
```sh
openssl passwd -6 yourpassword
```

### 2. Create Groups.plist

`/Local/Library/DirectoryServices/Groups.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>testuser</key>
    <dict>
        <key>groupname</key>
        <string>testuser</string>
        <key>gid</key>
        <integer>5001</integer>
        <key>members</key>
        <array>
            <string>testuser</string>
        </array>
    </dict>
</dict>
</plist>
```

### 3. Create home directory

```sh
sudo mkdir -p /Local/Users/testuser
sudo chown 5001:5001 /Local/Users/testuser
```

### 4. Start gsdh

```sh
sudo gsdh
```

## Server Setup

A server stores users in `/Local` and exports via NFS for clients.

### 1. Complete standalone setup above

### 2. Create Domain.plist

This marks the machine as a server:

```sh
sudo touch /Local/Library/DirectoryServices/Domain.plist
```

Or with content:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>role</key>
    <string>server</string>
</dict>
</plist>
```

### 3. Export /Local via NFS

#### FreeBSD

Add to `/etc/exports`:
```
/Local -alldirs -maproot=root
```

Enable and start NFS:
```sh
# /etc/rc.conf
nfs_server_enable="YES"
rpcbind_enable="YES"
mountd_enable="YES"

# Start services
sudo service rpcbind start
sudo service mountd start
sudo service nfsd start
```

#### Debian/Linux

Add to `/etc/exports`:
```
/Local *(rw,sync,no_subtree_check,no_root_squash)
```

Enable and start NFS:
```sh
sudo apt install nfs-kernel-server
sudo systemctl enable nfs-kernel-server
sudo systemctl start nfs-kernel-server
sudo exportfs -ra
```

#### Verify

```sh
showmount -e localhost
```

## Client Setup

A client mounts `/Network` from the server and uses those users.

### 1. Build and install gsdh/nss_gershwin

Complete the Building and nsswitch.conf steps above.

### 2. Enable NFS client

#### FreeBSD

```sh
# /etc/rc.conf
nfs_client_enable="YES"
rpcbind_enable="YES"

# Start services
sudo service rpcbind start
sudo service nfsclient start
```

#### Debian/Linux

```sh
sudo apt install nfs-common
```

### 3. Mount /Network from server

```sh
sudo mkdir -p /Network
sudo mount -t nfs server:/Local /Network
```

Or add to `/etc/fstab` for persistent mount:
```
server:/Local    /Network    nfs    rw    0    0
```

### 4. Start gsdh

```sh
sudo gsdh
```

gsdh will detect `/Network/Library/DirectoryServices/Users.plist` and use it.

### 5. Verify

```sh
getent passwd testuser
# Should show: testuser:*:5001:5001:Test User:/Network/Users/testuser:/bin/sh
```

## How It Works

| Machine | /Network mounted? | Domain.plist exists? | gsdh reads from |
|---------|-------------------|---------------------|-----------------|
| Server | No | Yes | /Local |
| Client | Yes | No | /Network |
| Standalone | No | No | /Local |

## Authentication

Authentication works through standard `pam_unix`. The daemon returns password hashes only to root callers (verified via `getpeereid`), matching FreeBSD's `/etc/master.passwd` security model.

No PAM configuration changes required.

## Testing

```sh
# Check which path gsdh is using
sudo gsdh &
# Look for "Loaded N users from /path" in output

# NSS lookup
getent passwd testuser
id testuser

# Direct socket query (as root to see hash)
sudo sh -c 'echo "getpwnam:testuser" | nc -U /var/run/gershwin-directory.sock'
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

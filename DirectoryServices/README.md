# Gershwin Directory Services

NSS module and helper daemon for managing users and groups via plist files.

## Components

- **gsdh** - Directory helper daemon (`/System/Library/Tools/gsdh`)
- **nss_gershwin** - NSS module (`/System/Library/Libraries/nss_gershwin.so.1`)

## Data Files

- `/Local/Library/DirectoryServices/Users.plist`
- `/Local/Library/DirectoryServices/Groups.plist`

## Building

```sh
# Ensure GNUstep environment is loaded
. /System/Library/Makefiles/GNUstep.sh

# Build all components
=======
gmake
sudo -E gmake install
```

## Configuration

### 1. Create Users.plist

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
        <key>homeDirectory</key>
        <string>/Users/testuser</string>
        <key>shell</key>
        <string>/bin/sh</string>
        <key>passwordHash</key>
        <string>$6$...</string>
        <key>canLogin</key>
        <true/>
    </dict>
</dict>
</plist>
```

Generate password hash:
```sh
openssl passwd -6 yourpassword
```

### 2. Create Groups.plist

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

### 3. Configure nsswitch.conf

```
passwd: files gershwin
group: files gershwin
```

### 4. Start gsdh

```sh
sudo gsdh
```

## Authentication

Authentication works through standard `pam_unix`. The daemon returns password hashes only to root callers (verified via `getpeereid`), matching FreeBSD's `/etc/master.passwd` security model.

No PAM configuration changes required.

## Testing

```sh
# NSS lookup
getent passwd testuser
id testuser

# Direct socket query (as root to see hash)
echo "getpwnam:testuser" | nc -U /var/run/gershwin-directory.sock
```

## User Fields

| Field | Required | Description |
|-------|----------|-------------|
| username | yes | Login name |
| uid | yes | User ID |
| gid | yes | Primary group ID |
| realName | no | GECOS field |
| homeDirectory | no | Home directory |
| shell | no | Login shell |
| passwordHash | yes* | SHA-512 hash (*for login) |
| canLogin | no | Default: true |

## Group Fields

| Field | Required | Description |
|-------|----------|-------------|
| groupname | yes | Group name |
| gid | yes | Group ID |
| members | no | Array of usernames |

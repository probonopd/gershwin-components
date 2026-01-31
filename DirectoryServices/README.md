# Gershwin Directory Services

Directory services for Gershwin, providing NSS and PAM integration for managing users and groups via plist files.

## Components

### gsdh (GNUstep Directory Helper)

The core daemon that handles user/group lookups and authentication.

- **Binary**: `/System/Library/Tools/gsdh`
- **Socket**: `/var/run/gershwin-directory.sock`
- **Data files**:
  - `/Local/Library/DirectoryServices/Users.plist`
  - `/Local/Library/DirectoryServices/Groups.plist`

### nss_gershwin

NSS (Name Service Switch) module that enables the system to resolve users and groups from gsdh.

- **Library**: `/System/Library/Libraries/libnss_gershwin.so.1`

### pam_gershwin

PAM (Pluggable Authentication Module) that authenticates users against gsdh.

- **Library**: `/System/Library/Libraries/libpam_gershwin.so`

## Building

```sh
# Ensure GNUstep environment is loaded
. /usr/GNUstep/System/Library/Makefiles/GNUstep.sh

# Build all components
gmake

# Install (as root)
sudo gmake install
```

## Configuration

### 1. Create User/Group Data Files

Create the directory and plist files:

```sh
sudo mkdir -p /Local/Library/DirectoryServices
```

#### Users.plist

Create `/Local/Library/DirectoryServices/Users.plist`:

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
        <string>$6$rounds=5000$SALT$HASH</string>
        <key>canLogin</key>
        <true/>
    </dict>
</dict>
</plist>
```

#### Groups.plist

Create `/Local/Library/DirectoryServices/Groups.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>testgroup</key>
    <dict>
        <key>groupname</key>
        <string>testgroup</string>
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

### 2. Generate a Password Hash

Use the system's `crypt` function to generate a SHA-512 hash. You can use this Python one-liner:

```sh
python3 -c "import crypt; print(crypt.crypt('yourpassword', crypt.mksalt(crypt.METHOD_SHA512)))"
```

Replace the `passwordHash` value in Users.plist with the output.

### 3. Configure nsswitch.conf

Edit `/etc/nsswitch.conf` to add `gershwin` to the passwd and group lines:

```
passwd: files gershwin
group: files gershwin
```

The `files` source should come first so local system users (root, daemon, etc.) are resolved from `/etc/passwd` and `/etc/master.passwd` before querying gsdh.

### 4. Configure PAM (Optional)

To enable PAM authentication for gershwin users, edit the appropriate PAM configuration file (e.g., `/etc/pam.d/system` or `/etc/pam.d/login`):

```
# Add before or after pam_unix
auth        sufficient    /System/Library/Libraries/libpam_gershwin.so
account     sufficient    /System/Library/Libraries/libpam_gershwin.so
```

### 5. Start gsdh

Start the daemon (runs as root):

```sh
# Foreground (for testing)
sudo gsdh -d

# Background (production)
sudo gsdh
```

For persistent startup, create an rc.d script or launchd plist.

## Creating a Test User

Complete example to create a test user:

```sh
# 1. Create directories
sudo mkdir -p /Local/Library/DirectoryServices
sudo mkdir -p /Users/testuser

# 2. Generate password hash
HASH=$(python3 -c "import crypt; print(crypt.crypt('testpass123', crypt.mksalt(crypt.METHOD_SHA512)))")

# 3. Create Users.plist
sudo tee /Local/Library/DirectoryServices/Users.plist << EOF
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
        <string>$HASH</string>
        <key>canLogin</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

# 4. Create Groups.plist
sudo tee /Local/Library/DirectoryServices/Groups.plist << EOF
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
EOF

# 5. Set ownership of home directory
sudo chown 5001:5001 /Users/testuser

# 6. Configure NSS
sudo sed -i '' 's/^passwd:.*/passwd: files gershwin/' /etc/nsswitch.conf
sudo sed -i '' 's/^group:.*/group: files gershwin/' /etc/nsswitch.conf

# 7. Start the daemon
sudo gsdh

# 8. Verify
getent passwd testuser
id testuser
```

## Testing

### Test NSS Resolution

```sh
# Look up user by name
getent passwd testuser

# Look up user by UID
getent passwd 5001

# Look up group by name
getent group testuser

# Get user ID info
id testuser
```

### Test gsdh Directly

```sh
# Query the socket directly
echo "getpwnam:testuser" | nc -U /var/run/gershwin-directory.sock
echo "getpwuid:5001" | nc -U /var/run/gershwin-directory.sock
echo "getgrnam:testuser" | nc -U /var/run/gershwin-directory.sock

# Test authentication
echo "auth:testuser:testpass123" | nc -U /var/run/gershwin-directory.sock
# Returns: 1 (success) or 0 (failure)
```

### Test PAM Authentication

```sh
# Try to su to the test user (requires PAM configured)
su - testuser

# Or use login
login testuser
```

## Troubleshooting

### gsdh won't start
- Ensure you're running as root
- Check if socket already exists: `rm /var/run/gershwin-directory.sock`
- Run in foreground for debug output: `gsdh -d`

### User not found
- Verify gsdh is running: `pgrep gsdh`
- Check nsswitch.conf has `gershwin` in passwd/group lines
- Test socket directly with `nc -U`
- Verify Users.plist syntax with `plutil`

### Authentication fails
- Check passwordHash is valid SHA-512 format (`$6$...`)
- Verify canLogin is true
- Test auth directly via socket

## User Plist Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| username | string | yes | Login name |
| uid | integer | yes | User ID (use 5000+ to avoid conflicts) |
| gid | integer | yes | Primary group ID |
| realName | string | no | Full name (GECOS field) |
| homeDirectory | string | no | Home directory path |
| shell | string | no | Login shell |
| passwordHash | string | yes* | SHA-512 crypt hash (*required for login) |
| canLogin | boolean | no | Whether user can authenticate (default: true) |

## Group Plist Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| groupname | string | yes | Group name |
| gid | integer | yes | Group ID |
| members | array | no | Array of member usernames |

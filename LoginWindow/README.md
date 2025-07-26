# LoginWindow

A simple, minimalist login manager for GNUstep-based desktop environments.

## Installation

1. Build the application with `gmake`
2. Install with `gmake install`
3. Add the following line to `/etc/rc.conf` to enable LoginWindow:
   ```
   loginwindow_enable="YES"
   ```
4. Disable other display managers (gdm, lightdm, etc.) in `/etc/rc.conf`


# Create the system preferences directory if it doesn't exist

```
sudo -A mkdir -p /System/Library/Preferences
```

# Create or update the loginwindow.plist file with auto-login user

```
sudo -A defaults write /System/Library/Preferences/loginwindow autoLoginUser User
```

# Logs

Logs are written to `/var/log/LoginWindow.log` if invoked from the rc script.
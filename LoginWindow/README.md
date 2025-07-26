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
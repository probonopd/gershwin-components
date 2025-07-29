# minibus

Minimal daemon for compatibility with legacy applications that require D-Bus

## Objective

Act as a drop-in replacement for `dbus-daemon` but without everything that is not absolutely needed for messages to be passed and services to work.

* Authentication
* Signing
* SELinux
* AppArmor
* Policies
* XML

## Theory of operation

(TODO: To be written)

## Testing

```
timeout 5 dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.Hello
```

## D-Bus criticism

* Way too complicated
* Why does it have to do "security"? Why can't the underlying operating system just take care of who can and cannot read/write to the sockets
* Why does it have to do "message serialization"? Why not send, e.g., JSON back and forth - the the clients encode and decode that
* Comes from GNOME, designed by Red Hat employees, unfortunately KDE went along with it; now it is branded as freedesktop.org, suggesting everyone agreed on it
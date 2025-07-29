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

[Linus Torvalds](https://lkml.iu.edu/hypermail/linux/kernel/1506.2/05492.html):  

> the reason dbus performs abysmally badly is just pure shit user space code"

* Way too complicated
* Why does it have to do "security"? Why can't the underlying operating system just take care of who can and cannot read/write to the sockets? What does this "security" even try to achieve? What is the treat model?
* Why does it have to do "message serialization"? Why not send, e.g., JSON back and forth - the the clients encode and decode that
* Why does it need padding?
* Why do we need to care about endianness?
* Why does it need XML files?
* Why does it need signature fields?

Comes from GNOME, designed by Red Hat employees, unfortunately KDE went along with it; now it is branded as freedesktop.org, implying everyone agreed on it
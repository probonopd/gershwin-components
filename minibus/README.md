# MiniBus

Minimal D-Bus daemon for compatibility with standard D-Bus tools and applications.

## Objective

Act as a drop-in replacement for `dbus-daemon` but without everything that is not absolutely needed for messages to be passed and services to work.

**Removed complexity:**
* Authentication (beyond basic EXTERNAL)
* Message signing and encryption
* SELinux/AppArmor integration
* Complex security policies
* XML configuration files
* Excessive feature bloat

## Status

MiniBus successfully handles standard D-Bus tool interactions.

**Verified working functionality:**
- ✅ **Authentication** (SASL EXTERNAL with Unix credentials)  
- ✅ **Hello exchange** (proper unique name assignment)
- ✅ **Core bus methods** (Hello, ListNames, GetNameOwner)
- ✅ **Message serialization** (follows D-Bus specification)
- ✅ **Connection lifecycle** (authentication → Hello → method calls)
- ✅ **Error handling** (proper error responses)

**Tool Compatibility Status:**
- ✅ **MiniBus ↔ MiniBus**: Full interoperability (100%)
- ✅ **dbus-send → MiniBus**: Core methods work (authentication, Hello, ListNames)
- ✅ **Protocol compliance**: Follows D-Bus specification requirements

## Quick Start

```bash
# Build MiniBus
gmake

# Start daemon
./obj/minibus &

# Test with standard tools

```
dbus-send --bus=unix:path=/tmp/minibus-socket --dest=org.freedesktop.DBus --type=method_call --print-reply / org.freedesktop.DBus.ListNames
```

## Protocol Compliance

This implementation intends to achieve compliance with the [D-Bus specification](https://dbus.freedesktop.org/doc/dbus-specification.html).

### Key Protocol Discoveries

Several critical details were discovered through byte-level analysis that are **not clearly specified** in the official D-Bus specification:

1. **Hello Reply Format**: Must contain only a single reply message, not followed by NameAcquired signal
2. **ListNames Array Order**: Must return bus name first (`org.freedesktop.DBus`), then well-known names, then unique names
3. **Header Field Order**: Reply messages require specific field ordering for compatibility
4. **Message Length Calculation**: Exact byte alignment and padding requirements for different message types

### Authentication Protocol

Implements the minimal D-Bus authentication requirements:
- SASL EXTERNAL mechanism only
- Unix credentials passing (UID verification)
- Proper handshake: null byte → AUTH EXTERNAL → OK → BEGIN

### Supported Bus Methods

Core D-Bus bus interface methods implemented:
- `Hello` - Connection establishment and unique name assignment
- `ListNames` - Service discovery
- `GetNameOwner` - Service ownership queries
- `RequestName` / `ReleaseName` - Service registration

## Testing and Verification

### Standard Tool Testing
```bash
# Service listing  
dbus-send --bus=unix:path=/tmp/minibus-socket --dest=org.freedesktop.DBus --type=method_call --print-reply / org.freedesktop.DBus.ListNames

# Name ownership
dbus-send --bus=unix:path=/tmp/minibus-socket --dest=org.freedesktop.DBus --type=method_call --print-reply / org.freedesktop.DBus.GetNameOwner string:"org.freedesktop.DBus"
```

### Traffic Analysis
Used `socat` for byte-level protocol analysis:
```bash
# Capture real dbus-daemon traffic
socat -x -v unix-listen:/tmp/proxy.socket,reuseaddr unix-connect:/tmp/dbus-daemon.socket

# Compare with MiniBus traffic for byte-for-byte verification
```

### Reference Implementation Testing
Verified against both:
- Real `dbus-daemon` (from dbus package)
- `libdbus` reference implementation (C library)

## Debugging Tools

The `minibus/` directory contains extensive debugging and analysis tools used during development:

- `capture-*.sh` - Network traffic capture scripts
- `compare-*.m` - Message format comparison tools  
- `analyze-*.m` - Byte-level protocol analysis
- `test-*.m` - Various compatibility test clients

See `DEBUGGING_REPORT.md` for complete details on tools and methodologies.

## Limitations and Scope

MiniBus implements the **core D-Bus protocol** needed for basic interoperability. While it works with standard tools, it does not implement the full feature set of the regular `dbus-daemon`:

### What MiniBus Does NOT Support
- Advanced security policies (XML policy files)
- Message signing and encryption  
- SELinux/AppArmor integration
- Complex service activation
- Per-service configuration
- Advanced authentication beyond SASL EXTERNAL
- Message filtering and routing policies

## Implementation Philosophy

MiniBus proves that D-Bus protocol compliance can be achieved with dramatically less complexity than the reference implementation. This is valuable for:

1. **Educational purposes** - Understanding D-Bus without implementation complexity
2. **Minimal environments** - Where full `dbus-daemon` is overkill
3. **Protocol development** - Testing D-Bus clients against a simpler implementation
4. **Debugging** - Simpler codebase for tracing protocol issues

## D-Bus Context

[Linus Torvalds](https://lkml.iu.edu/hypermail/linux/kernel/1506.2/05492.html) famously criticized D-Bus complexity:

> "the reason dbus performs abysmally badly is just pure shit user space code"

Common criticisms of D-Bus:
* Overly complicated for basic message passing
* Unnecessary "security" layering (why not use OS-level socket permissions?)
* Complex message serialization (why not JSON?)
* Padding and endianness requirements
* XML configuration overhead
* Mandatory signature fields

MiniBus addresses these by implementing **only the essential protocol elements** needed for compatibility, demonstrating that much of the complexity can be avoided while maintaining interoperability.
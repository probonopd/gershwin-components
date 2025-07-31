# D-Bus Protocol Description

This description describes the essentials of the D-Bus protocol; it is __not__ authoritative.

## 1. Message Structure

- A D-Bus message consists of a header and a body.
- The header contains metadata; the body contains zero or more typed arguments.
- The header must be aligned to an 8-byte boundary.
- The maximum message size is 134,217,728 bytes (128 MiB).

### Header Format

- Signature: `yyyyuua(yv)`
  - BYTE: Endianness
  - BYTE: Message type (`METHOD_CALL`, `METHOD_RETURN`, `ERROR`, `SIGNAL`)
  - BYTE: Flags (e.g., `NO_REPLY_EXPECTED`, `NO_AUTO_START`)
  - BYTE: Protocol version
  - UINT32: Body length
  - UINT32: Serial number
  - ARRAY of STRUCT (BYTE field code, VARIANT field value): Header fields

### Header Fields

- Each field: 1-byte code + value (in a variant)
- Required fields depend on message type:
  - `PATH` (object path): for `METHOD_CALL`, `SIGNAL`
  - `INTERFACE` (string): required for `SIGNAL`, optional for `METHOD_CALL`
  - `MEMBER` (string): for `METHOD_CALL`, `SIGNAL`
  - `ERROR_NAME` (string): for `ERROR`
  - `REPLY_SERIAL` (uint32): for `METHOD_RETURN`, `ERROR`
  - `DESTINATION` (string): optional
  - `SENDER` (string): optional
  - `SIGNATURE` (signature): optional (defaults to empty)
  - `UNIX_FDS` (uint32): optional

- Unknown header fields must be ignored if well-formed.

## 2. Type System and Marshalling

- Basic types: integers, booleans, strings, object paths, signatures, UNIX_FD.
- Container types: STRUCT `(…)`, ARRAY `a…`, VARIANT `v`, DICT_ENTRY `{…}`.
- Alignment: Each value is aligned to its natural boundary (e.g., 4 bytes for UINT32, 8 bytes for 64-bit types).
- Padding: Insert minimal zero bytes before a value to reach its required alignment.
- STRUCT and DICT_ENTRY always start at an 8-byte boundary, regardless of contents.
- SIGNATURE type is 1-byte aligned (no padding needed).
- Strings: 4-byte aligned, no padding between length, string, and trailing nul.
- Arrays: 4-byte length, then padding to element alignment, then elements.
- Variants: 1-byte signature, then padding to contained type's alignment, then value.

**Examples:**

- UINT32 at offset 2: add 2 zero bytes to reach offset 4.
- STRUCT at offset 10: add 6 zero bytes to reach offset 16.
- Array of 64-bit ints at offset 8: no padding needed, elements start at offset 8.
- String at offset 8: no padding needed, length at 8, string at 12, nul at end.

## 3. Message Types

- `METHOD_CALL`: Invokes a method. Must have `MEMBER` and `PATH`. `INTERFACE` recommended.
- `METHOD_RETURN`: Reply to a method call. Must have `REPLY_SERIAL`.
- `ERROR`: Reply indicating failure. Must have `ERROR_NAME` and `REPLY_SERIAL`.
- `SIGNAL`: Broadcast event. Must have `PATH`, `INTERFACE`, and `MEMBER`.

- Replies (`METHOD_RETURN` or `ERROR`) must reference the original call's serial via `REPLY_SERIAL`.
- If `NO_REPLY_EXPECTED` flag is set, do not send a reply.

## 4. Naming Rules

- Interface names: 2+ elements, dot-separated, ASCII letters/digits/underscore, not starting with digit, max 255 chars.
- Bus names: 1+ elements, dot-separated, ASCII letters/digits/underscore/hyphen, not starting with dot, must contain at least one dot, max 255 chars.
- Member names: ASCII letters/digits/underscore, not starting with digit, no dots, at least 1 char, max 255 chars.
- Error names: Same as interface names.

## 5. Authentication Protocol

- Before messaging, client and server authenticate using a line-based ASCII protocol (SASL profile).
- Client sends a single nul byte immediately after connecting.
- Commands: `AUTH`, `CANCEL`, `BEGIN`, `DATA`, `ERROR`, `NEGOTIATE_UNIX_FD`.
- Server replies: `REJECTED`, `OK`, `DATA`, `ERROR`, `AGREE_UNIX_FD`.
- After successful authentication, client sends `BEGIN` to start message exchange.

## 6. Protocol Handling

- Strict validation: protocol violations result in connection drop.
- Unknown message types and header fields must be ignored if well-formed.
- Only official extensions (future spec versions) are allowed.

## 7. Standard D-Bus Interfaces and Methods

D-Bus defines several standard interfaces with required methods:

### org.freedesktop.DBus.Peer
- **Ping()**
  - No arguments. Replies with METHOD_RETURN. Used to check liveness.
- **GetMachineId() → STRING machine_uuid**
  - Returns a hex-encoded UUID identifying the machine.

### org.freedesktop.DBus.Introspectable
- **Introspect() → STRING xml_data**
  - Returns XML describing the object's interfaces, methods, signals, and properties.

### org.freedesktop.DBus.Properties
- **Get(STRING interface_name, STRING property_name) → VARIANT value**
- **Set(STRING interface_name, STRING property_name, VARIANT value)**
- **GetAll(STRING interface_name) → ARRAY of DICT_ENTRY<STRING,VARIANT> props**
- **PropertiesChanged(STRING interface_name, ARRAY of DICT_ENTRY<STRING,VARIANT> changed_properties, ARRAY<STRING> invalidated_properties)** (signal)

### org.freedesktop.DBus.ObjectManager
- **GetManagedObjects() → ARRAY of DICT_ENTRY<OBJPATH,ARRAY of DICT_ENTRY<STRING,ARRAY of DICT_ENTRY<STRING,VARIANT>>> objpath_interfaces_and_properties**
- **InterfacesAdded(OBJPATH object_path, ARRAY of DICT_ENTRY<STRING,ARRAY of DICT_ENTRY<STRING,VARIANT>> interfaces_and_properties)** (signal)
- **InterfacesRemoved(OBJPATH object_path, ARRAY<STRING> interfaces)** (signal)

These methods are required for D-Bus conformance and are used for basic object management, introspection, and property access.
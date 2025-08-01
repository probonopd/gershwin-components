# MiniBus D-Bus Activation Implementation

## Overview

This document describes the D-Bus service activation implementation in MiniBus, which allows services to be started automatically when needed, following the D-Bus specification.

## Implementation Components

### Core Classes

1. **MBServiceFile** (`MBServiceFile.h/.m`)
   - Parses D-Bus service files (`.service` format)
   - Extracts service name and executable path
   - Validates service file format

2. **MBServiceManager** (`MBServiceManager.h/.m`)
   - Manages service discovery and activation
   - Scans service directories for `.service` files
   - Handles activation requests and process management
   - Implements service lifecycle (start, register, expire)

3. **MBDaemon** (updated)
   - Integrated with MBServiceManager for activation support
   - Handles `StartServiceByName` D-Bus method calls
   - Implements auto-activation during message routing
   - Provides activation status and error reporting

### Service Wrapper

- **Service Wrapper Script** (`/tmp/test-service-wrapper`)
  - Sets up environment variables for activated services
  - Provides `DBUS_STARTER_ADDRESS` and `DBUS_STARTER_BUS_TYPE`
  - Logs activation events for debugging

## Features Implemented

### 1. Service Discovery
- Automatically scans `/tmp/dbus-test-services/` for `.service` files
- Parses service files to extract activation information
- Validates service file format and executables

### 2. Explicit Activation
- Implements `org.freedesktop.DBus.StartServiceByName` method
- Returns appropriate D-Bus activation result codes
- Provides detailed error messages for failed activations

### 3. Auto-Activation
- Automatically starts services when messages are sent to inactive service names
- Queues messages during activation and delivers them once service registers
- Handles activation failures gracefully

### 4. Environment Setup
- Sets `DBUS_STARTER_ADDRESS` to the daemon's socket address
- Sets `DBUS_STARTER_BUS_TYPE` to "session"
- Allows services to connect back to the activating daemon

### 5. Error Handling
- Proper error responses for non-existent services
- Detailed logging of activation attempts and failures
- Graceful handling of service startup failures

## Testing

### Test Programs

1. **test-activation-client.m**
   - Tests explicit activation via `StartServiceByName`
   - Validates activation success/failure responses

2. **test-auto-activation.m**
   - Tests auto-activation by sending messages to inactive services
   - Verifies service startup and message delivery

3. **test-service.m**
   - Sample D-Bus service for testing activation
   - Registers with daemon and stays active for testing

### Test Scripts

1. **test-activation-comprehensive.sh**
   - Complete test suite for all activation features
   - Tests service discovery, explicit activation, auto-activation
   - Validates environment variables and service registration

2. **test-activation-edge-cases.sh**
   - Tests error conditions and edge cases
   - Validates proper error handling and logging

3. **demo-activation.sh**
   - Demonstration of all activation features
   - User-friendly output showing successful implementation

## Usage Example

### Service File Format
```ini
[D-BUS Service]
Name=com.example.TestService
Exec=/tmp/test-service-wrapper
```

### Starting a Service
```objc
// Explicit activation
[daemon startServiceByName:@"com.example.TestService" flags:0];

// Auto-activation (send message to inactive service)
[message setDestination:@"com.example.TestService"];
[daemon routeMessage:message];
```

### Service Implementation
```objc
// Service receives DBUS_STARTER_ADDRESS environment variable
NSString *starterAddress = [[NSProcessInfo processInfo] 
    environment][@"DBUS_STARTER_ADDRESS"];
// Connect to daemon and register service name
```

## Compliance

This implementation follows the D-Bus specification for service activation:
- Supports both explicit and auto-activation
- Proper environment variable setup
- Standard error codes and messages
- Compatible with D-Bus service file format

## Files Modified/Created

### Core Implementation
- `MBServiceFile.h/.m` - Service file parser
- `MBServiceManager.h/.m` - Service activation manager
- `MBDaemon.h/.m` - Updated with activation support
- `GNUmakefile` - Updated build configuration

### Test Programs
- `test-activation-client.m` - Explicit activation test
- `test-auto-activation.m` - Auto-activation test
- `test-service.m` - Test service implementation

### Test Scripts
- `test-activation-comprehensive.sh` - Complete test suite
- `test-activation-edge-cases.sh` - Error handling tests
- `demo-activation.sh` - Feature demonstration

### Service Configuration
- `/tmp/dbus-test-services/com.example.TestService.service` - Test service file
- `/tmp/test-service-wrapper` - Service wrapper script

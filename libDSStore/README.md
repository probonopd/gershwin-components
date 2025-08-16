# libDSStore

A GNUstep library and command-line tool for reading and writing macOS .DS_Store files.

## Overview

libDSStore provides a pure GNUstep/Objective-C implementation for manipulating .DS_Store files. These files are used by macOS Finder to store metadata about files and folders, including icon positions, view settings, background images, and more.

## Features

- Read and write .DS_Store files
- Support for all standard entry types (bool, long, blob, ustr, type, comp, dutc)
- Decode common blob types (icon positions, plist data)
- Command-line tool for inspection and modification
- Full GNUstep compatibility

## Supported Entry Types

- **bool**: Boolean values
- **long/shor**: 32-bit integers
- **blob**: Binary data (automatically decoded for known types)
- **ustr**: Unicode strings (UTF-16BE)
- **type**: 4-character type codes
- **comp/dutc**: 64-bit integers/timestamps

## Common Entry Codes

- **Iloc**: Icon location (x, y coordinates)
- **bwsp**: Browser window state plist
- **lsvp**: List view properties plist
- **lsvP**: List view properties plist (alternate)
- **icvp**: Icon view properties plist
- **pBBk**: Background picture bookmark

## Library Usage

### Basic Usage

```objc
#import <DSStore/DSStore.h>

// Load existing .DS_Store file
DSStore *store = [DSStore storeWithPath:@"/path/to/.DS_Store"];
if ([store load]) {
    // Access entries
    NSArray<DSStoreEntry *> *entries = store.entries;
    
    // Get specific entry
    DSStoreEntry *entry = [store entryForFilename:@"file.txt" code:@"Iloc"];
    
    // Get icon position
    NSPoint iconPos = [store iconLocationForFilename:@"file.txt"];
    
    // Set icon position
    [store setIconLocation:NSMakePoint(100, 200) forFilename:@"file.txt"];
    
    // Save changes
    [store save];
}

// Create new .DS_Store file
DSStore *newStore = [DSStore createStoreAtPath:@"/path/to/new/.DS_Store" withEntries:nil];
[newStore setIconLocation:NSMakePoint(50, 100) forFilename:@"document.pdf"];
[newStore save];
```

### Working with Entries

```objc
// Create a new entry
DSStoreEntry *entry = [[DSStoreEntry alloc] initWithFilename:@"file.txt"
                                                        code:@"note" 
                                                        type:DSStoreEntryTypeUnicodeString
                                                       value:@"My note"];
[store setEntry:entry];

// Remove an entry
[store removeEntryForFilename:@"file.txt" code:@"note"];
```

### Working with Plists

```objc
// Get background picture settings
NSDictionary *bgPicture = [store backgroundPictureForDirectory];

// Set list view settings
NSDictionary *listViewSettings = @{
    @"calculateAllSizes": @(YES),
    @"columns": @{
        @"name": @{@"ascending": @(YES), @"index": @(0), @"visible": @(YES), @"width": @(300)},
        @"size": @{@"ascending": @(NO), @"index": @(1), @"visible": @(YES), @"width": @(100)}
    }
};
[store setListViewSettings:listViewSettings];
```

## Command-Line Tool Usage

The `dsstore` command-line tool provides easy access to .DS_Store file functionality.

### Listing Entries

```bash
# List entries in current directory's .DS_Store
dsstore -l

# List entries with verbose output
dsstore -l -v

# List entries in specific directory
dsstore -l /path/to/directory

# List entries in specific .DS_Store file
dsstore -l /path/to/.DS_Store
```

### Icon Positions

```bash
# Get icon position for a file
dsstore --get-icon-pos file.txt

# Set icon position for a file
dsstore --set-icon-pos file.txt 100 200
```

### Background Pictures

```bash
# Set background picture
dsstore --set-bg-picture /path/to/image.jpg

# Clear background picture
dsstore --clear-bg-picture
```

### Entry Manipulation

```bash
# Set a custom entry
dsstore -s --filename file.txt --code note --type ustr --value "My custom note"

# Delete an entry
dsstore -d --filename file.txt --code note

# Set boolean entry
dsstore -s --filename . --code customFlag --type bool --value true

# Set integer entry
dsstore -s --filename file.txt --code priority --type long --value 42
```

### Creating Files

```bash
# Create new .DS_Store file
dsstore -c /path/to/new/.DS_Store
```

## Building

Requirements:
- GNUstep development environment
- clang19 compiler

```bash
# Build library and tool
gmake

# Install
sudo gmake install

# Clean
gmake clean
```

## File Format

The .DS_Store file format consists of:

1. **Buddy Allocator Header**: Manages block allocation within the file
2. **DSDB Superblock**: Contains metadata about the B-tree structure
3. **B-tree Nodes**: Store the actual entries in sorted order

Each entry contains:
- Filename (UTF-16BE string)
- 4-character code
- 4-character type
- Value data (format depends on type)

## Compatibility

This implementation is compatible with .DS_Store files created by:
- macOS Finder (all versions)
- Other .DS_Store manipulation tools
- The original Python `ds_store` library

## Error Handling

The library provides comprehensive error handling:
- Invalid file format detection
- Corrupted data recovery attempts
- Missing file handling
- Write permission checks

## Thread Safety

The library is not thread-safe. Use appropriate synchronization when accessing DSStore objects from multiple threads.

## Limitations

- Complex B-tree structures are simplified during write operations
- Some advanced Finder features may not be fully supported
- Large directories may have performance implications

## Examples

See the `dsstore` command-line tool source code for comprehensive usage examples.

## Contributing

Contributions are welcome! Please ensure all code follows the project's coding standards and includes appropriate tests.

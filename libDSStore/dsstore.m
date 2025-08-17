#import <Foundation/Foundation.h>
#import "DSStore.h"
#import "DSStoreEntry.h"

void printUsage(void) {
    printf("libDSStore command line tool\n\n");
    printf("Usage:\n");
    printf("  dsstore list [path]                        List entries in .DS_Store file\n");
    printf("  dsstore dump [path]                        Dump ALL data from .DS_Store file\n");
    printf("  dsstore create <path>                      Create new empty .DS_Store file\n");
    printf("\nIcon Position Commands:\n");
    printf("  dsstore get-icon <file> <filename>         Get icon position\n");
    printf("  dsstore set-icon <file> <filename> <x> <y> Set icon position\n");
    printf("\nBackground Commands:\n");
    printf("  dsstore get-background <file>              Get background settings\n");
    printf("  dsstore set-background-color <file> <r> <g> <b>  Set color (0.0-1.0)\n");
    printf("  dsstore set-background-image <file> <path> Set background image\n");
    printf("  dsstore remove-background <file>           Remove background\n");
    printf("\nView Settings Commands:\n");
    printf("  dsstore get-view <file>                    Get view settings\n");
    printf("  dsstore set-view-style <file> <style>      Set view style (icon/list/column/flow)\n");
    printf("  dsstore set-icon-size <file> <size>        Set icon size (16-512)\n");
    printf("\nFile Metadata Commands:\n");
    printf("  dsstore get-comment <file> <filename>      Get file comment\n");
    printf("  dsstore set-comment <file> <filename> <text>  Set file comment\n");
    printf("  dsstore get-size <file> <filename> [type]  Get file size (logical/physical)\n");
    printf("  dsstore set-size <file> <filename> <type> <size>  Set file size\n");
    printf("  dsstore get-date <file> <filename>         Get modification date\n");
    printf("  dsstore set-date <file> <filename> <timestamp>  Set modification date\n");
    printf("\nGeneric Field Commands:\n");
    printf("  dsstore get-field <file> <filename> <code> Get any field value\n");
    printf("  dsstore set-field <file> <filename> <code> <type> <value>  Set field\n");
    printf("  dsstore remove-field <file> <filename> <code>  Remove field\n");
    printf("  dsstore list-fields <file> <filename>      List all fields for file\n");
    printf("\nUtility Commands:\n");
    printf("  dsstore info <file>                        Show file information\n");
    printf("  dsstore validate <file>                    Validate .DS_Store file\n");
    printf("  dsstore list-files <file>                  List all files with entries\n");
    printf("  dsstore cleanup <file>                     Remove unused entries\n");
    printf("\nExamples:\n");
    printf("  dsstore list\n");
    printf("  dsstore get-icon .DS_Store file.txt\n");
    printf("  dsstore set-icon .DS_Store file.txt 100 150\n");
    printf("  dsstore set-background-color .DS_Store 1.0 0.8 0.6\n");
    printf("  dsstore set-view-style .DS_Store icon\n");
    printf("  dsstore set-comment .DS_Store file.txt 'Important document'\n");
    printf("  dsstore get-field .DS_Store . vstl\n");
    printf("  dsstore set-field .DS_Store . icvo long 64\n");
}

int listEntries(NSString *path) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        printf("Error: File not found: %s\n", [path UTF8String]);
        return 1;
    }
    
    DSStore *store = [[[DSStore alloc] initWithPath:path] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    NSArray *entries = [store entries];
    printf("Found %lu entries in %s:\n", (unsigned long)[entries count], [path UTF8String]);
    
    for (DSStoreEntry *entry in entries) {
        printf("  %-20s %s\n", 
               [[entry filename] UTF8String], 
               [[entry code] UTF8String]);
    }
    
    return 0;
}

int dumpAll(NSString *path) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        printf("Error: File not found: %s\n", [path UTF8String]);
        return 1;
    }
    
    DSStore *store = [[[DSStore alloc] initWithPath:path] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    NSArray *entries = [store entries];
    printf("=== COMPLETE DS_STORE DUMP: %s ===\n", [path UTF8String]);
    printf("Total entries: %lu\n\n", (unsigned long)[entries count]);
    
    // Group entries by filename
    NSMutableDictionary *entriesByFile = [NSMutableDictionary dictionary];
    for (DSStoreEntry *entry in entries) {
        NSString *filename = [entry filename];
        NSMutableArray *fileEntries = [entriesByFile objectForKey:filename];
        if (!fileEntries) {
            fileEntries = [NSMutableArray array];
            [entriesByFile setObject:fileEntries forKey:filename];
        }
        [fileEntries addObject:entry];
    }
    
    // Sort filenames for consistent output  
    NSArray *sortedFilenames = [[entriesByFile allKeys] sortedArrayUsingSelector:@selector(compare:)];
    
    for (NSString *filename in sortedFilenames) {
        printf("File: '%s'\n", [filename UTF8String]);
        NSArray *fileEntries = [entriesByFile objectForKey:filename];
        
        for (DSStoreEntry *entry in fileEntries) {
            NSString *code = [entry code];
            NSString *type = [entry type]; 
            id value = [entry value];
            
            printf("  %s (%s): ", [code UTF8String], [type UTF8String]);
            
            // Interpret known codes
            if ([code isEqualToString:@"Iloc"] && [type isEqualToString:@"blob"]) {
                if ([value isKindOfClass:[NSData class]]) {
                    NSData *data = (NSData *)value;
                    if ([data length] >= 8) {
                        const uint8_t *bytes = [data bytes];
                        uint32_t x = (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
                        uint32_t y = (bytes[4] << 24) | (bytes[5] << 16) | (bytes[6] << 8) | bytes[7];
                        printf("Icon position (%u, %u)", x, y);
                        if ([data length] > 8) {
                            printf(" + %lu extra bytes", (unsigned long)[data length] - 8);
                        }
                    } else {
                        printf("Invalid Iloc data (too short)");
                    }
                } else {
                    printf("Invalid Iloc data (not NSData)");
                }
            } else if ([code isEqualToString:@"bwsp"]) {
                printf("Background/Window settings (plist data)");
            } else if ([code isEqualToString:@"icvp"]) {
                printf("Icon view properties (plist data)");
            } else if ([code isEqualToString:@"lsvp"] || [code isEqualToString:@"lsvP"]) {
                printf("List view properties (plist data)");
            } else if ([code isEqualToString:@"vstl"]) {
                printf("View style");
            } else if ([code isEqualToString:@"BKGD"]) {
                printf("Background (legacy)");
            } else if ([code isEqualToString:@"cmmt"]) {
                printf("Comments");
            } else if ([code isEqualToString:@"dilc"]) {
                printf("Desktop icon location");
            } else if ([code isEqualToString:@"dscl"]) {
                printf("Disclosure state");
            } else if ([code isEqualToString:@"fwi0"]) {
                printf("Finder window info");
            } else if ([code isEqualToString:@"icgo"]) {
                printf("Icon grid offset");
            } else if ([code isEqualToString:@"icsp"]) {
                printf("Icon spacing");
            } else if ([code isEqualToString:@"icvo"]) {
                printf("Icon view options");
            } else if ([code isEqualToString:@"ICVO"]) {
                printf("Icon view overlay");
            } else if ([code isEqualToString:@"LSVO"]) {
                printf("List view overlay");
            } else if ([code isEqualToString:@"GRP0"]) {
                printf("Group (unknown)");
            } else {
                printf("Unknown code");
            }
            
            // Show raw value for small data
            if ([value isKindOfClass:[NSData class]]) {
                NSData *data = (NSData *)value;
                if ([data length] <= 16) {
                    printf(" [");
                    const uint8_t *bytes = [data bytes];
                    for (NSUInteger i = 0; i < [data length]; i++) {
                        printf("%02x", bytes[i]);
                        if (i < [data length] - 1) printf(" ");
                    }
                    printf("]");
                } else {
                    printf(" [%lu bytes]", (unsigned long)[data length]);
                }
            } else if ([value isKindOfClass:[NSString class]]) {
                printf(" \"%s\"", [(NSString *)value UTF8String]);
            } else if ([value isKindOfClass:[NSNumber class]]) {
                printf(" %s", [[(NSNumber *)value description] UTF8String]);
            }
            
            printf("\n");
        }
        printf("\n");
    }
    
    return 0;
}

int createStore(NSString *path) {
    NSArray *emptyEntries = [NSArray array];
    DSStore *store = [DSStore createStoreAtPath:path withEntries:emptyEntries];
    if (!store) {
        printf("Error: Failed to create .DS_Store file at %s\n", [path UTF8String]);
        return 1;
    }
    
    if (![store save]) {
        printf("Error: Failed to save .DS_Store file\n");
        return 1;
    }
    
    printf("Created empty .DS_Store file: %s\n", [path UTF8String]);
    return 0;
}

int setIconPosition(NSString *storePath, NSString *filename, int x, int y) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![[NSFileManager defaultManager] fileExistsAtPath:storePath]) {
        // Create new store if it doesn't exist
        NSArray *emptyEntries = [NSArray array];
        store = [DSStore createStoreAtPath:storePath withEntries:emptyEntries];
        if (!store) {
            printf("Error: Failed to create .DS_Store file\n");
            return 1;
        }
    } else if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    NSDictionary *location = [NSDictionary dictionaryWithObjectsAndKeys:
                             [NSNumber numberWithInt:x], @"x",
                             [NSNumber numberWithInt:y], @"y",
                             nil];
    
    [store setIconLocation:location forFilename:filename];
    
    if (![store save]) {
        printf("Error: Failed to save .DS_Store file\n");
        return 1;
    }
    
    printf("Set icon position for %s to (%d, %d)\n", [filename UTF8String], x, y);
    return 0;
}

int getIconPosition(NSString *storePath, NSString *filename) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:storePath]) {
        printf("Error: File not found: %s\n", [storePath UTF8String]);
        return 1;
    }
    
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    NSPoint location = [store iconLocationForFilename:filename];
    if (location.x == 0 && location.y == 0) {
        printf("No icon position set for %s\n", [filename UTF8String]);
    } else {
        printf("Icon position for %s: (%.0f, %.0f)\n", 
               [filename UTF8String], location.x, location.y);
    }
    
    return 0;
}

int setBackground(NSString *storePath, const char *type, int argc, const char *argv[], int startIndex) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![[NSFileManager defaultManager] fileExistsAtPath:storePath]) {
        NSArray *emptyEntries = [NSArray array];
        store = [DSStore createStoreAtPath:storePath withEntries:emptyEntries];
        if (!store) {
            printf("Error: Failed to create .DS_Store file\n");
            return 1;
        }
    } else if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    NSDictionary *backgroundInfo = nil;
    
    if (strcmp(type, "color") == 0) {
        if (argc < startIndex + 3) {
            printf("Error: Color background requires R G B values (0.0-1.0)\n");
            return 1;
        }
        
        float r = atof(argv[startIndex]);
        float g = atof(argv[startIndex + 1]);
        float b = atof(argv[startIndex + 2]);
        
        backgroundInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                         @"color", @"type",
                         [NSNumber numberWithFloat:r], @"red",
                         [NSNumber numberWithFloat:g], @"green",
                         [NSNumber numberWithFloat:b], @"blue",
                         nil];
        
        printf("Set background color to RGB(%.2f, %.2f, %.2f)\n", r, g, b);
    } else if (strcmp(type, "image") == 0) {
        if (argc < startIndex + 1) {
            printf("Error: Image background requires path\n");
            return 1;
        }
        
        NSString *imagePath = [NSString stringWithUTF8String:argv[startIndex]];
        backgroundInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                         @"image", @"type",
                         imagePath, @"path",
                         nil];
        
        printf("Set background image to %s\n", [imagePath UTF8String]);
    } else if (strcmp(type, "default") == 0) {
        backgroundInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                         @"default", @"type",
                         nil];
        
        printf("Set background to default\n");
    } else {
        printf("Error: Unknown background type: %s\n", type);
        return 1;
    }
    
    [store setBackgroundPicture:backgroundInfo];
    
    if (![store save]) {
        printf("Error: Failed to save .DS_Store file\n");
        return 1;
    }
    
    return 0;
}

int setView(NSString *storePath, const char *type, int argc, const char *argv[], int startIndex) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![[NSFileManager defaultManager] fileExistsAtPath:storePath]) {
        NSArray *emptyEntries = [NSArray array];
        store = [DSStore createStoreAtPath:storePath withEntries:emptyEntries];
        if (!store) {
            printf("Error: Failed to create .DS_Store file\n");
            return 1;
        }
    } else if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    NSDictionary *viewSettings = nil;
    
    if (strcmp(type, "icon") == 0) {
        int iconSize = 64; // Default
        if (argc > startIndex) {
            iconSize = atoi(argv[startIndex]);
        }
        
        viewSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                       @"icon", @"viewType",
                       [NSNumber numberWithInt:iconSize], @"iconSize",
                       nil];
        
        [store setIconViewSettings:viewSettings];
        printf("Set view to icon mode with size %d\n", iconSize);
    } else if (strcmp(type, "list") == 0) {
        viewSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                       @"list", @"viewType",
                       nil];
        
        [store setListViewSettings:viewSettings];
        printf("Set view to list mode\n");
    } else {
        printf("Error: Unknown view type: %s\n", type);
        return 1;
    }
    
    if (![store save]) {
        printf("Error: Failed to save .DS_Store file\n");
        return 1;
    }
    
    return 0;
}

int removeEntry(NSString *storePath, NSString *filename, NSString *code) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:storePath]) {
        printf("Error: File not found: %s\n", [storePath UTF8String]);
        return 1;
    }
    
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    [store removeEntryForFilename:filename code:code];
    
    if (![store save]) {
        printf("Error: Failed to save .DS_Store file\n");
        return 1;
    }
    
    printf("Removed entry %s:%s\n", [filename UTF8String], [code UTF8String]);
    return 0;
}

// Background management functions
int getBackground(NSString *storePath) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    // Try to get background color entry directly
    DSStoreEntry *colorEntry = [store entryForFilename:@"." code:@"BKGD"];
    if (colorEntry && [[colorEntry type] isEqualToString:@"blob"]) {
        NSData *data = [colorEntry value];
        if ([data length] >= 6) {
            const unsigned char *bytes = [data bytes];
            uint16_t red = (bytes[0] << 8) | bytes[1];
            uint16_t green = (bytes[2] << 8) | bytes[3];
            uint16_t blue = (bytes[4] << 8) | bytes[5];
            printf("Background: color %.3f %.3f %.3f\n", 
                   red/65535.0, green/65535.0, blue/65535.0);
            return 0;
        }
    }
    
    NSString *imagePath = [store backgroundImagePathForDirectory];
    if (imagePath) {
        printf("Background: image %s\n", [imagePath UTF8String]);
    } else {
        printf("Background: default\n");
    }
    
    return 0;
}

int setBackgroundColor(NSString *storePath, float r, float g, float b) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    // Create a simple RGB color representation without NSColor
    int redInt = (int)(r * 65535);
    int greenInt = (int)(g * 65535);
    int blueInt = (int)(b * 65535);
    
    DSStoreEntry *entry = [DSStoreEntry backgroundColorEntryForFile:@"." red:redInt green:greenInt blue:blueInt];
    [store setEntry:entry];
    
    if (![store saveChanges]) {
        printf("Error: Failed to save .DS_Store file\n");
        return 1;
    }
    
    printf("Set background color to %.3f %.3f %.3f\n", r, g, b);
    return 0;
}

int setBackgroundImage(NSString *storePath, NSString *imagePath) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    [store setBackgroundImagePathForDirectory:imagePath];
    
    if (![store saveChanges]) {
        printf("Error: Failed to save .DS_Store file\n");
        return 1;
    }
    
    printf("Set background image to %s\n", [imagePath UTF8String]);
    return 0;
}

int removeBackground(NSString *storePath) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    [store removeEntryForFilename:@"." code:@"BKGD"];
    
    if (![store saveChanges]) {
        printf("Error: Failed to save .DS_Store file\n");
        return 1;
    }
    
    printf("Removed background settings\n");
    return 0;
}

// View management functions
int getView(NSString *storePath) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    NSString *viewStyle = [store viewStyleForDirectory];
    int iconSize = [store iconSizeForDirectory];
    
    if (viewStyle) {
        printf("View style: %s\n", [viewStyle UTF8String]);
    }
    
    if (iconSize > 0) {
        printf("Icon size: %d\n", iconSize);
    }
    
    if (!viewStyle && iconSize == 0) {
        printf("View: default\n");
    }
    
    return 0;
}

int setViewStyle(NSString *storePath, NSString *style) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    [store setViewStyleForDirectory:style];
    
    if (![store saveChanges]) {
        printf("Error: Failed to save .DS_Store file\n");
        return 1;
    }
    
    printf("Set view style to %s\n", [style UTF8String]);
    return 0;
}

int setIconSize(NSString *storePath, int size) {
    if (size < 16 || size > 512) {
        printf("Error: Icon size must be between 16 and 512\n");
        return 1;
    }
    
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    [store setIconSizeForDirectory:size];
    
    if (![store saveChanges]) {
        printf("Error: Failed to save .DS_Store file\n");
        return 1;
    }
    
    printf("Set icon size to %d\n", size);
    return 0;
}

// Comment management functions
int getComment(NSString *storePath, NSString *filename) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    NSString *comment = [store commentsForFilename:filename];
    if (comment) {
        printf("Comment for %s: %s\n", [filename UTF8String], [comment UTF8String]);
    } else {
        printf("No comment for %s\n", [filename UTF8String]);
    }
    
    return 0;
}

int setComment(NSString *storePath, NSString *filename, NSString *comment) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    [store setCommentsForFilename:filename comments:comment];
    
    if (![store saveChanges]) {
        printf("Error: Failed to save .DS_Store file\n");
        return 1;
    }
    
    printf("Set comment for %s: %s\n", [filename UTF8String], [comment UTF8String]);
    return 0;
}

// Generic field management functions
int getField(NSString *storePath, NSString *filename, NSString *code) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    DSStoreEntry *entry = [store entryForFilename:filename code:code];
    if (entry) {
        printf("Field %s:%s = (%s) ", [filename UTF8String], [code UTF8String], [[entry type] UTF8String]);
        
        id value = [entry value];
        if ([value isKindOfClass:[NSString class]]) {
            printf("\"%s\"\n", [(NSString *)value UTF8String]);
        } else if ([value isKindOfClass:[NSNumber class]]) {
            printf("%s\n", [[(NSNumber *)value stringValue] UTF8String]);
        } else if ([value isKindOfClass:[NSDate class]]) {
            printf("%s\n", [[(NSDate *)value description] UTF8String]);
        } else if ([value isKindOfClass:[NSData class]]) {
            NSData *data = (NSData *)value;
            printf("<%lu bytes>\n", (unsigned long)[data length]);
        } else {
            printf("%s\n", [[value description] UTF8String]);
        }
    } else {
        printf("No field %s:%s\n", [filename UTF8String], [code UTF8String]);
    }
    
    return 0;
}

int setField(NSString *storePath, NSString *filename, NSString *code, NSString *type, NSString *valueStr) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    id value = nil;
    
    if ([type isEqualToString:@"bool"]) {
        BOOL boolValue = [valueStr isEqualToString:@"true"] || [valueStr isEqualToString:@"1"] || [valueStr isEqualToString:@"yes"];
        value = [NSNumber numberWithBool:boolValue];
    } else if ([type isEqualToString:@"shor"] || [type isEqualToString:@"long"]) {
        value = [NSNumber numberWithLong:[valueStr longLongValue]];
    } else if ([type isEqualToString:@"comp"]) {
        value = [NSNumber numberWithLongLong:[valueStr longLongValue]];
    } else if ([type isEqualToString:@"dutc"]) {
        NSTimeInterval timestamp = [valueStr doubleValue];
        value = [NSDate dateWithTimeIntervalSince1970:timestamp];
    } else if ([type isEqualToString:@"ustr"] || [type isEqualToString:@"type"]) {
        value = valueStr;
    } else if ([type isEqualToString:@"blob"]) {
        // For blob, expect hex string
        NSMutableData *data = [NSMutableData data];
        const char *hexStr = [valueStr UTF8String];
        for (int i = 0; i < strlen(hexStr); i += 2) {
            char hex[3] = {hexStr[i], hexStr[i+1], 0};
            unsigned char byte = (unsigned char)strtol(hex, NULL, 16);
            [data appendBytes:&byte length:1];
        }
        value = data;
    } else {
        printf("Error: Unknown type '%s'\n", [type UTF8String]);
        return 1;
    }
    
    DSStoreEntry *entry = [[DSStoreEntry alloc] initWithFilename:filename code:code type:type value:value];
    [store setEntry:entry];
    [entry release];
    
    if (![store saveChanges]) {
        printf("Error: Failed to save .DS_Store file\n");
        return 1;
    }
    
    printf("Set field %s:%s to (%s) %s\n", [filename UTF8String], [code UTF8String], [type UTF8String], [valueStr UTF8String]);
    return 0;
}

int removeField(NSString *storePath, NSString *filename, NSString *code) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    [store removeEntryForFilename:filename code:code];
    
    if (![store saveChanges]) {
        printf("Error: Failed to save .DS_Store file\n");
        return 1;
    }
    
    printf("Removed field %s:%s\n", [filename UTF8String], [code UTF8String]);
    return 0;
}

int listFields(NSString *storePath, NSString *filename) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    NSArray *codes = [store allCodesForFilename:filename];
    if ([codes count] > 0) {
        printf("Fields for %s:\n", [filename UTF8String]);
        for (NSString *code in codes) {
            DSStoreEntry *entry = [store entryForFilename:filename code:code];
            if (entry) {
                printf("  %s (%s)\n", [code UTF8String], [[entry type] UTF8String]);
            }
        }
    } else {
        printf("No fields for %s\n", [filename UTF8String]);
    }
    
    return 0;
}

int listFiles(NSString *storePath) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    NSArray *filenames = [store allFilenames];
    if ([filenames count] > 0) {
        printf("Files with entries:\n");
        for (NSString *filename in filenames) {
            NSArray *codes = [store allCodesForFilename:filename];
            printf("  %s (%lu fields)\n", [filename UTF8String], (unsigned long)[codes count]);
        }
    } else {
        printf("No files found\n");
    }
    
    return 0;
}

int validateFile(NSString *storePath) {
    DSStore *store = [[[DSStore alloc] initWithPath:storePath] autorelease];
    if (![store load]) {
        printf("Error: Failed to load .DS_Store file\n");
        return 1;
    }
    
    NSArray *entries = [store entries];
    printf("Validation results for %s:\n", [storePath UTF8String]);
    printf("  Entries: %lu\n", (unsigned long)[entries count]);
    
    // Count by type
    NSMutableDictionary *typeCounts = [NSMutableDictionary dictionary];
    for (DSStoreEntry *entry in entries) {
        NSString *type = [entry type];
        NSNumber *count = [typeCounts objectForKey:type];
        if (count) {
            [typeCounts setObject:[NSNumber numberWithInt:[count intValue] + 1] forKey:type];
        } else {
            [typeCounts setObject:[NSNumber numberWithInt:1] forKey:type];
        }
    }
    
    printf("  Types:\n");
    for (NSString *type in [typeCounts allKeys]) {
        NSNumber *count = [typeCounts objectForKey:type];
        printf("    %s: %d\n", [type UTF8String], [count intValue]);
    }
    
    printf("  Status: Valid DS_Store file\n");
    return 0;
}

int showInfo(NSString *path) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        printf("Error: File not found: %s\n", [path UTF8String]);
        return 1;
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:&error];
    if (error) {
        printf("Error getting file attributes: %s\n", [[error localizedDescription] UTF8String]);
        return 1;
    }
    
    NSNumber *fileSize = [attrs objectForKey:NSFileSize];
    NSDate *modDate = [attrs objectForKey:NSFileModificationDate];
    
    printf("File: %s\n", [path UTF8String]);
    printf("Size: %llu bytes\n", [fileSize unsignedLongLongValue]);
    printf("Modified: %s", [[modDate description] UTF8String]);
    
    DSStore *store = [[[DSStore alloc] initWithPath:path] autorelease];
    if ([store load]) {
        NSArray *entries = [store entries];
        printf("Entries: %lu\n", (unsigned long)[entries count]);
        
        // Show background settings
        NSDictionary *bg = [store backgroundPictureForDirectory];
        if (bg) {
            NSString *bgType = [bg objectForKey:@"type"];
            printf("Background: %s\n", [bgType UTF8String]);
        }
        
        // Show view settings
        NSDictionary *iconView = [store iconViewSettingsForDirectory];
        NSDictionary *listView = [store listViewSettingsForDirectory];
        if (iconView) {
            printf("Icon view settings found\n");
        }
        if (listView) {
            printf("List view settings found\n");
        }
    }
    
    return 0;
}

int main(int argc, const char * argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    if (argc < 2) {
        printUsage();
        [pool drain];
        return 1;
    }
    
    const char *command = argv[1];
    int result = 0;
    
    if (strcmp(command, "list") == 0) {
        NSString *path = @".DS_Store";
        if (argc > 2) {
            path = [NSString stringWithUTF8String:argv[2]];
        }
        result = listEntries(path);
    } else if (strcmp(command, "dump") == 0) {
        NSString *path = @".DS_Store";
        if (argc > 2) {
            path = [NSString stringWithUTF8String:argv[2]];
        }
        result = dumpAll(path);
    } else if (strcmp(command, "create") == 0) {
        if (argc < 3) {
            printf("Error: create command requires path\n");
            result = 1;
        } else {
            NSString *path = [NSString stringWithUTF8String:argv[2]];
            result = createStore(path);
        }
    } else if (strcmp(command, "set-icon-pos") == 0) {
        if (argc < 6) {
            printf("Error: set-icon-pos requires <file> <filename> <x> <y>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            NSString *filename = [NSString stringWithUTF8String:argv[3]];
            int x = atoi(argv[4]);
            int y = atoi(argv[5]);
            result = setIconPosition(storePath, filename, x, y);
        }
    } else if (strcmp(command, "get-icon") == 0) {
        if (argc < 4) {
            printf("Error: get-icon requires <file> <filename>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            NSString *filename = [NSString stringWithUTF8String:argv[3]];
            result = getIconPosition(storePath, filename);
        }
    } else if (strcmp(command, "set-icon") == 0) {
        if (argc < 6) {
            printf("Error: set-icon requires <file> <filename> <x> <y>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            NSString *filename = [NSString stringWithUTF8String:argv[3]];
            int x = atoi(argv[4]);
            int y = atoi(argv[5]);
            result = setIconPosition(storePath, filename, x, y);
        }
    } else if (strcmp(command, "get-background") == 0) {
        if (argc < 3) {
            printf("Error: get-background requires <file>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            result = getBackground(storePath);
        }
    } else if (strcmp(command, "set-background-color") == 0) {
        if (argc < 6) {
            printf("Error: set-background-color requires <file> <r> <g> <b>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            float r = atof(argv[3]);
            float g = atof(argv[4]);
            float b = atof(argv[5]);
            result = setBackgroundColor(storePath, r, g, b);
        }
    } else if (strcmp(command, "set-background-image") == 0) {
        if (argc < 4) {
            printf("Error: set-background-image requires <file> <image_path>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            NSString *imagePath = [NSString stringWithUTF8String:argv[3]];
            result = setBackgroundImage(storePath, imagePath);
        }
    } else if (strcmp(command, "remove-background") == 0) {
        if (argc < 3) {
            printf("Error: remove-background requires <file>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            result = removeBackground(storePath);
        }
    } else if (strcmp(command, "get-view") == 0) {
        if (argc < 3) {
            printf("Error: get-view requires <file>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            result = getView(storePath);
        }
    } else if (strcmp(command, "set-view-style") == 0) {
        if (argc < 4) {
            printf("Error: set-view-style requires <file> <style>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            NSString *style = [NSString stringWithUTF8String:argv[3]];
            result = setViewStyle(storePath, style);
        }
    } else if (strcmp(command, "set-icon-size") == 0) {
        if (argc < 4) {
            printf("Error: set-icon-size requires <file> <size>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            int size = atoi(argv[3]);
            result = setIconSize(storePath, size);
        }
    } else if (strcmp(command, "get-comment") == 0) {
        if (argc < 4) {
            printf("Error: get-comment requires <file> <filename>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            NSString *filename = [NSString stringWithUTF8String:argv[3]];
            result = getComment(storePath, filename);
        }
    } else if (strcmp(command, "set-comment") == 0) {
        if (argc < 5) {
            printf("Error: set-comment requires <file> <filename> <comment>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            NSString *filename = [NSString stringWithUTF8String:argv[3]];
            NSString *comment = [NSString stringWithUTF8String:argv[4]];
            result = setComment(storePath, filename, comment);
        }
    } else if (strcmp(command, "get-field") == 0) {
        if (argc < 5) {
            printf("Error: get-field requires <file> <filename> <code>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            NSString *filename = [NSString stringWithUTF8String:argv[3]];
            NSString *code = [NSString stringWithUTF8String:argv[4]];
            result = getField(storePath, filename, code);
        }
    } else if (strcmp(command, "set-field") == 0) {
        if (argc < 7) {
            printf("Error: set-field requires <file> <filename> <code> <type> <value>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            NSString *filename = [NSString stringWithUTF8String:argv[3]];
            NSString *code = [NSString stringWithUTF8String:argv[4]];
            NSString *type = [NSString stringWithUTF8String:argv[5]];
            NSString *value = [NSString stringWithUTF8String:argv[6]];
            result = setField(storePath, filename, code, type, value);
        }
    } else if (strcmp(command, "remove-field") == 0) {
        if (argc < 5) {
            printf("Error: remove-field requires <file> <filename> <code>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            NSString *filename = [NSString stringWithUTF8String:argv[3]];
            NSString *code = [NSString stringWithUTF8String:argv[4]];
            result = removeField(storePath, filename, code);
        }
    } else if (strcmp(command, "list-fields") == 0) {
        if (argc < 4) {
            printf("Error: list-fields requires <file> <filename>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            NSString *filename = [NSString stringWithUTF8String:argv[3]];
            result = listFields(storePath, filename);
        }
    } else if (strcmp(command, "list-files") == 0) {
        if (argc < 3) {
            printf("Error: list-files requires <file>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            result = listFiles(storePath);
        }
    } else if (strcmp(command, "validate") == 0) {
        if (argc < 3) {
            printf("Error: validate requires <file>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            result = validateFile(storePath);
        }
    } else if (strcmp(command, "get-icon-pos") == 0) {
        // Legacy alias for get-icon
        if (argc < 4) {
            printf("Error: get-icon-pos requires <file> <filename>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            NSString *filename = [NSString stringWithUTF8String:argv[3]];
            result = getIconPosition(storePath, filename);
        }
    } else if (strcmp(command, "set-icon-pos") == 0) {
        // Legacy alias for set-icon
        if (argc < 6) {
            printf("Error: set-icon-pos requires <file> <filename> <x> <y>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            NSString *filename = [NSString stringWithUTF8String:argv[3]];
            int x = atoi(argv[4]);
            int y = atoi(argv[5]);
            result = setIconPosition(storePath, filename, x, y);
        }
    } else if (strcmp(command, "set-background") == 0) {
        if (argc < 4) {
            printf("Error: set-background requires <file> <type> [options]\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            const char *type = argv[3];
            result = setBackground(storePath, type, argc, argv, 4);
        }
    } else if (strcmp(command, "set-view") == 0) {
        if (argc < 4) {
            printf("Error: set-view requires <file> <type> [options]\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            const char *type = argv[3];
            result = setView(storePath, type, argc, argv, 4);
        }
    } else if (strcmp(command, "remove-entry") == 0) {
        if (argc < 5) {
            printf("Error: remove-entry requires <file> <filename> <code>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            NSString *filename = [NSString stringWithUTF8String:argv[3]];
            NSString *code = [NSString stringWithUTF8String:argv[4]];
            result = removeEntry(storePath, filename, code);
        }
    } else if (strcmp(command, "info") == 0) {
        if (argc < 3) {
            printf("Error: info command requires path\n");
            result = 1;
        } else {
            NSString *path = [NSString stringWithUTF8String:argv[2]];
            result = showInfo(path);
        }
    } else {
        printf("Error: Unknown command: %s\n", command);
        printUsage();
        result = 1;
    }
    
    [pool drain];
    return result;
}

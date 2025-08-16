#import <Foundation/Foundation.h>
#import "DSStore.h"
#import "DSStoreEntry.h"

void printUsage(void) {
    printf("libDSStore command line tool\n\n");
    printf("Usage:\n");
    printf("  dsstore list [path]                    List entries in .DS_Store file\n");
    printf("  dsstore create <path>                  Create new empty .DS_Store file\n");
    printf("  dsstore set-icon-pos <file> <filename> <x> <y>  Set icon position\n");
    printf("  dsstore get-icon-pos <file> <filename> Get icon position\n");
    printf("  dsstore set-background <file> <type> [value]   Set background (color/image)\n");
    printf("  dsstore set-view <file> <type> [options]       Set view settings\n");
    printf("  dsstore remove-entry <file> <filename> <code>  Remove specific entry\n");
    printf("  dsstore info <file>                    Show file information\n");
    printf("\nBackground types:\n");
    printf("  color <r> <g> <b>     Set background color (0.0-1.0)\n");
    printf("  image <path>          Set background image\n");
    printf("  default               Use default background\n");
    printf("\nView types:\n");
    printf("  icon <size>           Icon view with icon size\n");
    printf("  list                  List view\n");
    printf("\nExamples:\n");
    printf("  dsstore list\n");
    printf("  dsstore create new.DS_Store\n");
    printf("  dsstore set-icon-pos .DS_Store file.txt 100 150\n");
    printf("  dsstore set-background .DS_Store color 1.0 0.8 0.6\n");
    printf("  dsstore set-view .DS_Store icon 64\n");
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
    
    NSDictionary *location = [store iconLocationForFilename:filename];
    if (location) {
        NSNumber *x = [location objectForKey:@"x"];
        NSNumber *y = [location objectForKey:@"y"];
        printf("Icon position for %s: (%d, %d)\n", 
               [filename UTF8String], [x intValue], [y intValue]);
    } else {
        printf("No icon position set for %s\n", [filename UTF8String]);
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
    } else if (strcmp(command, "get-icon-pos") == 0) {
        if (argc < 4) {
            printf("Error: get-icon-pos requires <file> <filename>\n");
            result = 1;
        } else {
            NSString *storePath = [NSString stringWithUTF8String:argv[2]];
            NSString *filename = [NSString stringWithUTF8String:argv[3]];
            result = getIconPosition(storePath, filename);
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

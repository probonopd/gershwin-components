//
//  DSStore.m
//  libDSStore
//
//  Main DS_Store functionality
//  Based on .DS_Store format specification
//

#import "DSStore.h"
#import "DSStoreCodecs.h"

// Constants from .DS_Store format specification
#define DSDB_MAGIC 0x44534442  // "DSDB"

// Byte swapping functions
static uint32_t swapBytes32(uint32_t x) {
    return ((x & 0xFF000000) >> 24) | ((x & 0x00FF0000) >> 8) |
           ((x & 0x0000FF00) << 8)  | ((x & 0x000000FF) << 24);
}

@implementation DSStore

+ (id)storeWithPath:(NSString *)path {
    return [[[self alloc] initWithPath:path] autorelease];
}

+ (id)createStoreAtPath:(NSString *)path withEntries:(NSArray *)entries {
    DSStore *store = [[[self alloc] initWithPath:path] autorelease];
    if (!store) {
        return nil;
    }
    
    // Initialize with provided entries
    if (entries) {
        [store->_entries addObjectsFromArray:entries];
    }
    
    store->_isLoaded = YES;
    return store;
}

- (id)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _filePath = [path copy];
        _allocator = nil;
        _entries = [[NSMutableArray alloc] init];
        _isLoaded = NO;
    }
    return self;
}

- (void)dealloc {
    [_filePath release];
    [_allocator release];
    [_entries release];
    [super dealloc];
}

- (NSString *)filePath {
    return _filePath;
}

- (NSArray *)entries {
    if (!_isLoaded) {
        [self load];
    }
    return [NSArray arrayWithArray:_entries];
}

- (BOOL)load {
    // Initialize buddy allocator
    _allocator = [[DSBuddyAllocator alloc] initWithFile:_filePath];
    if (![_allocator open]) {
        return NO;
    }
    
    // Check file size
    NSUInteger fileSize = [_allocator fileSize];
    if (fileSize < 36) {
        return NO;
    }
    
    // Read buddy allocator header (first 32 bytes)
    DSBuddyBlock *headerBlock = [_allocator blockAtOffset:0 size:32];
    if (!headerBlock) {
        return NO;
    }
    
    // Check buddy allocator magic
    uint32_t magic1 = [headerBlock readUInt32];
    uint32_t magic2 = [headerBlock readUInt32];
    
    if (magic1 != 0x00000001 || magic2 != 0x42756431) { // "Bud1"
        [headerBlock close];
        return NO;
    }
    
    // Read offset and size of root block
    uint32_t rootOffset = [headerBlock readUInt32];
    uint32_t rootSize = [headerBlock readUInt32];
    uint32_t rootOffset2 __attribute__((unused)) = [headerBlock readUInt32]; // Duplicate
    
    [headerBlock close];
    
    // Validate offsets
    if (rootOffset >= fileSize || rootOffset + rootSize > fileSize) {
        return NO;
    }
    
    // Read root block (contains B-tree superblock)
    DSBuddyBlock *rootBlock = [_allocator blockAtOffset:rootOffset size:rootSize];
    if (!rootBlock) {
        return NO;
    }
    
    // Read block offsets count and unknown value
    uint32_t offsetCount = [rootBlock readUInt32];
    uint32_t unknown2 __attribute__((unused)) = [rootBlock readUInt32];
    
    // Read offset table (count padded to 256 boundary)
    // Some files have offsetCount=0, others have offsetCount=1
    uint32_t paddedCount = (offsetCount + 255) & ~255;
    if (paddedCount == 0) paddedCount = 256; // Handle offsetCount=0 case
    
    NSMutableArray *offsets = [NSMutableArray arrayWithCapacity:offsetCount];
    for (uint32_t i = 0; i < paddedCount; i++) {
        uint32_t offset = [rootBlock readUInt32];
        if (i < offsetCount) {
            [offsets addObject:[NSNumber numberWithUnsignedInt:offset]];
        }
    }
    
    // Now read TOC count first
    uint32_t tocCount = [rootBlock readUInt32];
    
    // Look for DSDB entry in ToC
    uint32_t dsdbOffset = 0;
    for (uint32_t i = 0; i < tocCount; i++) {
        uint8_t nameLen = [rootBlock readUInt8];
        NSData *nameData = [rootBlock readBytes:nameLen];
        uint32_t directOffset = [rootBlock readUInt32];
        
        NSString *name = [[NSString alloc] initWithData:nameData encoding:NSASCIIStringEncoding];
        
        if ([name isEqualToString:@"DSDB"]) {
            dsdbOffset = directOffset;
        }
        [name release];
    }
    
    // Skip free lists (32 lists) - NOTE: This comes AFTER the TOC
    for (int i = 0; i < 32; i++) {
        uint32_t freeCount = [rootBlock readUInt32];
        [rootBlock seek:[rootBlock tell] + (freeCount * 4)];
    }
    
    [rootBlock close];
    
    if (dsdbOffset == 0) {
        return NO;
    }

    // Read DSDB block (B-tree header is 20 bytes: 5 uint32_t values)
    DSBuddyBlock *dsdbBlock = [_allocator blockAtOffset:dsdbOffset size:20];
    if (!dsdbBlock) {
        NSLog(@"Failed to read DSDB block at offset %u", dsdbOffset);
        return NO;
    }
    
    NSLog(@"DEBUG: DSDB block read successfully");
    
    // Read B-tree header
    uint32_t rootAddress = [dsdbBlock readUInt32];
    uint32_t levelsNumber = [dsdbBlock readUInt32];
    uint32_t recordsNumber = [dsdbBlock readUInt32];
    uint32_t nodesNumber = [dsdbBlock readUInt32];
    uint32_t pageSize = [dsdbBlock readUInt32];
    
    NSLog(@"B-tree info: rootAddr=%u levels=%u records=%u nodes=%u pageSize=%u",
          rootAddress, levelsNumber, recordsNumber, nodesNumber, pageSize);
    
    [_entries removeAllObjects];
    
    if (recordsNumber == 0) {
        NSLog(@"Empty B-tree");
        [dsdbBlock close];
        _isLoaded = YES;
        return YES;
    }
    
    [dsdbBlock close];
    
    // B-tree root address is relative to file start
    // Calculate the size of B-tree data (remaining file size)
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSDictionary *fileAttrs = [fileManager attributesOfItemAtPath:_filePath error:&error];
    NSUInteger totalFileSize = [[fileAttrs objectForKey:NSFileSize] unsignedIntegerValue];
    NSUInteger btreeOffset = dsdbOffset + rootAddress;
    NSUInteger btreeSize = totalFileSize - btreeOffset;
    
    // Read B-tree data from the correct location
    DSBuddyBlock *btreeBlock = [_allocator blockAtOffset:btreeOffset size:btreeSize];
    if (!btreeBlock) {
        NSLog(@"Failed to read B-tree block");
        return NO;
    }
    
    @try {
        [self readBTreeNode:btreeBlock address:0 isLeaf:(levelsNumber == 1)];
        _isLoaded = YES;
        [btreeBlock close];
        return YES;
    }
    @catch (NSException *exception) {
        NSLog(@"Error parsing B-tree: %@", [exception description]);
        [btreeBlock close];
        return NO;
    }
}

- (void)readBTreeNode:(DSBuddyBlock *)block address:(uint32_t)address isLeaf:(BOOL)isLeaf {
    [block seek:address];
    
    uint32_t nodeKind = [block readUInt32];
    uint32_t recordCount = [block readUInt32];
    
    NSLog(@"Node at %u: kind=%u count=%u isLeaf=%d", address, nodeKind, recordCount, isLeaf);
    
    if (isLeaf) {
        // Leaf node - contains actual entries
        for (uint32_t i = 0; i < recordCount; i++) {
            // Read filename length and filename (UTF-16BE)
            uint32_t nameLen = [block readUInt32];
            NSData *nameData = [block readBytes:(nameLen * 2)];
            NSString *filename = [[NSString alloc] initWithData:nameData encoding:NSUTF16BigEndianStringEncoding];
            
            // Read code (4 bytes, null-terminated)
            NSData *codeData = [block readBytes:4];
            NSString *code = [[NSString alloc] initWithData:codeData encoding:NSASCIIStringEncoding];
            code = [code stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\0"]];
            
            // Read type (4 bytes, null-terminated)
            NSData *typeData = [block readBytes:4];
            NSString *type = [[NSString alloc] initWithData:typeData encoding:NSASCIIStringEncoding];
            type = [type stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\0"]];
            
            // Read value based on type
            id value = nil;
            if ([type isEqualToString:@"bool"]) {
                uint8_t boolVal = [block readUInt8];
                value = [NSNumber numberWithBool:(boolVal != 0)];
            } else if ([type isEqualToString:@"long"] || [type isEqualToString:@"shor"]) {
                uint32_t intVal = [block readUInt32];
                value = [NSNumber numberWithUnsignedInt:intVal];
            } else if ([type isEqualToString:@"blob"]) {
                uint32_t blobLen = [block readUInt32];
                value = [block readBytes:blobLen];
            } else if ([type isEqualToString:@"ustr"]) {
                uint32_t strLen = [block readUInt32];
                NSData *strData = [block readBytes:(strLen * 2)];
                value = [[NSString alloc] initWithData:strData encoding:NSUTF16BigEndianStringEncoding];
            } else if ([type isEqualToString:@"type"]) {
                NSData *typeValue = [block readBytes:4];
                value = [[NSString alloc] initWithData:typeValue encoding:NSASCIIStringEncoding];
            } else if ([type isEqualToString:@"comp"] || [type isEqualToString:@"dutc"]) {
                uint64_t longVal = [block readUInt64];
                value = [NSNumber numberWithUnsignedLongLong:longVal];
            }
            
            DSStoreEntry *entry = [[DSStoreEntry alloc] initWithFilename:filename 
                                                                    code:code 
                                                                    type:type
                                                                   value:value];
            [_entries addObject:entry];
            [entry release];
            [filename release];
            [code release];
            [type release];
            if ([type isEqualToString:@"ustr"] || [type isEqualToString:@"type"]) {
                [value release];
            }
            
            NSLog(@"Entry: %@ -> %@ (%@)", filename, code, value);
        }
    } else {
        // Internal node - contains pointers to other nodes
        for (uint32_t i = 0; i < recordCount; i++) {
            uint32_t nameLen = [block readUInt32];
            NSData *nameData = [block readBytes:(nameLen * 2)];
            NSString *filename = [[NSString alloc] initWithData:nameData encoding:NSUTF16BigEndianStringEncoding];
            
            NSData *codeData = [block readBytes:4];
            NSString *code = [[NSString alloc] initWithData:codeData encoding:NSASCIIStringEncoding];
            
            uint32_t pointer = [block readUInt32];
            
            // Recursively read child node
            [self readBTreeNode:block address:pointer isLeaf:NO];
            
            [filename release];
            [code release];
        }
    }
}

- (BOOL)save {
    if (!_isLoaded) {
        NSLog(@"Cannot save unloaded store");
        return NO;
    }
    
    NSMutableData *fileData = [NSMutableData data];
    
    // Write the buddy allocator header per .DS_Store specification
    struct {
        uint32_t magic1;        // 1
        uint32_t magic2;        // "Bud1"
        uint32_t rootOffset;    // 2048
        uint32_t headerSize;    // 1264  
        uint32_t rootOffset2;   // 2048 (duplicate)
        uint32_t padding[4];    // Padding to align
    } header;
    
    header.magic1 = swapBytes32(1);
    header.magic2 = swapBytes32(0x42756431);  // "Bud1"
    header.rootOffset = swapBytes32(2048);
    header.headerSize = swapBytes32(1264);
    header.rootOffset2 = swapBytes32(2048);
    header.padding[0] = 0;
    header.padding[1] = swapBytes32(0x0010000C);
    header.padding[2] = swapBytes32(0x00000087);
    header.padding[3] = swapBytes32(0x0020000B);
    
    [fileData appendBytes:&header length:sizeof(header)];
    
    // Pad to 2048 bytes for root block
    NSUInteger paddingSize = 2048 - [fileData length];
    char *padding = calloc(paddingSize, 1);
    [fileData appendBytes:padding length:paddingSize];
    free(padding);
    
    // Write root block (buddy allocator metadata)
    // Root block structure compatible with reference implementation:
    // - offset count (0) - this is what the reference library expects!
    // - unknown (0) 
    // - 256 padding entries (since count is 0, all are padding)
    // - ToC count (1 for DSDB)
    // - ToC entry: "DSDB" -> offset
    // - Free lists
    
    uint32_t offsetCount = swapBytes32(0);  // Changed from 1 to 0!
    uint32_t unknown = swapBytes32(0);
    uint32_t dsdbBlockOffset = 2048 + 1264; // After root block
    
    [fileData appendBytes:&offsetCount length:4];
    [fileData appendBytes:&unknown length:4];
    
    // 256 padding entries (since offset count is 0)
    for (int i = 0; i < 256; i++) {
        uint32_t zero = 0;
        [fileData appendBytes:&zero length:4];
    }
    
    // ToC: 1 entry for DSDB
    uint32_t tocCount = swapBytes32(1);
    [fileData appendBytes:&tocCount length:4];
    
    // ToC entry: length (4) + "DSDB" + offset
    uint8_t nameLen = 4;
    [fileData appendBytes:&nameLen length:1];
    [fileData appendBytes:"DSDB" length:4];
    uint32_t dsdbOffset = swapBytes32(dsdbBlockOffset);
    [fileData appendBytes:&dsdbOffset length:4];
    
    // Free lists (simplified - mostly zeros for small files)
    // 32 free list entries * 4 bytes each for count + data
    for (int i = 0; i < 32; i++) {
        uint32_t freeCount = 0;
        [fileData appendBytes:&freeCount length:4];
    }
    
    // Pad to end of root block (1264 bytes total)
    NSUInteger currentSize = [fileData length] - 2048;
    if (currentSize < 1264) {
        NSUInteger remaining = 1264 - currentSize;
        char *rootPadding = calloc(remaining, 1);
        [fileData appendBytes:rootPadding length:remaining];
        free(rootPadding);
    }
    
    // Write DSDB block 
    uint32_t btreeRoot = swapBytes32(20);  // B-tree data starts after DSDB header
    uint32_t levels = swapBytes32(1);      // Single level (leaf only)
    uint32_t records = swapBytes32([_entries count]);
    uint32_t nodes = swapBytes32(1);       // Single node
    uint32_t pageSize = swapBytes32(4096);
    
    [fileData appendBytes:&btreeRoot length:4];
    [fileData appendBytes:&levels length:4];
    [fileData appendBytes:&records length:4];
    [fileData appendBytes:&nodes length:4];
    [fileData appendBytes:&pageSize length:4];
    
    // Write B-tree leaf node
    uint32_t nodeType = swapBytes32(0);              // Leaf node
    uint32_t entryCount = [_entries count];
    uint32_t recordCount = swapBytes32(entryCount);
    
    NSLog(@"DEBUG SAVE: Writing %u entries, swapped recordCount=0x%08x", entryCount, recordCount);
    
    [fileData appendBytes:&nodeType length:4];
    [fileData appendBytes:&recordCount length:4];
    
    // Sort entries as required by .DS_Store format
    NSArray *sortedEntries = [_entries sortedArrayUsingSelector:@selector(compare:)];
    
    // Write entries
    for (DSStoreEntry *entry in sortedEntries) {
        NSData *entryData = [entry encode];
        if (entryData) {
            [fileData appendData:entryData];
        }
    }
    
    // Write to file
    NSError *error = nil;
    BOOL success = [fileData writeToFile:_filePath 
                                 options:NSDataWritingAtomic 
                                   error:&error];
    
    if (!success) {
        NSLog(@"Failed to write .DS_Store file: %@", [error localizedDescription]);
        return NO;
    }
    
    NSLog(@"Saved .DS_Store file: %@ (%lu bytes)", _filePath, (unsigned long)[fileData length]);
    return YES;
}

- (DSStoreEntry *)entryForFilename:(NSString *)filename code:(NSString *)code {
    if (!_isLoaded) {
        [self load];
    }
    
    for (DSStoreEntry *entry in _entries) {
        if ([[entry filename] isEqualToString:filename] && 
            [[entry code] isEqualToString:code]) {
            return entry;
        }
    }
    return nil;
}

- (void)setEntry:(DSStoreEntry *)entry {
    if (!_isLoaded) {
        [self load];
    }
    
    // Remove existing entry with same filename and code
    DSStoreEntry *existing = [self entryForFilename:[entry filename] code:[entry code]];
    if (existing) {
        [_entries removeObject:existing];
    }
    
    [_entries addObject:entry];
}

- (void)removeEntryForFilename:(NSString *)filename code:(NSString *)code {
    if (!_isLoaded) {
        [self load];
    }
    
    DSStoreEntry *entry = [self entryForFilename:filename code:code];
    if (entry) {
        [_entries removeObject:entry];
    }
}

// Convenience methods for common entries
- (NSDictionary *)iconLocationForFilename:(NSString *)filename {
    DSStoreEntry *entry = [self entryForFilename:filename code:@"Iloc"];
    if (entry && [[entry code] isEqualToString:@"Iloc"]) {
        NSData *data = (NSData *)[entry value];
        return [DSILocCodec decodeData:data];
    }
    return nil;
}

- (void)setIconLocation:(NSDictionary *)location forFilename:(NSString *)filename {
    NSData *encodedData = [DSILocCodec encodeValue:location];
    DSStoreEntry *entry = [[DSStoreEntry alloc] initWithFilename:filename 
                                                            code:@"Iloc" 
                                                            type:@"blob"
                                                           value:encodedData];
    [self setEntry:entry];
    [entry release];
}

- (NSDictionary *)backgroundPictureForDirectory {
    DSStoreEntry *entry = [self entryForFilename:@"." code:@"bwsp"];
    if (!entry) {
        entry = [self entryForFilename:@"." code:@"pBBk"];
    }
    
    if (entry && ([[entry code] isEqualToString:@"bwsp"] || [[entry code] isEqualToString:@"pBBk"])) {
        return (NSDictionary *)[entry value];
    }
    return nil;
}

- (void)setBackgroundPicture:(NSDictionary *)pictureInfo {
    DSStoreEntry *entry = [[DSStoreEntry alloc] initWithFilename:@"." 
                                                            code:@"bwsp" 
                                                            type:@"blob"
                                                           value:pictureInfo];
    [self setEntry:entry];
    [entry release];
}

- (NSDictionary *)listViewSettingsForDirectory {
    DSStoreEntry *entry = [self entryForFilename:@"." code:@"lsvp"];
    if (!entry) {
        entry = [self entryForFilename:@"." code:@"lsvP"];
    }
    
    if (entry && ([[entry code] isEqualToString:@"lsvp"] || [[entry code] isEqualToString:@"lsvP"])) {
        // The value should be a blob containing plist data - just return the raw value for now
        return (NSDictionary *)[entry value];
    }
    return nil;
}

- (void)setListViewSettings:(NSDictionary *)settings {
    DSStoreEntry *entry = [[DSStoreEntry alloc] initWithFilename:@"." 
                                                            code:@"lsvp" 
                                                            type:@"blob"
                                                           value:settings];
    [self setEntry:entry];
    [entry release];
}

- (NSDictionary *)iconViewSettingsForDirectory {
    DSStoreEntry *entry = [self entryForFilename:@"." code:@"icvp"];
    if (!entry) {
        entry = [self entryForFilename:@"." code:@"icvP"];
    }
    
    if (entry && ([[entry code] isEqualToString:@"icvp"] || [[entry code] isEqualToString:@"icvP"])) {
        // The value should be a blob containing plist data - just return the raw value for now
        return (NSDictionary *)[entry value];
    }
    return nil;
}

- (void)setIconViewSettings:(NSDictionary *)settings {
    DSStoreEntry *entry = [[DSStoreEntry alloc] initWithFilename:@"." 
                                                            code:@"icvp" 
                                                            type:@"blob"
                                                           value:settings];
    [self setEntry:entry];
    [entry release];
}

@end

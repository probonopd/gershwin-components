//
//  DSStore.m
//  libDSStore
//
//  Main DS_Store functionality
//  Based on .DS_Store format specification
//

#import "DSStore.h"
#import "DSStoreCodecs.h"

// Byte order conversion macros for GNUstep
#define CFSwapInt32BigToHost(x) NSSwapBigIntToHost(x)
#define CFSwapInt16BigToHost(x) NSSwapBigShortToHost(x)

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
    
    // Read root block (contains buddy allocator metadata)
    // NOTE: Reference library skips first 4 bytes of root block
    DSBuddyBlock *rootBlock = [_allocator blockAtOffset:rootOffset + 4 size:rootSize - 4];
    if (!rootBlock) {
        return NO;
    }
    
    // Read block offsets count and unknown value
    uint32_t offsetCount = [rootBlock readUInt32];
    uint32_t unknown2 __attribute__((unused)) = [rootBlock readUInt32];
    
    NSLog(@"Root block: offsetCount=%u, unknown=%u", offsetCount, unknown2);
    
    // Read offset table (always 256 entries, padded with zeros)
    NSMutableArray *offsets = [NSMutableArray arrayWithCapacity:offsetCount];
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t offset = [rootBlock readUInt32];
        if (i < offsetCount) {
            [offsets addObject:[NSNumber numberWithUnsignedInt:offset]];
            NSLog(@"Offset[%u]: 0x%08x", i, offset);
        }
    }
    
    // Read TOC count
    uint32_t tocCount = [rootBlock readUInt32];
    NSLog(@"TOC count: %u", tocCount);
    
    // Parse ALL directory entries robustly (not just DSDB)
    NSMutableDictionary *directoryEntries = [NSMutableDictionary dictionaryWithCapacity:tocCount];
    for (uint32_t i = 0; i < tocCount; i++) {
        uint8_t nameLen = [rootBlock readUInt8];
        NSData *nameData = [rootBlock readBytes:nameLen];
        uint32_t blockNum = [rootBlock readUInt32];
        
        NSString *name = [[NSString alloc] initWithData:nameData encoding:NSASCIIStringEncoding];
        NSLog(@"TOC[%u]: name='%@' -> block %u", i, name, blockNum);
        
        // Store ALL directory entries for future extensibility
        [directoryEntries setObject:[NSNumber numberWithUnsignedInt:blockNum] forKey:name];
        [name release];
    }
    
    [rootBlock close];
    
    // Look for DSDB directory entry (robust approach)
    NSNumber *dsdbBlockNumObj = [directoryEntries objectForKey:@"DSDB"];
    if (!dsdbBlockNumObj) {
        NSLog(@"DSDB directory not found in TOC");
        return NO;
    }
    
    uint32_t dsdbBlockNum = [dsdbBlockNumObj unsignedIntValue];
    if (dsdbBlockNum >= [offsets count]) {
        NSLog(@"DSDB block number %u exceeds offset table size %lu", dsdbBlockNum, (unsigned long)[offsets count]);
        return NO;
    }
    
    // Get DSDB block address from offset table
    uint32_t dsdbAddr = [[offsets objectAtIndex:dsdbBlockNum] unsignedIntValue];
    uint32_t dsdbOffset = dsdbAddr & ~0x1F;  // Remove size bits
    uint32_t dsdbSize = 1 << (dsdbAddr & 0x1F);  // Extract size bits
    
    NSLog(@"DSDB block %u: addr=0x%08x, offset=0x%x, size=%u", dsdbBlockNum, dsdbAddr, dsdbOffset, dsdbSize);
    
    // Read DSDB superblock (NOTE: +4 for reference library file offset correction)
    DSBuddyBlock *dsdbBlock = [_allocator blockAtOffset:dsdbOffset + 4 size:dsdbSize];
    if (!dsdbBlock) {
        NSLog(@"Failed to read DSDB block at offset %u", dsdbOffset + 4);
        return NO;
    }
    
    // Read DSDB superblock header (5 uint32_t values)
    uint32_t rootAddress = [dsdbBlock readUInt32];
    uint32_t levelsNumber = [dsdbBlock readUInt32];
    uint32_t recordsNumber = [dsdbBlock readUInt32];
    uint32_t nodesNumber = [dsdbBlock readUInt32];
    uint32_t pageSize = [dsdbBlock readUInt32];
    
    NSLog(@"DSDB: rootAddr=%u levels=%u records=%u nodes=%u pageSize=%u",
          rootAddress, levelsNumber, recordsNumber, nodesNumber, pageSize);
    
    [_entries removeAllObjects];
    
    if (recordsNumber == 0) {
        NSLog(@"Empty B-tree");
        [dsdbBlock close];
        _isLoaded = YES;
        return YES;
    }
    
    [dsdbBlock close];
    
    // The B-tree root address points to another block in the offset table
    // If rootAddress >= offsetCount, it's likely an offset relative to DSDB block
    if (rootAddress < [offsets count]) {
        // Root address is a block number
        uint32_t btreeAddr = [[offsets objectAtIndex:rootAddress] unsignedIntValue];
        uint32_t btreeOffset = btreeAddr & ~0x1F;
        uint32_t btreeSize = 1 << (btreeAddr & 0x1F);
        
        NSLog(@"B-tree block %u: addr=0x%08x, offset=0x%x, size=%u", rootAddress, btreeAddr, btreeOffset, btreeSize);
        
        // Read B-tree data (+4 for file offset correction)
        DSBuddyBlock *btreeBlock = [_allocator blockAtOffset:btreeOffset + 4 size:btreeSize - 4];
        if (!btreeBlock) {
            NSLog(@"Failed to read B-tree block");
            return NO;
        }
        
        @try {
            [self readBTreeNode:btreeBlock address:0 isLeaf:(levelsNumber <= 1)];
            _isLoaded = YES;
            [btreeBlock close];
            return YES;
        }
        @catch (NSException *exception) {
            NSLog(@"Error parsing B-tree: %@", [exception description]);
            [btreeBlock close];
            return NO;
        }
    } else {
        // Root address is relative to DSDB block
        // Seek to rootAddress within DSDB block data 
        NSUInteger btreeOffset = dsdbOffset + 4 + rootAddress;
        NSUInteger btreeSize = pageSize;  // Use pageSize from DSDB
        
        NSLog(@"B-tree at relative offset %u (absolute 0x%lx), size=%lu", rootAddress, (unsigned long)btreeOffset, (unsigned long)btreeSize);
        
        // Read B-tree data
        DSBuddyBlock *btreeBlock = [_allocator blockAtOffset:btreeOffset size:btreeSize - 4];
        if (!btreeBlock) {
            NSLog(@"Failed to read B-tree block at relative offset");
            return NO;
        }
        
        @try {
            [self readBTreeNode:btreeBlock address:0 isLeaf:(levelsNumber <= 1)];
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
}

- (void)readBTreeNode:(DSBuddyBlock *)block address:(uint32_t)address isLeaf:(BOOL)isLeaf {
    NSLog(@"Reading B-tree node at address 0x%x, isLeaf: %@", address, isLeaf ? @"YES" : @"NO");
    
    uint32_t nodeId = [block readUInt32];
    uint32_t recordsCount = [block readUInt32];
    
    NSLog(@"Node ID: 0x%x, Records count: %u", nodeId, recordsCount);
    
    if (isLeaf) {
        // Read leaf records (actual DS_Store entries)
        for (uint32_t i = 0; i < recordsCount; i++) {
            NSLog(@"Reading leaf record %u", i);
            
            uint32_t filenameLength = [block readUInt32];
            if (filenameLength == 0 || filenameLength > 1024) {
                NSLog(@"Invalid filename length: %u", filenameLength);
                break;
            }
            
            NSData *unicodeData = [block readBytes:filenameLength * 2];
            NSString *filename = [[NSString alloc] initWithData:unicodeData encoding:NSUTF16BigEndianStringEncoding];
            
            // Read code (4 bytes ASCII)
            NSData *codeData = [block readBytes:4];
            NSString *code = [[NSString alloc] initWithData:codeData encoding:NSASCIIStringEncoding];
            
            // Read type (4 bytes ASCII)  
            NSData *typeData = [block readBytes:4];
            NSString *type = [[NSString alloc] initWithData:typeData encoding:NSASCIIStringEncoding];
            
            NSLog(@"Entry: filename='%@', code='%@', type='%@'", filename, code, type);
            
            // Read value based on type
            id value = nil;
            if ([type isEqualToString:@"bool"]) {
                uint8_t boolVal = [block readUInt8];
                value = [NSNumber numberWithBool:(boolVal != 0)];
            } else if ([type isEqualToString:@"long"]) {
                uint32_t intVal = [block readUInt32];
                value = [NSNumber numberWithUnsignedInt:intVal];
            } else if ([type isEqualToString:@"shor"]) {
                uint16_t shortVal = [block readUInt16];
                value = [NSNumber numberWithUnsignedShort:shortVal];
            } else if ([type isEqualToString:@"blob"]) {
                uint32_t blobLen = [block readUInt32];
                if (blobLen > 0 && blobLen < 65536) {
                    value = [block readBytes:blobLen];
                }
            } else if ([type isEqualToString:@"ustr"]) {
                uint32_t strLen = [block readUInt32];
                if (strLen > 0 && strLen < 1024) {
                    NSData *strData = [block readBytes:strLen * 2];
                    value = [[NSString alloc] initWithData:strData encoding:NSUTF16BigEndianStringEncoding];
                }
            } else if ([type isEqualToString:@"type"]) {
                NSData *typeValue = [block readBytes:4];
                value = [[NSString alloc] initWithData:typeValue encoding:NSASCIIStringEncoding];
            } else if ([type isEqualToString:@"comp"]) {
                uint64_t longVal = [block readUInt64];
                value = [NSNumber numberWithUnsignedLongLong:longVal];
            } else if ([type isEqualToString:@"dutc"]) {
                uint64_t longVal = [block readUInt64];
                value = [NSNumber numberWithUnsignedLongLong:longVal];
            } else {
                // Unknown type - try to read as blob
                uint32_t valueLen = [block readUInt32];
                if (valueLen > 0 && valueLen < 65536) {
                    value = [block readBytes:valueLen];
                }
            }
            
            DSStoreEntry *entry = [[DSStoreEntry alloc] initWithFilename:filename
                                                                     code:code
                                                                     type:type
                                                                    value:value];
            if (entry) {
                [_entries addObject:entry];
                [entry release];
            }
            [filename release];
            [code release];
            [type release];
            if ([type isEqualToString:@"ustr"] || [type isEqualToString:@"type"]) {
                [value release];
            }
        }
    } else {
        // Read internal node pointers
        for (uint32_t i = 0; i < recordsCount; i++) {
            NSLog(@"Reading internal record %u", i);
            
            uint32_t childAddress = [block readUInt32];
            uint32_t filenameLength = [block readUInt32];
            
            if (filenameLength > 0 && filenameLength < 1024) {
                NSData *unicodeData = [block readBytes:filenameLength * 2];
                // Skip the filename for internal nodes
            }
            
            // Recursively read child node
            if (childAddress != 0) {
                NSLog(@"Following child pointer to address 0x%x", childAddress);
                
                // Decode child address
                uint32_t childOffset = childAddress & ~0x1F;
                uint32_t childSizeBits = childAddress & 0x1F;
                uint32_t childSize = 1 << childSizeBits;
                
                DSBuddyBlock *childBlock = [_allocator blockAtOffset:childOffset size:childSize];
                if (childBlock) {
                    [self readBTreeNode:childBlock address:childOffset isLeaf:YES]; // Assume next level is leaf for now
                    [childBlock close];
                }
            }
        }
    }
}

- (BOOL)save {
    if (!_isLoaded) {
        NSLog(@"Cannot save unloaded store");
        return NO;
    }
    
    NSMutableData *fileData = [NSMutableData data];
    
    // Write the buddy allocator header
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
    header.headerSize = swapBytes32(2048);  // Changed to 2048
    header.rootOffset2 = swapBytes32(2048);
    // Write padding values directly as they appear in reference file
    header.padding[0] = 0x0C100000;  // Will be stored as: 00 00 10 0c
    header.padding[1] = 0x87000000;  // Will be stored as: 00 00 00 87  
    header.padding[2] = 0x0B200000;  // Will be stored as: 00 00 20 0b
    header.padding[3] = 0;
    
    [fileData appendBytes:&header length:sizeof(header)];
    
    // Pad to 2048 bytes for root block
    NSUInteger paddingSize = 2048 - [fileData length];
    char *padding = calloc(paddingSize, 1);
    [fileData appendBytes:padding length:paddingSize];
    free(padding);
    
    // Write root block (buddy allocator metadata) 
    // NOTE: The reference library skips the first 4 bytes of the root block!
    // So we need to write 4 dummy bytes first
    uint32_t dummy = 0;
    [fileData appendBytes:&dummy length:4];
    
    // Now write the actual root block content that reference library will read
    // Match reference implementation structure exactly:
    // - offset count (3) - like reference
    // - unknown (varies) 
    // - offset entries (3 real entries + 253 padding)
    // - ToC count (1 for DSDB)
    // - ToC entry: "DSDB" -> block number 1
    // - Free lists (32 entries with counts + offsets)
    
    uint32_t offsetCount = swapBytes32(3);  // Like reference - 3 allocated blocks
    uint32_t unknown = swapBytes32(0);      
    
    // Block addresses like reference:
    // Block 0: 0x80b (offset=0x800, size=2048) - root block
    // Block 1: 0x25 (offset=0x20, size=32) - DSDB superblock  
    // Block 2: 0x200d (offset=0x2000, size=8192) - B-tree data
    uint32_t rootBlockAddr = 0x800 | 11;  // 2048 = 2^11
    uint32_t dsdbBlockAddr = 0x20 | 5;    // 32 = 2^5  
    uint32_t btreeBlockAddr = 0x2000 | 13; // 8192 = 2^13
    
    [fileData appendBytes:&offsetCount length:4];
    [fileData appendBytes:&unknown length:4];
    
    // 3 real offset entries + 253 zeros
    uint32_t offset0 = swapBytes32(rootBlockAddr);
    uint32_t offset1 = swapBytes32(dsdbBlockAddr);
    uint32_t offset2 = swapBytes32(btreeBlockAddr);
    [fileData appendBytes:&offset0 length:4];
    [fileData appendBytes:&offset1 length:4];
    [fileData appendBytes:&offset2 length:4];
    
    // 253 padding entries
    for (int i = 3; i < 256; i++) {
        uint32_t zero = 0;
        [fileData appendBytes:&zero length:4];
    }
    
    // ToC: 1 entry for DSDB
    uint32_t tocCount = swapBytes32(1);
    [fileData appendBytes:&tocCount length:4];
    
    // ToC entry: length (4) + "DSDB" + block_number (1 - like reference)
    uint8_t nameLen = 4;
    [fileData appendBytes:&nameLen length:1];
    [fileData appendBytes:"DSDB" length:4];
    uint32_t dsdbBlockNum = swapBytes32(1); // Block 1 like reference
    [fileData appendBytes:&dsdbBlockNum length:4];
    
    // Free lists (32 entries matching reference pattern)
    // Reference has specific pattern for buddy allocator
    for (int i = 0; i < 5; i++) {
        uint32_t freeCount = 0;
        [fileData appendBytes:&freeCount length:4];
    }
    // Free blocks of various sizes
    for (int i = 5; i < 31; i++) {
        uint32_t freeCount = swapBytes32(1);
        [fileData appendBytes:&freeCount length:4];
        uint32_t freeOffset = swapBytes32(1 << i);
        [fileData appendBytes:&freeOffset length:4];
    }
    // Last entry
    uint32_t freeCount = 0;
    [fileData appendBytes:&freeCount length:4];
    
    // Pad to end of root block (2048 bytes total)
    NSUInteger currentSize = [fileData length] - 2048;
    if (currentSize < 2048) {
        NSUInteger remaining = 2048 - currentSize;
        char *rootPadding = calloc(remaining, 1);
        [fileData appendBytes:rootPadding length:remaining];
        free(rootPadding);
    }
    
    // Rewind to write DSDB block at offset 0x20 (before root block!)
    NSUInteger dsdbStart = 0x20;
    NSMutableData *tempData = [NSMutableData dataWithData:fileData];
    
    // Create DSDB superblock (32 bytes at offset 0x20)
    uint32_t btreeRoot = swapBytes32(2);   // B-tree is in block 2 (not offset 20!)
    uint32_t levels = swapBytes32(1);      // Single level (leaf only)
    uint32_t records = swapBytes32([_entries count]);
    uint32_t nodes = swapBytes32(1);       // Single node
    uint32_t pageSize = swapBytes32(4096);
    
    // Insert DSDB block data at position 0x24 (like reference file with +4 offset)
    NSMutableData *dsdbData = [NSMutableData data];
    [dsdbData appendBytes:&btreeRoot length:4];
    [dsdbData appendBytes:&levels length:4];
    [dsdbData appendBytes:&records length:4];
    [dsdbData appendBytes:&nodes length:4];
    [dsdbData appendBytes:&pageSize length:4];
    
    // Pad DSDB block to 32 bytes
    while ([dsdbData length] < 32) {
        char zero = 0;
        [dsdbData appendBytes:&zero length:1];
    }
    
    // Replace data at position 0x24 (0x20 + 4 offset)
    [tempData replaceBytesInRange:NSMakeRange(dsdbStart + 4, 32) withBytes:[dsdbData bytes] length:32];
    fileData = tempData;
    
    // Pad to B-tree block start (0x2000)
    NSUInteger btreeStart = 0x2000;
    while ([fileData length] < btreeStart) {
        char zero = 0;
        [fileData appendBytes:&zero length:1];
    }
    
    // Write 4 dummy bytes first (for reference format compatibility)
    uint32_t btreeDummy = 0;
    [fileData appendBytes:&btreeDummy length:4];
    
    // Write B-tree leaf node at 0x2000+4
    uint32_t nodeType = swapBytes32(0);              // Leaf node (big-endian)
    uint32_t entryCount = [_entries count];
    uint32_t recordCount = swapBytes32(entryCount);  // Convert to big-endian
    
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
    
    // Pad to full B-tree block size (8192 bytes from 0x2000)
    NSUInteger fullBtreeEnd = 0x2000 + 8192;
    while ([fileData length] < fullBtreeEnd) {
        char zero = 0;
        [fileData appendBytes:&zero length:1];
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
    _dirty = YES;  // Mark as modified
}

- (void)removeEntryForFilename:(NSString *)filename code:(NSString *)code {
    if (!_isLoaded) {
        [self load];
    }
    
    DSStoreEntry *entry = [self entryForFilename:filename code:code];
    if (entry) {
        [_entries removeObject:entry];
        _dirty = YES;  // Mark as modified
    }
}

// CRUD methods for all DS_Store field types

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

// CRUD methods for all DS_Store field types

- (NSPoint)iconLocationForFilename:(NSString *)filename {
    DSStoreEntry *entry = [self entryForFilename:filename code:@"Iloc"];
    if (entry) {
        return [entry iconLocation];
    }
    return NSMakePoint(0, 0);
}

- (void)setIconLocationForFilename:(NSString *)filename x:(int)x y:(int)y {
    DSStoreEntry *entry = [DSStoreEntry iconLocationEntryForFile:filename x:x y:y];
    [self setEntry:entry];
}

- (SimpleColor *)backgroundColorForDirectory {
    DSStoreEntry *entry = [self entryForFilename:@"." code:@"BKGD"];
    if (entry) {
        return [entry backgroundColor];
    }
    return nil;
}

- (void)setBackgroundColorForDirectory:(SimpleColor *)color {
    float red, green, blue, alpha;
    [color getRed:&red green:&green blue:&blue alpha:&alpha];
    
    int redInt = (int)(red * 65535);
    int greenInt = (int)(green * 65535);
    int blueInt = (int)(blue * 65535);
    
    DSStoreEntry *entry = [DSStoreEntry backgroundColorEntryForFile:@"." red:redInt green:greenInt blue:blueInt];
    [self setEntry:entry];
}

- (NSString *)backgroundImagePathForDirectory {
    DSStoreEntry *entry = [self entryForFilename:@"." code:@"BKGD"];
    if (entry) {
        return [entry backgroundImagePath];
    }
    return nil;
}

- (void)setBackgroundImagePathForDirectory:(NSString *)imagePath {
    DSStoreEntry *entry = [DSStoreEntry backgroundImageEntryForFile:@"." imagePath:imagePath];
    [self setEntry:entry];
}

- (NSString *)viewStyleForDirectory {
    DSStoreEntry *entry = [self entryForFilename:@"." code:@"vstl"];
    if (entry) {
        return [entry viewStyle];
    }
    return nil;
}

- (void)setViewStyleForDirectory:(NSString *)style {
    DSStoreEntry *entry = [DSStoreEntry viewStyleEntryForFile:@"." style:style];
    [self setEntry:entry];
}

- (int)iconSizeForDirectory {
    DSStoreEntry *entry = [self entryForFilename:@"." code:@"icvo"];
    if (entry) {
        return [entry iconSize];
    }
    return 0;
}

- (void)setIconSizeForDirectory:(int)size {
    DSStoreEntry *entry = [DSStoreEntry iconSizeEntryForFile:@"." size:size];
    [self setEntry:entry];
}

- (NSString *)commentsForFilename:(NSString *)filename {
    DSStoreEntry *entry = [self entryForFilename:filename code:@"cmmt"];
    if (entry) {
        return [entry comments];
    }
    return nil;
}

- (void)setCommentsForFilename:(NSString *)filename comments:(NSString *)comments {
    DSStoreEntry *entry = [DSStoreEntry commentsEntryForFile:filename comments:comments];
    [self setEntry:entry];
}

- (long long)logicalSizeForFilename:(NSString *)filename {
    DSStoreEntry *entry = [self entryForFilename:filename code:@"lg1S"];
    if (!entry) {
        entry = [self entryForFilename:filename code:@"logS"]; // Fallback to legacy
    }
    if (entry) {
        return [entry logicalSize];
    }
    return 0;
}

- (void)setLogicalSizeForFilename:(NSString *)filename size:(long long)size {
    DSStoreEntry *entry = [DSStoreEntry logicalSizeEntryForFile:filename size:size];
    [self setEntry:entry];
}

- (long long)physicalSizeForFilename:(NSString *)filename {
    DSStoreEntry *entry = [self entryForFilename:filename code:@"ph1S"];
    if (!entry) {
        entry = [self entryForFilename:filename code:@"phyS"]; // Fallback to legacy
    }
    if (entry) {
        return [entry physicalSize];
    }
    return 0;
}

- (void)setPhysicalSizeForFilename:(NSString *)filename size:(long long)size {
    DSStoreEntry *entry = [DSStoreEntry physicalSizeEntryForFile:filename size:size];
    [self setEntry:entry];
}

- (NSDate *)modificationDateForFilename:(NSString *)filename {
    DSStoreEntry *entry = [self entryForFilename:filename code:@"modD"];
    if (!entry) {
        entry = [self entryForFilename:filename code:@"moDD"]; // Alternative
    }
    if (entry) {
        return [entry modificationDate];
    }
    return nil;
}

- (void)setModificationDateForFilename:(NSString *)filename date:(NSDate *)date {
    DSStoreEntry *entry = [DSStoreEntry modificationDateEntryForFile:filename date:date];
    [self setEntry:entry];
}

- (BOOL)booleanValueForFilename:(NSString *)filename code:(NSString *)code {
    DSStoreEntry *entry = [self entryForFilename:filename code:code];
    if (entry) {
        return [entry booleanValue];
    }
    return NO;
}

- (void)setBooleanValueForFilename:(NSString *)filename code:(NSString *)code value:(BOOL)value {
    DSStoreEntry *entry = [DSStoreEntry booleanEntryForFile:filename code:code value:value];
    [self setEntry:entry];
}

- (int32_t)longValueForFilename:(NSString *)filename code:(NSString *)code {
    DSStoreEntry *entry = [self entryForFilename:filename code:code];
    if (entry) {
        return [entry longValue];
    }
    return 0;
}

- (void)setLongValueForFilename:(NSString *)filename code:(NSString *)code value:(int32_t)value {
    DSStoreEntry *entry = [DSStoreEntry longEntryForFile:filename code:code value:value];
    [self setEntry:entry];
}

// Legacy compatibility method - redirect to new API
- (NSDictionary *)iconLocationDictForFilename:(NSString *)filename {
    NSPoint location = [self iconLocationForFilename:filename];
    if (location.x == 0 && location.y == 0) {
        return nil;
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithFloat:location.x], @"x",
            [NSNumber numberWithFloat:location.y], @"y",
            nil];
}

- (void)setIconLocation:(NSDictionary *)location forFilename:(NSString *)filename {
    int x = [[location objectForKey:@"x"] intValue];
    int y = [[location objectForKey:@"y"] intValue];
    [self setIconLocationForFilename:filename x:x y:y];
}

- (NSDictionary *)iconViewSettingsForDirectory {
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    
    NSString *viewStyle = [self viewStyleForDirectory];
    if (viewStyle) {
        [settings setObject:viewStyle forKey:@"viewStyle"];
    }
    
    int iconSize = [self iconSizeForDirectory];
    if (iconSize > 0) {
        [settings setObject:[NSNumber numberWithInt:iconSize] forKey:@"iconSize"];
    }
    
    SimpleColor *backgroundColor = [self backgroundColorForDirectory];
    if (backgroundColor) {
        [settings setObject:backgroundColor forKey:@"backgroundColor"];
    }
    
    NSString *backgroundImage = [self backgroundImagePathForDirectory];
    if (backgroundImage) {
        [settings setObject:backgroundImage forKey:@"backgroundImage"];
    }
    
    return [settings count] > 0 ? settings : nil;
}

- (void)setIconViewSettings:(NSDictionary *)settings forDirectory:(BOOL)directory {
    NSString *viewStyle = [settings objectForKey:@"viewStyle"];
    if (viewStyle) {
        [self setViewStyleForDirectory:viewStyle];
    }
    
    NSNumber *iconSize = [settings objectForKey:@"iconSize"];
    if (iconSize) {
        [self setIconSizeForDirectory:[iconSize intValue]];
    }
    
    SimpleColor *backgroundColor = [settings objectForKey:@"backgroundColor"];
    if (backgroundColor) {
        [self setBackgroundColorForDirectory:backgroundColor];
    }
    
    NSString *backgroundImage = [settings objectForKey:@"backgroundImage"];
    if (backgroundImage) {
        [self setBackgroundImagePathForDirectory:backgroundImage];
    }
}

// Directory entry management methods

- (BOOL)saveChanges {
    if (!_dirty) {
        return YES; // No changes to save
    }
    
    @try {
        // Save changes back to file
        if (![self save]) {
            return NO;
        }
        _dirty = NO;
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"Error saving DS_Store file: %@", [exception reason]);
        return NO;
    }
}

- (void)removeAllEntriesForFilename:(NSString *)filename {
    NSMutableArray *toRemove = [NSMutableArray array];
    
    for (DSStoreEntry *entry in _entries) {
        if ([[entry filename] isEqualToString:filename]) {
            [toRemove addObject:entry];
        }
    }
    
    for (DSStoreEntry *entry in toRemove) {
        [_entries removeObject:entry];
        _dirty = YES;
    }
}

- (NSArray *)allFilenames {
    NSMutableSet *filenames = [NSMutableSet set];
    
    for (DSStoreEntry *entry in _entries) {
        [filenames addObject:[entry filename]];
    }
    
    return [filenames allObjects];
}

- (NSArray *)allCodesForFilename:(NSString *)filename {
    NSMutableArray *codes = [NSMutableArray array];
    
    for (DSStoreEntry *entry in _entries) {
        if ([[entry filename] isEqualToString:filename]) {
            [codes addObject:[entry code]];
        }
    }
    
    return codes;
}

- (void)setIconViewSettings:(NSDictionary *)settings {
    // Modern method delegation
    [self setIconViewSettings:settings forDirectory:YES];
}

@end

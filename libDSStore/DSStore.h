//
//  DSStore.h
//  libDSStore
//
//  Created by Gershwin Components
//  License: MIT
//

#import <Foundation/Foundation.h>
#import "DSBuddyAllocator.h"
#import "DSStoreEntry.h"
#import "DSStoreCodecs.h"

#ifdef __cplusplus
extern "C" {
#endif

@interface DSStore : NSObject
{
    NSString *_filePath;
    DSBuddyAllocator *_allocator;
    NSMutableArray *_entries;
    BOOL _isLoaded;
    
    // B-tree structure fields
    uint32_t _rootNode;
    uint32_t _levels;
    uint32_t _records;
    uint32_t _nodes;
    uint32_t _pageSize;
}

+ (id)storeWithPath:(NSString *)path;
+ (id)createStoreAtPath:(NSString *)path withEntries:(NSArray *)entries;

- (id)initWithPath:(NSString *)path;

- (NSString *)filePath;
- (NSArray *)entries;

- (BOOL)load;
- (BOOL)save;

// Internal methods
- (void)readBTreeNode:(DSBuddyBlock *)block address:(uint32_t)address isLeaf:(BOOL)isLeaf;

- (DSStoreEntry *)entryForFilename:(NSString *)filename code:(NSString *)code;
- (void)setEntry:(DSStoreEntry *)entry;
- (void)removeEntryForFilename:(NSString *)filename code:(NSString *)code;

// Convenience methods for common entries
- (NSDictionary *)iconLocationForFilename:(NSString *)filename;
- (void)setIconLocation:(NSDictionary *)location forFilename:(NSString *)filename;

- (NSDictionary *)backgroundPictureForDirectory;
- (void)setBackgroundPicture:(NSDictionary *)pictureInfo;

- (NSDictionary *)listViewSettingsForDirectory;
- (void)setListViewSettings:(NSDictionary *)settings;

- (NSDictionary *)iconViewSettingsForDirectory;
- (void)setIconViewSettings:(NSDictionary *)settings;

@end

#ifdef __cplusplus
}
#endif

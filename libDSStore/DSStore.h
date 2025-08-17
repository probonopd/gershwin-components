//
//  DSStore.h
//  libDSStore
//
//  Created by Gershwin Components
//  License: MIT
//

#import <Foundation/Foundation.h>
#import "SimpleColor.h"  // Simple color replacement for headless systems
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
    BOOL _dirty;  // Track if changes were made
    
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

// Icon Position methods (New CRUD API)
- (NSPoint)iconLocationForFilename:(NSString *)filename;
- (void)setIconLocationForFilename:(NSString *)filename x:(int)x y:(int)y;

// Background methods
- (SimpleColor *)backgroundColorForDirectory;
- (void)setBackgroundColorForDirectory:(SimpleColor *)color;
- (NSString *)backgroundImagePathForDirectory;
- (void)setBackgroundImagePathForDirectory:(NSString *)imagePath;

// View Style methods
- (NSString *)viewStyleForDirectory;
- (void)setViewStyleForDirectory:(NSString *)style;
- (int)iconSizeForDirectory;
- (void)setIconSizeForDirectory:(int)size;

// File Metadata methods
- (NSString *)commentsForFilename:(NSString *)filename;
- (void)setCommentsForFilename:(NSString *)filename comments:(NSString *)comments;
- (long long)logicalSizeForFilename:(NSString *)filename;
- (void)setLogicalSizeForFilename:(NSString *)filename size:(long long)size;
- (long long)physicalSizeForFilename:(NSString *)filename;
- (void)setPhysicalSizeForFilename:(NSString *)filename size:(long long)size;
- (NSDate *)modificationDateForFilename:(NSString *)filename;
- (void)setModificationDateForFilename:(NSString *)filename date:(NSDate *)date;

// Generic field methods
- (BOOL)booleanValueForFilename:(NSString *)filename code:(NSString *)code;
- (void)setBooleanValueForFilename:(NSString *)filename code:(NSString *)code value:(BOOL)value;
- (int32_t)longValueForFilename:(NSString *)filename code:(NSString *)code;
- (void)setLongValueForFilename:(NSString *)filename code:(NSString *)code value:(int32_t)value;

// Directory entry management  
- (BOOL)saveChanges;
- (void)removeEntryForFilename:(NSString *)filename code:(NSString *)code;
- (void)removeAllEntriesForFilename:(NSString *)filename;
- (NSArray *)allFilenames;
- (NSArray *)allCodesForFilename:(NSString *)filename;

// Legacy compatibility methods
- (NSDictionary *)iconLocationDictForFilename:(NSString *)filename;
- (void)setIconLocation:(NSDictionary *)location forFilename:(NSString *)filename;
- (NSDictionary *)iconViewSettingsForDirectory;
- (void)setIconViewSettings:(NSDictionary *)settings;

// Convenience methods for common entries (legacy compatibility)
- (NSDictionary *)backgroundPictureForDirectory;
- (void)setBackgroundPicture:(NSDictionary *)pictureInfo;

- (NSDictionary *)listViewSettingsForDirectory;
- (void)setListViewSettings:(NSDictionary *)settings;

@end

#ifdef __cplusplus
}
#endif

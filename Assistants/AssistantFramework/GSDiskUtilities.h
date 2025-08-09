//
// GSDiskUtilities.h
// GSAssistantFramework - Disk Management Utilities
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface GSDisk : NSObject
@property (nonatomic, retain) NSString *deviceName;
@property (nonatomic, retain) NSString *description;
@property (nonatomic, assign) long long size;
@property (nonatomic, retain) NSString *geomName;
@property (nonatomic, assign) BOOL isRemovable;
@property (nonatomic, assign) BOOL isWritable;
@end

@interface GSDiskUtilities : NSObject

+ (NSArray *)getAvailableDisks;
+ (nullable GSDisk *)getDiskInfo:(NSString *)deviceName;
+ (BOOL)unmountPartitionsForDisk:(NSString *)deviceName;
+ (NSString *)formatSize:(long long)sizeInBytes;
+ (NSString *)formatSizeWithUnit:(long long)sizeInBytes unit:(NSString *)preferredUnit;

// Convenience methods
+ (NSArray *)getRemovableDisks;
+ (NSArray *)getDisksWithMinimumSize:(long long)minimumBytes;

@end

NS_ASSUME_NONNULL_END

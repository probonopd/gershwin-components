//
// CLMDiskUtility.h
// Create Live Media Assistant - Disk Utility
//

#import <Foundation/Foundation.h>

@interface CLMDisk : NSObject
@property (nonatomic, retain) NSString *deviceName;
@property (nonatomic, retain) NSString *description;
@property (nonatomic, assign) long long size;
@property (nonatomic, retain) NSString *geomName;
@property (nonatomic, assign) BOOL isRemovable;
@property (nonatomic, assign) BOOL isWritable;
@end

@interface CLMDiskUtility : NSObject

+ (NSArray *)getAvailableDisks;
+ (CLMDisk *)getDiskInfo:(NSString *)deviceName;
+ (BOOL)unmountPartitionsForDisk:(NSString *)deviceName;
+ (NSString *)formatSize:(long long)sizeInBytes;

@end

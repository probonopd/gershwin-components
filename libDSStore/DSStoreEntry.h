//
//  DSStoreEntry.h
//  libDSStore
//
//  DS_Store entry representation
//  Based on Python ds_store store.py
//

#import <Foundation/Foundation.h>
#import "SimpleColor.h"  // Simple color replacement for headless systems
#import <CoreFoundation/CoreFoundation.h>  // For CFSwap functions

@interface DSStoreEntry : NSObject
{
    NSString *_filename;
    NSString *_code;
    NSString *_type;
    id _value;
}

@property (nonatomic, retain) NSString *filename;
@property (nonatomic, retain) NSString *code;
@property (nonatomic, retain) NSString *type;
@property (nonatomic, retain) id value;

- (id)initWithFilename:(NSString *)filename code:(NSString *)code type:(NSString *)type value:(id)value;
- (NSUInteger)byteLength;
- (NSData *)encode;

// Comparison methods for sorting
- (NSComparisonResult)compare:(DSStoreEntry *)other;

// CRUD convenience methods for all DS_Store field types
+ (DSStoreEntry *)iconLocationEntryForFile:(NSString *)filename x:(int)x y:(int)y;
+ (DSStoreEntry *)backgroundColorEntryForFile:(NSString *)filename red:(int)red green:(int)green blue:(int)blue;
+ (DSStoreEntry *)backgroundImageEntryForFile:(NSString *)filename imagePath:(NSString *)imagePath;
+ (DSStoreEntry *)viewStyleEntryForFile:(NSString *)filename style:(NSString *)style;
+ (DSStoreEntry *)iconSizeEntryForFile:(NSString *)filename size:(int)size;
+ (DSStoreEntry *)commentsEntryForFile:(NSString *)filename comments:(NSString *)comments;
+ (DSStoreEntry *)logicalSizeEntryForFile:(NSString *)filename size:(long long)size;
+ (DSStoreEntry *)physicalSizeEntryForFile:(NSString *)filename size:(long long)size;
+ (DSStoreEntry *)modificationDateEntryForFile:(NSString *)filename date:(NSDate *)date;
+ (DSStoreEntry *)booleanEntryForFile:(NSString *)filename code:(NSString *)code value:(BOOL)value;
+ (DSStoreEntry *)longEntryForFile:(NSString *)filename code:(NSString *)code value:(int32_t)value;

// Value extraction methods
- (NSPoint)iconLocation;
- (SimpleColor *)backgroundColor;
- (NSString *)backgroundImagePath;
- (NSString *)viewStyle;
- (int)iconSize;
- (NSString *)comments;
- (long long)logicalSize;
- (long long)physicalSize;
- (NSDate *)modificationDate;
- (BOOL)booleanValue;
- (int32_t)longValue;

@end

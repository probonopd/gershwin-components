//
//  DSStoreEntry.h
//  libDSStore
//
//  DS_Store entry representation
//  Based on Python ds_store store.py
//

#import <Foundation/Foundation.h>

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

@end

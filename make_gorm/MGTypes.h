/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef MGTYPES_H
#define MGTYPES_H

#import <Foundation/NSObject.h>
#import <Foundation/NSData.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSValue.h>

/*
 * GSC type tag constants (from NSData.h)
 */
#define GSC_NONE       0x00
#define GSC_XREF       0x80
#define GSC_SIZE       0x60
#define GSC_MASK       0x1f

#define GSC_X_0        0x00
#define GSC_X_1        0x20
#define GSC_X_2        0x40
#define GSC_X_4        0x60

#define GSC_I16        0x00
#define GSC_I32        0x20
#define GSC_I64        0x40
#define GSC_I128       0x60

#define GSC_MAYX       0x10

#define GSC_CHR        0x01
#define GSC_UCHR       0x02
#define GSC_SHT        0x03
#define GSC_USHT       0x04
#define GSC_INT        0x05
#define GSC_UINT       0x06
#define GSC_LNG        0x07
#define GSC_ULNG       0x08
#define GSC_LNG_LNG    0x09
#define GSC_ULNG_LNG   0x0a
#define GSC_FLT        0x0b
#define GSC_DBL        0x0c
#define GSC_BOOL       0x0d

#define GSC_ID         0x10
#define GSC_CLASS      0x11
#define GSC_SEL        0x12
#define GSC_PTR        0x13
#define GSC_CHARPTR    0x14
#define GSC_ARY_B      0x15
#define GSC_STRUCT_B   0x16
#define GSC_CID        0x17

#define GSC_S_SHT      GSC_I16
#define GSC_S_INT      GSC_I32
#define GSC_S_LNG      GSC_I64
#define GSC_S_LNG_LNG  GSC_I64

/*
 * Platform-independent size of scalar types in the archive.
 * Encoded in bits 5-6 of integer type tags.
 */
typedef NS_ENUM(uint8_t, MGScalarWidth) {
    MGScalarWidth16    = 0x00,
    MGScalarWidth32    = 0x20,
    MGScalarWidth64    = 0x40,
    MGScalarWidth128   = 0x60,
};

/*
 * A value decoded from the binary archive stream.
 * Used to represent the IR at the tag level.
 */
@interface MGValue : NSObject
@property uint8_t tag;        /* raw GSC tag (including xref/size bits) */
@property uint32_t xref;      /* cross-reference number */
@property (strong) NSData *rawData;  /* raw serialized bytes for this value */
@property (strong) id objectValue;   /* decoded Objective-C object (if applicable) */
@property (strong) NSString *stringValue;  /* string value (for char*, selectors) */
@property int64_t intValue;
@property uint64_t uintValue;
@property double doubleValue;
@property float floatValue;
@property BOOL boolValue;
/* For arrays and structs */
@property (strong) NSMutableArray *children; /* of MGValue */

+ (instancetype)valueWithTag:(uint8_t)t;
@end

/*
 * A class definition in the archive
 */
@interface MGClassDef : NSObject
@property (strong) NSString *name;
@property unsigned version;
@end

/*
 * An object in the archive
 */
@interface MGArchiveObject : NSObject
@property int32_t objectId;         /* crossref number (1-based, 0 = nil) */
@property (strong) NSString *className;
@property (strong) NSMutableArray *encodedValues; /* of MGValue */
/* Decoded object (after NSUnarchiver) */
@property (strong) id decodedObject;
/* Named properties (from RecordingCoder) */
@property (strong) NSMutableDictionary *namedProperties;
@end

/*
 * The complete binary archive
 */
@interface MGArchive : NSObject
@property unsigned systemVersion;
@property unsigned classCount;
@property unsigned objectCount;
@property unsigned pointerCount;
@property (strong) NSMutableArray *classDefs;   /* of MGClassDef */
@property (strong) NSMutableArray *objects;     /* of MGArchiveObject */
/* Raw data references */
@property (strong) NSMutableArray *selectorValues;   /* of NSString */
@property (strong) NSMutableArray *cstringValues;   /* of NSString */
@property (strong) NSMutableArray *ptrValues;       /* of NSData */

- (MGArchiveObject *)objectWithId:(int32_t)oid;
@end

/*
 * Unambiguous BOOL wrapper used by MGRecordingCoder and MGTextFormatter.
 * Distinguishes boolean values from integer NSNumbers during round-tripping.
 */
@interface MGBoolBox : NSObject
{
  BOOL _value;
}
- (instancetype)initWithBool:(BOOL)val;
- (BOOL)boolValue;
@end

#endif

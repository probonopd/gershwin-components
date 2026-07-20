/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MGTextWriter.h"
#import "MGTypes.h"
#import "MGArchiverReader.h"

#import <Foundation/Foundation.h>
#import <GNUstepBase/GNUstep.h>
#import <objc/objc-api.h>
#import <objc/runtime.h>

/* ============================================================
 *  MGRecordingCoder -- captures encodeWithCoder: as name-value pairs
 * ============================================================ */
@interface MGRecordingCoder : NSCoder
{
  MGArchive        *_archive;
  NSMapTable       *_objectToId;
  NSMutableDictionary *_properties;
  NSMutableSet     *_seenObjects; /* cycle detection */
  BOOL              _allowKeyed;
  int               _unnamedIndex;
  int               _currentDepth;
  int               _maxDepth;
}
- (instancetype)initWithArchive:(MGArchive *)archive
                     objectToId:(NSMapTable *)map;
- (NSDictionary *)properties;
- (void)setAllowsKeyedCoding:(BOOL)flag;
@end

/* Private method declarations */
@interface MGRecordingCoder (Private)
- (void)_encodeValueOfObjCType:(const char *)type
                            at:(const void *)addr
                        forKey:(NSString *)key;
@end

@implementation MGRecordingCoder

- (instancetype)initWithArchive:(MGArchive *)archive
                     objectToId:(NSMapTable *)map
{
  self = [super init];
  if (self)
    {
      _archive = RETAIN(archive);
      _objectToId = map ? RETAIN(map) : nil;
      _properties = [[NSMutableDictionary alloc] init];
      _seenObjects = [[NSMutableSet alloc] init];
      _allowKeyed = YES;
      _unnamedIndex = 0;
      _currentDepth = 0;
      _maxDepth = 32;
    }
  return self;
}

- (void)dealloc
{
  RELEASE(_archive);
  RELEASE(_objectToId);
  RELEASE(_properties);
  RELEASE(_seenObjects);
  [super dealloc];
}

- (NSDictionary *)properties
{
  return _properties;
}

- (BOOL)allowsKeyedCoding
{
  return _allowKeyed;
}

- (void)setAllowsKeyedCoding:(BOOL)flag
{
  _allowKeyed = flag;
}

/* Look up object pointer in our map */
- (NSString *)_refForObject:(id)obj
{
  if (obj == nil || _objectToId == nil)
    return nil;
  NSNumber *oid = [_objectToId objectForKey:obj];
  if (oid == nil)
    return nil;
  return [NSString stringWithFormat:@"@%d", [oid intValue]];
}

/* Store a property value */
- (void)_setValue:(id)val forKey:(NSString *)key
{
  if (key == nil)
    key = [NSString stringWithFormat:@"%d", _unnamedIndex++];
  if (val == nil)
    val = [NSNull null];
  [_properties setObject:val forKey:key];
}

/* Check if an object is a "simple" value (NSString, NSNumber, NSData, etc.) */
- (BOOL)_isSimpleObject:(id)obj
{
  if ([obj isKindOfClass:[NSString class]]) return YES;
  if ([obj isKindOfClass:[NSNumber class]]) return YES;
  if ([obj isKindOfClass:[NSData class]]) return YES;
  if ([obj isKindOfClass:[NSNull class]]) return YES;
  if ([obj isKindOfClass:[NSArray class]]) return YES;
  if ([obj isKindOfClass:[NSDictionary class]]) return YES;
  return NO;
}

/* Recursively convert a collection to text-friendly format */
- (id)_convertObject:(id)obj
{
  if (obj == nil)
    return [NSNull null];

  /* Depth limit */
  if (_currentDepth >= _maxDepth)
    {
      NSString *ref = [self _refForObject:obj];
      if (ref) return ref;
      return [@"<max depth>" stringByAppendingString:[obj description]];
    }

  /* Cycle detection */
  if ([_seenObjects containsObject:obj])
    {
      NSString *ref = [self _refForObject:obj];
      if (ref) return ref;
      return [NSNull null];
    }
  [_seenObjects addObject:obj];

  id result = nil;

  /* Check for archive reference first */
  NSString *ref = [self _refForObject:obj];
  if (ref != nil)
    result = ref;
  else if ([obj isKindOfClass:[NSString class]] ||
           [obj isKindOfClass:[NSNumber class]] ||
           [obj isKindOfClass:[NSNull class]])
    result = obj;
  else if ([obj isKindOfClass:[NSData class]])
    result = obj;
  else if ([obj isKindOfClass:[NSArray class]])
    {
      NSMutableArray *arr = [NSMutableArray array];
      for (id elem in (NSArray *)obj)
        [arr addObject:[self _convertObject:elem]];
      result = arr;
    }
  else if ([obj isKindOfClass:[NSDictionary class]])
    {
      NSMutableDictionary *dict = [NSMutableDictionary dictionary];
      for (id key in [(NSDictionary *)obj allKeys])
        [dict setObject:[self _convertObject:[(NSDictionary *)obj objectForKey:key]]
                 forKey:key];
      result = dict;
    }
  else if ([obj respondsToSelector:@selector(encodeWithCoder:)])
    {
      MGRecordingCoder *subCoder;
      subCoder = [[MGRecordingCoder alloc] initWithArchive:_archive
                                                objectToId:_objectToId];
      subCoder->_currentDepth = _currentDepth + 1;
      subCoder->_maxDepth = _maxDepth;
      @try
        {
          [obj encodeWithCoder:subCoder];
        }
      @catch (NSException *e)
        {
          RELEASE(subCoder);
          [_seenObjects removeObject:obj];
          return [obj description];
        }
      result = [[subCoder properties] copy];
      RELEASE(subCoder);
      [result autorelease];
    }
  else
    result = [obj description];

  [_seenObjects removeObject:obj];
  return result;
}

/* --- Keyed encoding --- */

- (void)encodeObject:(id)obj forKey:(NSString *)key
{
  [self _setValue:[self _convertObject:obj] forKey:key];
}

- (void)encodeConditionalObject:(id)obj forKey:(NSString *)key
{
  [self encodeObject:obj forKey:key];
}

- (void)encodeBool:(BOOL)val forKey:(NSString *)key
{
  [self _setValue:[[[MGBoolBox alloc] initWithBool:val] autorelease]
           forKey:key];
}

- (void)encodeInt:(int)val forKey:(NSString *)key
{
  [self _setValue:[NSNumber numberWithInt:val] forKey:key];
}

- (void)encodeInt32:(int32_t)val forKey:(NSString *)key
{
  [self _setValue:[NSNumber numberWithInt:val] forKey:key];
}

- (void)encodeInt64:(int64_t)val forKey:(NSString *)key
{
  [self _setValue:[NSNumber numberWithLongLong:val] forKey:key];
}

- (void)encodeFloat:(float)val forKey:(NSString *)key
{
  [self _setValue:[NSNumber numberWithFloat:val] forKey:key];
}

- (void)encodeDouble:(double)val forKey:(NSString *)key
{
  [self _setValue:[NSNumber numberWithDouble:val] forKey:key];
}

- (void)encodeBytes:(const uint8_t *)bytes
             length:(NSUInteger)len
             forKey:(NSString *)key
{
  [self _setValue:[NSData dataWithBytes:bytes length:len] forKey:key];
}

/* --- Unkeyed (old-style) encoding --- */

- (void)encodeValueOfObjCType:(const char *)type at:(const void *)addr
{
  NSString *key = [NSString stringWithFormat:@"%d", _unnamedIndex++];
  [self _encodeValueOfObjCType:type at:addr forKey:key];
}

- (void)encodeValueOfObjCType:(const char *)type
                           at:(const void *)addr
                       forKey:(NSString *)key
{
  if (key == nil)
    key = [NSString stringWithFormat:@"%d", _unnamedIndex++];
  [self _encodeValueOfObjCType:type at:addr forKey:key];
}

- (void)_encodeValueOfObjCType:(const char *)type
                            at:(const void *)addr
                        forKey:(NSString *)key
{
  switch (*type)
    {
      case _C_ID:
        {
          id obj = *(id *)addr;
          [self _setValue:[self _convertObject:obj] forKey:key];
          break;
        }
      case _C_CLASS:
        {
          Class cls = *(Class *)addr;
          if (cls == Nil)
            [self _setValue:[NSNull null] forKey:key];
          else
            [self _setValue:NSStringFromClass(cls) forKey:key];
          break;
        }
      case _C_SEL:
        {
          SEL sel = *(SEL *)addr;
          if (sel == NULL)
            [self _setValue:[NSNull null] forKey:key];
          else
            [self _setValue:NSStringFromSelector(sel) forKey:key];
          break;
        }
      case _C_CHR:
        [self _setValue:[NSNumber numberWithChar:*(char *)addr] forKey:key];
        break;
      case _C_UCHR:
        [self _setValue:[NSNumber numberWithUnsignedChar:*(unsigned char *)addr]
                 forKey:key];
        break;
      case _C_SHT:
        [self _setValue:[NSNumber numberWithShort:*(short *)addr] forKey:key];
        break;
      case _C_USHT:
        [self _setValue:[NSNumber numberWithUnsignedShort:*(unsigned short *)addr]
                 forKey:key];
        break;
      case _C_INT:
        [self _setValue:[NSNumber numberWithInt:*(int *)addr] forKey:key];
        break;
      case _C_UINT:
        [self _setValue:[NSNumber numberWithUnsignedInt:*(unsigned int *)addr]
                 forKey:key];
        break;
      case _C_LNG:
        [self _setValue:[NSNumber numberWithLong:*(long *)addr] forKey:key];
        break;
      case _C_ULNG:
        [self _setValue:[NSNumber numberWithUnsignedLong:*(unsigned long *)addr]
                 forKey:key];
        break;
      case _C_LNG_LNG:
        [self _setValue:[NSNumber numberWithLongLong:*(long long *)addr]
                 forKey:key];
        break;
      case _C_ULNG_LNG:
        [self _setValue:[NSNumber numberWithUnsignedLongLong:*(unsigned long long *)addr]
                 forKey:key];
        break;
      case _C_FLT:
        [self _setValue:[NSNumber numberWithFloat:*(float *)addr] forKey:key];
        break;
      case _C_DBL:
        [self _setValue:[NSNumber numberWithDouble:*(double *)addr] forKey:key];
        break;
      case _C_BOOL:
        {
          BOOL bval = *(BOOL *)addr;
          [self _setValue:[[[MGBoolBox alloc] initWithBool:bval] autorelease]
                   forKey:key];
          break;
        }
      case _C_CHARPTR:
        {
          const char *str = *(const char **)addr;
          if (str != NULL)
            [self _setValue:[NSString stringWithUTF8String:str] forKey:key];
          else
            [self _setValue:[NSNull null] forKey:key];
          break;
        }
      default:
        {
          /* Handle arrays and structs via the runtime */
          NSUInteger size, align;
          NSGetSizeAndAlignment(type, &size, &align);
          NSData *raw = [NSData dataWithBytes:addr length:size];
          [self _setValue:raw forKey:key];
          break;
        }
    }
}

- (void)encodeDataObject:(NSData *)data
{
  [self _setValue:data forKey:[NSString stringWithFormat:@"%d", _unnamedIndex++]];
}

- (void)encodeArrayOfObjCType:(const char *)type
                        count:(NSUInteger)count
                           at:(const void *)array
{
  NSUInteger elementSize = objc_sizeof_type(type);
  for (NSUInteger i = 0; i < count; i++)
    {
      const void *element = (const char *)array + (i * elementSize);
      [self encodeValueOfObjCType:type at:element];
    }
}

- (void)encodeBytes:(void *)addr length:(NSUInteger)length
{
  [self _setValue:[NSData dataWithBytes:addr length:length]
           forKey:[NSString stringWithFormat:@"%d", _unnamedIndex++]];
}

@end

/* ============================================================
 *  MGTextWriter implementation
 * ============================================================ */

@implementation MGTextWriter

/* Build a map from pointer -> objectId for all decoded objects */
static NSMapTable *_buildObjectToIdMap(MGArchive *archive)
{
  NSMapTable *map = [NSMapTable mapTableWithKeyOptions:NSMapTableWeakMemory
                                          valueOptions:NSMapTableStrongMemory];
  for (MGArchiveObject *obj in archive.objects)
    {
      if (obj.decodedObject != nil)
        {
          [map setObject:[NSNumber numberWithInt:obj.objectId]
                  forKey:obj.decodedObject];
        }
    }
  return map;
}

/* Escape a string for text format output */
static NSString *_escapeString(NSString *str)
{
  if (str == nil)
    return @"";
  NSMutableString *escaped = [NSMutableString stringWithString:str];
  [escaped replaceOccurrencesOfString:@"\\"
                           withString:@"\\\\"
                              options:0
                                range:NSMakeRange(0, [escaped length])];
  [escaped replaceOccurrencesOfString:@"\""
                           withString:@"\\\""
                              options:0
                                range:NSMakeRange(0, [escaped length])];
  [escaped replaceOccurrencesOfString:@"\n"
                           withString:@"\\n"
                              options:0
                                range:NSMakeRange(0, [escaped length])];
  [escaped replaceOccurrencesOfString:@"\t"
                           withString:@"\\t"
                              options:0
                                range:NSMakeRange(0, [escaped length])];
  [escaped replaceOccurrencesOfString:@"\r"
                           withString:@"\\r"
                              options:0
                                range:NSMakeRange(0, [escaped length])];
  return escaped;
}

/* Format a value as text recursively */
static NSString *_formatValue(id val, NSUInteger indent)
{
  NSString *indentStr = @"";
  for (NSUInteger i = 0; i < indent; i++)
    indentStr = [indentStr stringByAppendingString:@"    "];

  NSString *childIndent = @"";
  for (NSUInteger i = 0; i < indent + 1; i++)
    childIndent = [childIndent stringByAppendingString:@"    "];

  if (val == nil || [val isKindOfClass:[NSNull class]])
    return @"null";

  /* BOOL wrapper */
  if ([val isKindOfClass:[MGBoolBox class]])
    return [(MGBoolBox *)val boolValue] ? @"true" : @"false";

  if ([val isKindOfClass:[NSString class]])
    {
      NSString *str = (NSString *)val;

      /* Check if this looks like a reference (@<number>) */
      if ([str length] > 1 && [str characterAtIndex:0] == '@')
        {
          NSScanner *sc = [NSScanner scannerWithString:
            [str substringFromIndex:1]];
          int intVal;
          if ([sc scanInt:&intVal] && [sc isAtEnd])
            return str;
        }

      return [NSString stringWithFormat:@"\"%@\"", _escapeString(str)];
    }

  if ([val isKindOfClass:[NSNumber class]])
    {
      NSNumber *num = (NSNumber *)val;
      const char *type = [num objCType];
      if (type && (strchr("fd", *type) != NULL
                   || strchr("FD", *type) != NULL))
        {
          double dval = [num doubleValue];
          if (dval == (double)(long long)dval && dval < (1LL << 53))
            return [NSString stringWithFormat:@"%.1f", dval];
          return [NSString stringWithFormat:@"%g", dval];
        }

      return [num stringValue];
    }

  if ([val isKindOfClass:[NSData class]])
    {
      NSData *data = (NSData *)val;
      NSUInteger len = [data length];
      const uint8_t *bytes = [data bytes];
      NSMutableString *result = [NSMutableString string];
      [result appendString:@"<data>\n"];
      [result appendString:childIndent];

      for (NSUInteger i = 0; i < len; i++)
        {
          [result appendFormat:@"%02X", bytes[i]];
          if ((i % 64) == 63 && (i + 1) < len)
            {
              [result appendString:@"\n"];
              [result appendString:childIndent];
            }
        }

      [result appendString:@"\n"];
      [result appendString:indentStr];
      [result appendString:@"</data>"];
      return result;
    }

  if ([val isKindOfClass:[NSArray class]])
    {
      NSArray *arr = (NSArray *)val;
      if ([arr count] == 0)
        return @"[]";

      NSMutableString *result = [NSMutableString string];
      [result appendString:@"[\n"];
      for (NSUInteger i = 0; i < [arr count]; i++)
        {
          [result appendString:childIndent];
          [result appendString:_formatValue([arr objectAtIndex:i], indent + 1)];
          if (i < [arr count] - 1)
            [result appendString:@","];
          [result appendString:@"\n"];
        }
      [result appendString:indentStr];
      [result appendString:@"]"];
      return result;
    }

  if ([val isKindOfClass:[NSDictionary class]])
    {
      NSDictionary *dict = (NSDictionary *)val;
      if ([dict count] == 0)
        return @"{}";

      NSMutableString *result = [NSMutableString string];
      [result appendString:@"{\n"];

      NSArray *sortedKeys = [[dict allKeys] sortedArrayUsingSelector:
        @selector(compare:)];
      for (NSString *key in sortedKeys)
        {
          [result appendString:childIndent];
          [result appendString:key];
          [result appendString:@" = "];
          [result appendString:_formatValue([dict objectForKey:key],
                                             indent + 1)];
          [result appendString:@";\n"];
        }
      [result appendString:indentStr];
      [result appendString:@"}"];
      return result;
    }

  /* Fallback */
  return [NSString stringWithFormat:@"\"%@\"",
    _escapeString([val description])];
}

+ (NSString *)textFromArchive:(MGArchive *)archive
{
  NSMutableString *output = [NSMutableString string];

  [output appendString:@"gorm-text 1\n"];

  [output appendString:@"\nmetadata\n{\n"];
  [output appendFormat:@"    archiveVersion = %u;\n", archive.systemVersion];
  [output appendFormat:@"    coderVersion = 2;\n"];
  [output appendString:@"}\n"];

  /* Sort objects by ID */
  NSArray *sortedObjects = [archive.objects sortedArrayUsingComparator:
    ^NSComparisonResult(MGArchiveObject *a, MGArchiveObject *b) {
      if (a.objectId < b.objectId) return NSOrderedAscending;
      if (a.objectId > b.objectId) return NSOrderedDescending;
      return NSOrderedSame;
    }];

  /* Build objectId → className map for ref formatting */
  NSMutableDictionary *idToClass = [NSMutableDictionary dictionary];
  for (MGArchiveObject *obj in sortedObjects) {
    idToClass[@(obj.objectId)] = obj.className;
  }

  for (MGArchiveObject *obj in sortedObjects)
    {
      [output appendString:@"\n"];
      [output appendFormat:@"object %d\n", obj.objectId];
      [output appendString:@"{\n"];
      [output appendFormat:@"    class = %@;\n", obj.className];

      /* Named properties from RecordingCoder: disabled by default.
       * encodeWithCoder: crashes on complex view hierarchies that
       * need a display server. Enable with -DRECORDING_CODER. */
#ifdef RECORDING_CODER
      NSDictionary *namedProps = nil;
      if (obj.decodedObject != nil)
        {
          NSMapTable *oidMap = _buildObjectToIdMap(archive);
          MGRecordingCoder *coder;
          coder = [[MGRecordingCoder alloc] initWithArchive:archive
                                                 objectToId:oidMap];
          @try
            {
              [coder setAllowsKeyedCoding:YES];
              [obj.decodedObject encodeWithCoder:coder];
              namedProps = [coder properties];
            }
          @catch (NSException *e)
            {
              /* Fall through */
            }
          RELEASE(coder);
        }
      if (namedProps && [namedProps count] > 0)
        {
          NSArray *sortedKeys = [[namedProps allKeys] sortedArrayUsingSelector:
            @selector(compare:)];
          for (NSString *key in sortedKeys)
            {
              if ([key isEqualToString:@"class"]) continue;
              id val = [namedProps objectForKey:key];
              [output appendFormat:@"    %@ = %@;\n",
                key, _formatValue(val, 1)];
            }
        }
      else
#endif
      if ([obj.namedProperties count] > 0)
        {
          /* Output named properties from parsed text */
          NSArray *sortedKeys = [[obj.namedProperties allKeys]
            sortedArrayUsingSelector:@selector(compare:)];
          for (NSString *key in sortedKeys)
            {
              id val = [obj.namedProperties objectForKey:key];
              if ([key isEqualToString:@"class"]) continue;
              [output appendFormat:@"    %@ = %@;\n",
                key, _formatValue(val, 1)];
            }
        }
      else if ([obj.encodedValues count] > 0)
        {
          NSUInteger vi = 0;
          for (MGValue *v in obj.encodedValues)
            {
              NSString *s = _formatMGValue(v, 1, idToClass);
              [output appendFormat:@"    _%lu = %@;\n", (unsigned long)vi, s];
              vi++;
            }
        }

      [output appendString:@"}\n"];
    }

  return output;
}

/* Format raw data as hex */
static NSString *_formatRawData(NSData *data, NSUInteger indent)
{
  NSUInteger len = [data length];
  const uint8_t *bytes = [data bytes];
  NSMutableString *result = [NSMutableString string];
  [result appendString:@"<data>\n"];

  NSString *indentStr = @"";
  for (NSUInteger i = 0; i < indent + 1; i++)
    indentStr = [indentStr stringByAppendingString:@"    "];

  [result appendString:indentStr];
  for (NSUInteger i = 0; i < len; i++)
    {
      [result appendFormat:@"%02X", bytes[i]];
      if ((i % 64) == 63 && (i + 1) < len)
        {
          [result appendString:@"\n"];
          [result appendString:indentStr];
        }
    }
  [result appendString:@"\n"];

  NSString *closeIndent = @"";
  for (NSUInteger i = 0; i < indent; i++)
    closeIndent = [closeIndent stringByAppendingString:@"    "];
  [result appendString:closeIndent];
  [result appendString:@"</data>"];
  return result;
}

/* Format an MGValue from the binary parse tree for text output */
static NSString *_formatMGValue(MGValue *val, NSUInteger indent,
                                 NSDictionary *idToClass)
{
  if (!val) return @"null";

  /* Skip raw data blobs (no hex output) */
  if ([val.objectValue isKindOfClass:[NSData class]])
    return @"<raw>";

  uint8_t base = val.tag & GSC_MASK;

  /* Cross-references (object, class, selector, etc.) */
  if (val.tag & GSC_XREF)
    {
      if ((val.tag & GSC_SIZE) == GSC_X_0)
        return @"null";

      if (base == GSC_ID || base == GSC_CID)
        return [NSString stringWithFormat:@"@%u", val.xref];
      if (base == GSC_CLASS)
        return [NSString stringWithFormat:@"@%u", val.xref];
      if (base == GSC_SEL || base == GSC_CHARPTR)
        {
          if (val.stringValue)
            return [NSString stringWithFormat:@"\"%@\"", _escapeString(val.stringValue)];
          return [NSString stringWithFormat:@"@%u", val.xref];
        }
      if (base == GSC_PTR)
        return [NSString stringWithFormat:@"ptr@%u", val.xref];
      return [NSString stringWithFormat:@"@%u", val.xref];
    }

  switch (base)
    {
      case GSC_NONE:
        return @"null";

      case GSC_CHR:
      case GSC_UCHR:
      case GSC_SHT:
      case GSC_USHT:
      case GSC_INT:
      case GSC_UINT:
      case GSC_LNG:
      case GSC_ULNG:
      case GSC_LNG_LNG:
      case GSC_ULNG_LNG:
        if (val.tag & GSC_SIZE)
          return [NSString stringWithFormat:@"%lld", (long long)val.intValue];
        return [NSString stringWithFormat:@"%llu", (unsigned long long)val.uintValue];

      case GSC_FLT:
        return [NSString stringWithFormat:@"%g", val.floatValue];

      case GSC_DBL:
        return [NSString stringWithFormat:@"%g", val.doubleValue];

      case GSC_BOOL:
        return val.boolValue ? @"true" : @"false";

      case GSC_ID:
      case GSC_CLASS:
      case GSC_CID:
        return [NSString stringWithFormat:@"@%u", val.xref];

      case GSC_SEL:
      case GSC_CHARPTR:
        if (val.stringValue)
          return [NSString stringWithFormat:@"\"%@\"", _escapeString(val.stringValue)];
        return @"\"\"";

      case GSC_PTR:
        return [NSString stringWithFormat:@"ptr@%u", val.xref];

      case GSC_ARY_B:
        {
          NSMutableString *s = [NSMutableString stringWithString:@"[\n"];
          NSString *indentStr = @"";
          for (NSUInteger i = 0; i < indent + 1; i++)
            indentStr = [indentStr stringByAppendingString:@"    "];
          NSString *closeIndent = @"";
          for (NSUInteger i = 0; i < indent; i++)
            closeIndent = [closeIndent stringByAppendingString:@"    "];

          NSArray *children = val.children;
          for (NSUInteger i = 0; i < [children count]; i++)
            {
              [s appendString:indentStr];
              [s appendString:_formatMGValue([children objectAtIndex:i],
                                              indent + 1, idToClass)];
              if (i < [children count] - 1)
                [s appendString:@","];
              [s appendString:@"\n"];
            }
          [s appendString:closeIndent];
          [s appendString:@"]"];
          return s;
        }

      case GSC_STRUCT_B:
        {
          NSMutableString *s = [NSMutableString stringWithString:@"{\n"];
          NSString *indentStr = @"";
          for (NSUInteger i = 0; i < indent + 1; i++)
            indentStr = [indentStr stringByAppendingString:@"    "];
          NSString *closeIndent = @"";
          for (NSUInteger i = 0; i < indent; i++)
            closeIndent = [closeIndent stringByAppendingString:@"    "];

          NSArray *children = val.children;
          for (NSUInteger i = 0; i < [children count]; i++)
            {
              [s appendString:indentStr];
              [s appendFormat:@"_%lu = %@;\n",
                (unsigned long)i,
                _formatMGValue([children objectAtIndex:i], indent + 1, idToClass)];
            }
          [s appendString:closeIndent];
          [s appendString:@"}"];
          return s;
        }

      default:
        return [NSString stringWithFormat:@"0x%x", val.tag];
    }
}

+ (BOOL)writeArchive:(MGArchive *)archive
              toPath:(NSString *)path
               error:(NSError **)error
{
  NSString *text = [self textFromArchive:archive];
  return [text writeToFile:path
                atomically:YES
                  encoding:NSUTF8StringEncoding
                     error:error];
}

@end

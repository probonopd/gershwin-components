/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "MGArchiverWriter.h"

static inline uint16_t _swap16(uint16_t v)
{
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
  return (v >> 8) | (v << 8);
#else
  return v;
#endif
}

static inline uint32_t _swap32(uint32_t v)
{
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
  return ((v >> 24) & 0xff)
       | ((v >>  8) & 0xff00)
       | ((v <<  8) & 0xff0000)
       | ((v << 24) & 0xff000000);
#else
  return v;
#endif
}

static inline uint64_t _swap64(uint64_t v)
{
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
  return ((uint64_t)_swap32((uint32_t)v) << 32)
       | _swap32((uint32_t)(v >> 32));
#else
  return v;
#endif
}

static uint8_t _xrefSizeBits(uint32_t xref)
{
  if (xref <= 0xff)    return GSC_X_1;
  if (xref <= 0xffff)  return GSC_X_2;
  return GSC_X_4;
}

static void _writeXref(NSMutableData *data, uint32_t xref)
{
  if (xref <= 0xff) {
    uint8_t v = (uint8_t)xref;
    [data appendBytes:&v length:1];
  } else if (xref <= 0xffff) {
    uint16_t v = _swap16((uint16_t)xref);
    [data appendBytes:&v length:2];
  } else {
    uint32_t v = _swap32(xref);
    [data appendBytes:&v length:4];
  }
}

static void _writeU64BE(NSMutableData *data, uint64_t val, NSUInteger bytes)
{
  uint8_t buf[8] = {0};
  for (NSUInteger i = 0; i < bytes; i++) {
    buf[i] = (val >> ((bytes - 1 - i) * 8)) & 0xff;
  }
  [data appendBytes:buf length:bytes];
}

@implementation MGArchiverWriter

- (NSData *)archiveDataFromArchive:(MGArchive *)archive error:(NSError **)error
{
  NSMutableData *data = [NSMutableData data];

  [self writeHeader:archive into:data];
  [self writeClassDefs:archive.classDefs into:data];

  for (MGArchiveObject *object in archive.objects) {
    for (MGValue *value in object.encodedValues) {
      [self writeValue:value into:data];
    }
  }

  return data;
}

- (void)writeHeader:(MGArchive *)archive into:(NSMutableData *)data
{
  NSString *hdr = [NSString stringWithFormat:
    @"GNUstep archive%08x:%08x:%08x:%08x:",
    archive.systemVersion,
    archive.classCount,
    archive.objectCount,
    archive.pointerCount];
  [data appendData:[hdr dataUsingEncoding:NSASCIIStringEncoding]];
}

- (void)writeClassDefs:(NSArray *)classDefs into:(NSMutableData *)data
{
  uint32_t idx = 1;
  for (MGClassDef *cd in classDefs) {
    uint8_t tag = GSC_CLASS | GSC_XREF | _xrefSizeBits(idx);
    [data appendBytes:&tag length:1];
    _writeXref(data, idx);

    NSData *nData = [cd.name dataUsingEncoding:NSUTF8StringEncoding];
    uint16_t nLen = _swap16((uint16_t)[nData length]);
    [data appendBytes:&nLen length:2];
    [data appendData:nData];

    uint32_t ver = _swap32((uint32_t)cd.version);
    [data appendBytes:&ver length:4];
    idx++;
  }

  uint8_t end = GSC_NONE;
  [data appendBytes:&end length:1];
}

- (void)writeValue:(MGValue *)value into:(NSMutableData *)data
{
  if (value.rawData) {
    [data appendData:value.rawData];
    return;
  }

  uint8_t tag    = value.tag;
  uint8_t base   = tag & GSC_MASK;

  if (tag & GSC_XREF) {
    uint8_t outTag = base | GSC_XREF | _xrefSizeBits(value.xref);
    [data appendBytes:&outTag length:1];
    _writeXref(data, value.xref);
    return;
  }

  switch (base) {
    case GSC_NONE:
      [data appendBytes:&tag length:1];
      return;

    case GSC_ARY_B:
      [self writeArrayValue:value tag:tag into:data];
      return;

    case GSC_STRUCT_B:
      [self writeStructValue:value tag:tag into:data];
      return;

    case GSC_SEL:
    case GSC_CHARPTR:
      [self writeInlineString:value tag:tag into:data];
      return;

    default:
      if ((tag & GSC_SIZE) == GSC_X_0) {
        [data appendBytes:&tag length:1];
        return;
      }
      [self writeScalar:value tag:tag into:data];
      return;
  }
}

- (void)writeScalar:(MGValue *)value tag:(uint8_t)tag into:(NSMutableData *)data
{
  uint8_t base = tag & GSC_MASK;
  [data appendBytes:&tag length:1];

  switch (base) {
    case GSC_CHR: {
      int8_t v = (int8_t)value.intValue;
      [data appendBytes:&v length:1];
      break;
    }
    case GSC_UCHR:
    case GSC_BOOL: {
      uint8_t v = (uint8_t)(base == GSC_UCHR ? value.uintValue
                                             : (uint64_t)value.boolValue);
      [data appendBytes:&v length:1];
      break;
    }
    case GSC_SHT: {
      int16_t v = _swap16((int16_t)value.intValue);
      [data appendBytes:&v length:2];
      break;
    }
    case GSC_USHT: {
      uint16_t v = _swap16((uint16_t)value.uintValue);
      [data appendBytes:&v length:2];
      break;
    }
    case GSC_INT:
    case GSC_UINT:
    case GSC_LNG:
    case GSC_ULNG: {
      NSUInteger bytes = 4;
      switch (tag & GSC_SIZE) {
        case GSC_I16:  bytes = 2; break;
        case GSC_I32:  bytes = 4; break;
        case GSC_I64:  bytes = 8; break;
        default:       bytes = 4; break;
      }
      BOOL s = (base == GSC_INT || base == GSC_LNG);
      _writeU64BE(data, s ? (uint64_t)value.intValue : value.uintValue, bytes);
      break;
    }
    case GSC_LNG_LNG: {
      uint64_t v = _swap64((uint64_t)value.intValue);
      [data appendBytes:&v length:8];
      break;
    }
    case GSC_ULNG_LNG: {
      uint64_t v = _swap64(value.uintValue);
      [data appendBytes:&v length:8];
      break;
    }
    case GSC_FLT: {
      uint32_t fBits;
      float f = value.floatValue;
      memcpy(&fBits, &f, sizeof(fBits));
      fBits = _swap32(fBits);
      [data appendBytes:&fBits length:4];
      break;
    }
    case GSC_DBL: {
      uint64_t dBits;
      double d = value.doubleValue;
      memcpy(&dBits, &d, sizeof(dBits));
      dBits = _swap64(dBits);
      [data appendBytes:&dBits length:8];
      break;
    }
    default:
      break;
  }
}

- (void)writeInlineString:(MGValue *)value tag:(uint8_t)tag into:(NSMutableData *)data
{
  [data appendBytes:&tag length:1];
  NSString *str = value.stringValue ?: @"";
  NSData *strData = [str dataUsingEncoding:NSUTF8StringEncoding];
  uint16_t len = _swap16((uint16_t)[strData length]);
  [data appendBytes:&len length:2];
  [data appendData:strData];
}

- (void)writeArrayValue:(MGValue *)value tag:(uint8_t)tag into:(NSMutableData *)data
{
  [data appendBytes:&tag length:1];
  uint32_t count = _swap32((uint32_t)[value.children count]);
  [data appendBytes:&count length:4];
  for (MGValue *child in value.children) {
    [self writeValue:child into:data];
  }
}

- (void)writeStructValue:(MGValue *)value tag:(uint8_t)tag into:(NSMutableData *)data
{
  [data appendBytes:&tag length:1];
  for (MGValue *child in value.children) {
    [self writeValue:child into:data];
  }
}

@end

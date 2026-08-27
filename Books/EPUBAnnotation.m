/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EPUBAnnotation.h"

@implementation EPUBAnnotation

+ (NSColor *)colorForLabel:(NSString *)label
{
  if ([label isEqualToString:@"green"])
    return [NSColor colorWithCalibratedRed:0.55 green:0.92 blue:0.40 alpha:1.0];
  if ([label isEqualToString:@"blue"])
    return [NSColor colorWithCalibratedRed:0.45 green:0.78 blue:1.0 alpha:1.0];
  if ([label isEqualToString:@"red"])
    return [NSColor colorWithCalibratedRed:1.0 green:0.45 blue:0.45 alpha:1.0];
  if ([label isEqualToString:@"pink"])
    return [NSColor colorWithCalibratedRed:1.0 green:0.65 blue:0.88 alpha:1.0];
  return [NSColor colorWithCalibratedRed:1.0 green:0.88 blue:0.18 alpha:1.0]; // yellow
}

+ (NSString *)defaultColorLabel
{
  return @"yellow";
}

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      _uuid = [[NSUUID UUID] UUIDString];
      _motivation = EPUBAnnotationHighlighting;
      _created = [NSDate date];
      _modified = _created;
      _colorLabel = [[self class] defaultColorLabel];
    }
  return self;
}

// EPUB Annotations 1.0 anchors an Annotation to a resource with one or more
// selectors. We always carry a TextQuoteSelector (exact text) plus a
// TextPositionSelector (offset within the document's reading text); a reading
// system can recover the passage from either, which is the resilient shape the
// spec recommends for cross-reader portability.
- (NSDictionary *)webAnnotationDictionary
{
  NSMutableDictionary *anno = [NSMutableDictionary dictionary];
  anno[@"@context"] = @"http://www.w3.org/ns/anno.jsonld";
  anno[@"id"] = [NSString stringWithFormat:@"urn:uuid:%@", _uuid];
  anno[@"type"] = @"Annotation";

  NSString *mot = @"highlighting";
  if (_motivation == EPUBAnnotationBookmarking) mot = @"bookmarking";
  else if (_motivation == EPUBAnnotationCommenting) mot = @"commenting";
  anno[@"motivation"] = mot;

  NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
  [fmt setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
  [fmt setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
  if (_created) anno[@"created"] = [fmt stringFromDate:_created];
  if (_modified) anno[@"modified"] = [fmt stringFromDate:_modified];

  NSMutableArray *bodies = [NSMutableArray array];
  if (_note != nil && [_note length] > 0)
    [bodies addObject:@{ @"type": @"TextualBody", @"purpose": @"commenting",
                          @"value": _note, @"format": @"text/plain" }];
  if (_motivation != EPUBAnnotationBookmarking)
    [bodies addObject:@{ @"type": @"TextualBody", @"purpose": @"highlighting",
                          @"value": (_colorLabel ?: [self.class defaultColorLabel]),
                          @"format": @"text/plain" }];
  if ([bodies count] == 1)
    anno[@"body"] = bodies[0];
  else if ([bodies count] > 1)
    anno[@"body"] = bodies;

  NSMutableArray *selectors = [NSMutableArray array];
  if (_exact != nil && [_exact length] > 0)
    [selectors addObject:@{ @"type": @"TextQuoteSelector", @"exact": _exact }];
  [selectors addObject:@{ @"type": @"TextPositionSelector",
                          @"start": @(_docStart), @"end": @(_docEnd) }];

  NSMutableDictionary *target = [NSMutableDictionary dictionary];
  target[@"source"] = (_source ?: @"");
  target[@"selector"] = selectors;
  anno[@"target"] = target;

  return anno;
}

- (instancetype)initWithWebAnnotationDictionary:(NSDictionary *)dict
{
  self = [super init];
  if (self)
    {
      _motivation = EPUBAnnotationHighlighting;
      _colorLabel = [[self class] defaultColorLabel];

      NSString *ctxId = dict[@"id"];
      if ([ctxId hasPrefix:@"urn:uuid:"])
        _uuid = [ctxId substringFromIndex:9];
      else
        _uuid = [[NSUUID UUID] UUIDString];

      NSString *mot = dict[@"motivation"];
      if ([mot isEqualToString:@"bookmarking"]) _motivation = EPUBAnnotationBookmarking;
      else if ([mot isEqualToString:@"commenting"]) _motivation = EPUBAnnotationCommenting;

      NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
      [fmt setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
      [fmt setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
      if ([dict[@"created"] isKindOfClass:[NSString class]])
        _created = [fmt dateFromString:dict[@"created"]];
      if ([dict[@"modified"] isKindOfClass:[NSString class]])
        _modified = [fmt dateFromString:dict[@"modified"]];
      if (_created == nil) _created = [NSDate date];
      if (_modified == nil) _modified = _created;

      id body = dict[@"body"];
      NSArray *bodyList = nil;
      if ([body isKindOfClass:[NSArray class]])
        bodyList = body;
      else if (body != nil)
        bodyList = @[ body ];
      for (NSDictionary *b in bodyList)
        {
          NSString *purpose = b[@"purpose"];
          NSString *value = b[@"value"];
          if ([purpose isEqualToString:@"commenting"])
            _note = [value copy];
          else if ([purpose isEqualToString:@"highlighting"] && [value length] > 0)
            _colorLabel = [value copy];
        }

      id target = dict[@"target"];
      if ([target isKindOfClass:[NSDictionary class]])
        {
          _source = [target[@"source"] copy];
          id sel = target[@"selector"];
          NSArray *selList = nil;
          if ([sel isKindOfClass:[NSArray class]])
            selList = sel;
          else if (sel != nil)
            selList = @[ sel ];
          for (NSDictionary *s in selList)
            {
              NSString *type = s[@"type"];
              if ([type isEqualToString:@"TextQuoteSelector"])
                _exact = [s[@"exact"] copy];
              else if ([type isEqualToString:@"TextPositionSelector"])
                {
                  _docStart = [s[@"start"] unsignedIntegerValue];
                  _docEnd = [s[@"end"] unsignedIntegerValue];
                }
            }
        }
    }
  return self;
}

@end

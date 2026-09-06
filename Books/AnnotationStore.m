/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "AnnotationStore.h"
#import "LibraryBook.h"

@implementation AnnotationStore
{
  NSString *_path;
}

- (instancetype)initWithBook:(LibraryBook *)book
{
  self = [super init];
  if (self)
    {
      // Keep the annotation sidecar next to the book itself, sharing its
      // filename but with a different extension, so annotations travel with the
      // EPUB and are easy to back up or move alongside it.
      NSString *epub = book.epubPath;
      if ([epub length] == 0)
        epub = @"book.epub";
      _path = [[epub stringByDeletingPathExtension]
          stringByAppendingPathExtension:@"annot.json"];
    }
  return self;
}

- (NSString *)path
{
  return _path;
}

- (NSArray<EPUBAnnotation *> *)load
{
  NSData *data = [NSData dataWithContentsOfFile:_path];
  if (data == nil)
    return @[];
  NSError *err = nil;
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
  if (obj == nil || err != nil)
    {
      NSLog(@"Books: could not parse annotations at %@: %@", _path, err);
      return @[];
    }
  NSMutableArray *out = [NSMutableArray array];
  NSArray *items = nil;
  if ([obj isKindOfClass:[NSDictionary class]])
    items = obj[@"items"];
  if ([obj isKindOfClass:[NSArray class]])
    items = obj;
  if (items == nil || ![items isKindOfClass:[NSArray class]])
    return @[];
  for (id item in items)
    {
      if (![item isKindOfClass:[NSDictionary class]])
        continue;
      EPUBAnnotation *a = [[EPUBAnnotation alloc] initWithWebAnnotationDictionary:item];
      [out addObject:a];
    }
  return out;
}

- (BOOL)saveAnnotations:(NSArray<EPUBAnnotation *> *)annotations
{
  NSMutableArray *items = [NSMutableArray arrayWithCapacity:[annotations count]];
  for (EPUBAnnotation *a in annotations)
    [items addObject:[a webAnnotationDictionary]];

  NSMutableDictionary *set = [NSMutableDictionary dictionary];
  set[@"@context"] = @"http://www.w3.org/ns/anno.jsonld";
  set[@"id"] = [NSString stringWithFormat:@"urn:uuid:%@",
                [[[NSUUID UUID] UUIDString] lowercaseString]];
  set[@"type"] = @"AnnotationSet";
  set[@"generator"] = @{ @"type": @"Software", @"name": @"Gershwin Books",
                         @"homepage": @"https://github.com/gershwin-desktop" };
  set[@"created"] = [self iso8601Now];
  set[@"items"] = items;

  NSError *err = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:set
                                                 options:NSJSONWritingPrettyPrinted
                                                   error:&err];
  if (data == nil || err != nil)
    {
      NSLog(@"Books: could not serialize annotations: %@", err);
      return NO;
    }
  if ([data writeToFile:_path atomically:YES] == NO)
    {
      NSLog(@"Books: could not write annotations to %@", _path);
      return NO;
    }
  return YES;
}

- (NSString *)iso8601Now
{
  NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
  [fmt setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
  [fmt setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
  return [fmt stringFromDate:[NSDate date]];
}

@end

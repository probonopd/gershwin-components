/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "LibraryBook.h"
#import "EPUBBook.h"

@implementation LibraryBook

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      _addedDate = [NSDate date];
      _lastSpreadIndex = 0;
      _fontSize = 16.0;
      _theme = 0;
    }
  return self;
}

- (instancetype)initWithEpubPath:(NSString *)path
{
  self = [self init];
  if (self)
    {
      _epubPath = [path copy];
      _title = [[path lastPathComponent] copy];
      _author = @"";
      _coverPath = nil;
      NSError *err = nil;
      EPUBBook *book = [[EPUBBook alloc] initWithEPUBAtPath:path error:&err];
      if (book)
        {
          if ([book.title length] > 0)
            _title = [book.title copy];
          if ([book.author length] > 0)
            _author = [book.author copy];
          if ([book.coverPath length] > 0)
            _coverPath = [book.coverPath copy];
          [book cleanupExtraction];
        }
    }
  return self;
}

- (NSString *)displayTitle
{
  return (_title != nil && [_title length] > 0) ? _title : @"Untitled";
}

- (NSString *)displayAuthor
{
  return (_author != nil && [_author length] > 0) ? _author : @"Unknown author";
}

- (void)encodeWithCoder:(NSCoder *)coder
{
  [coder encodeObject:_epubPath forKey:@"epubPath"];
  [coder encodeObject:_title forKey:@"title"];
  [coder encodeObject:_author forKey:@"author"];
  [coder encodeObject:_coverPath forKey:@"coverPath"];
  [coder encodeObject:_addedDate forKey:@"addedDate"];
  [coder encodeInteger:(NSInteger)_lastSpreadIndex forKey:@"lastSpreadIndex"];
  [coder encodeDouble:_fontSize forKey:@"fontSize"];
  [coder encodeInteger:_theme forKey:@"theme"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
  self = [super init];
  if (self)
    {
      _epubPath = [coder decodeObjectForKey:@"epubPath"];
      _title = [coder decodeObjectForKey:@"title"];
      _author = [coder decodeObjectForKey:@"author"];
      _coverPath = [coder decodeObjectForKey:@"coverPath"];
      _addedDate = [coder decodeObjectForKey:@"addedDate"];
      _lastSpreadIndex = (NSUInteger)[coder decodeIntegerForKey:@"lastSpreadIndex"];
      _fontSize = [coder decodeDoubleForKey:@"fontSize"];
      _theme = [coder decodeIntegerForKey:@"theme"];
      if (_fontSize < 8.0) _fontSize = 16.0;
    }
  return self;
}

@end

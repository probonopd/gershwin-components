/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "LibraryStore.h"
#import "LibraryBook.h"

@interface LibraryBook ()

@end

@interface LibraryStore ()

@property (nonatomic, strong) NSMutableArray<LibraryBook *> *mutableBooks;

@end

@implementation LibraryStore

+ (instancetype)sharedStore
{
  static LibraryStore *store = nil;
  if (store == nil)
    store = [[LibraryStore alloc] init];
  return store;
}

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      _mutableBooks = [NSMutableArray array];
      [self load];
    }
  return self;
}

- (NSArray<LibraryBook *> *)books
{
  return [_mutableBooks copy];
}

- (NSString *)storePath
{
  NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                      NSUserDomainMask, YES);
  NSString *base = [dirs firstObject];
  if (base == nil)
    base = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Books"];
  NSString *dir = [base stringByAppendingPathComponent:@"Books"];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
  return [dir stringByAppendingPathComponent:@"library.plist"];
}

- (void)load
{
  NSString *path = [self storePath];
  NSData *data = [NSData dataWithContentsOfFile:path];
  if (data == nil) return;
  @try
    {
      NSArray *arr = [NSKeyedUnarchiver unarchiveObjectWithData:data];
      if ([arr isKindOfClass:[NSArray class]])
        {
          for (id obj in arr)
            {
              if ([obj isKindOfClass:[LibraryBook class]])
                [_mutableBooks addObject:obj];
            }
        }
    }
  @catch (id ex)
    {
      NSLog(@"Books: failed to load library store: %@", ex);
    }
}

- (void)save
{
  NSString *path = [self storePath];
  NSData *data = [NSKeyedArchiver archivedDataWithRootObject:[_mutableBooks copy]];
  if (data)
    [data writeToFile:path atomically:YES];
}

- (BOOL)containsBookAtPath:(NSString *)path
{
  NSString *std = [path stringByStandardizingPath];
  for (LibraryBook *b in _mutableBooks)
    {
      if ([[b.epubPath stringByStandardizingPath] isEqualToString:std])
        return YES;
    }
  return NO;
}

- (void)addBookAtPath:(NSString *)path
{
  if ([self containsBookAtPath:path]) return;
  LibraryBook *book = [[LibraryBook alloc] initWithEpubPath:path];
  [_mutableBooks addObject:book];
  [self save];
}

- (void)removeBook:(LibraryBook *)book
{
  [_mutableBooks removeObject:book];
  [self save];
}

@end

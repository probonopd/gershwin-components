/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EPUBBook.h"
#import "EPUBParser.h"

@interface EPUBBook ()
@property (nonatomic, copy, readwrite) NSString *extractedRoot;
@end

@implementation EPUBBook

- (instancetype)initWithEPUBAtPath:(NSString *)epubPath error:(NSError **)error
{
    self = [super init];
    if (self == nil)
    {
        return nil;
    }
    EPUBParser *parser = [[EPUBParser alloc] init];
    EPUBBook *result = [parser parseEPUBAtPath:epubPath error:error];
    if (result == nil)
    {
        return nil;
    }
    _title = [result.title copy];
    _author = [result.author copy];
    _identifier = [result.identifier copy];
    _language = [result.language copy];
    _publisher = [result.publisher copy];
    _coverPath = [result.coverPath copy];
    _spine = [result.spine copy];
    _tableOfContents = [result.tableOfContents copy];
    _extractedRoot = [result.extractedRoot copy];
    return self;
}

- (NSString *)absolutePathForContent:(NSString *)relativePath
{
    if (relativePath == nil)
    {
        return nil;
    }
    if ([relativePath isAbsolutePath])
    {
        return relativePath;
    }
    return [self.extractedRoot stringByAppendingPathComponent:relativePath];
}

- (void)cleanupExtraction
{
    if (self.extractedRoot == nil)
    {
        return;
    }
    [[NSFileManager defaultManager] removeItemAtPath:self.extractedRoot error:NULL];
}

@end

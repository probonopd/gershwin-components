/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "OPDSFeedParser.h"

static NSString *LocalName(NSString *name)
{
  NSRange r = [name rangeOfString:@":"];
  if (r.location != NSNotFound)
    return [name substringFromIndex:r.location + 1];
  return name;
}

#pragma mark - OPDSXMLParser (inner helper)

// Lightweight NSXMLParserDelegate that extracts <entry> elements from an
// Atom/OPDS feed. Only the fields we need are collected.
@interface OPDSXMLParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<OPDSEntry *> *entries;
@property (nonatomic, copy) NSString *feedTitle;
@end

@implementation OPDSXMLParser
{
  NSMutableString *_text;
  OPDSEntry *_current;
  BOOL _inEntry;
  BOOL _inAuthor;
}

- (void)parseData:(NSData *)data
{
  _entries = [NSMutableArray array];
  _feedTitle = nil;
  _text = nil;
  _current = nil;
  _inEntry = NO;
  _inAuthor = NO;

  NSXMLParser *p = [[NSXMLParser alloc] initWithData:data];
  [p setShouldResolveExternalEntities:NO];
  [p setDelegate:self];
  [p parse];
}

#pragma mark NSXMLParserDelegate

- (void)parser:(NSXMLParser *)parser
didStartElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qn
    attributes:(NSDictionary *)attrs
{
  NSString *e = LocalName(elementName);

  if ([e isEqualToString:@"entry"])
    {
      _inEntry = YES;
      _current = [[OPDSEntry alloc] init];
      _text = [NSMutableString string];
      return;
    }
  if (!_inEntry)
    {
      if ([e isEqualToString:@"title"])
        {
          _text = [NSMutableString string];
          return;
        }
      return;
    }

  // Inside <entry>
  if ([e isEqualToString:@"author"])
    {
      _inAuthor = YES;
      _text = [NSMutableString string];
      return;
    }
  if ([e isEqualToString:@"title"] || [e isEqualToString:@"summary"] ||
      [e isEqualToString:@"id"])
    {
      _text = [NSMutableString string];
      return;
    }
  if ([e isEqualToString:@"link"])
    {
      NSString *href = attrs[@"href"];
      NSString *rel = attrs[@"rel"] ?: @"";
      NSString *type = attrs[@"type"] ?: @"";

      BOOL isEpub = ([type isEqualToString:@"application/epub+zip"] ||
                     [rel isEqualToString:@"http://opds-spec.org/acquisition/open"] ||
                     [rel isEqualToString:@"http://opds-spec.org/acquisition/"] ||
                     [rel isEqualToString:@"http://opds-spec.org/acquisition/buy"] ||
                     [rel isEqualToString:@"http://opds-spec.org/acquisition/borrow"] ||
                     [rel isEqualToString:@"http://opds-spec.org/acquisition/sample"]);
      if (isEpub && href != nil && _current.epubURL == nil)
        _current.epubURL = [NSURL URLWithString:href];

      BOOL isCover = ([rel isEqualToString:@"http://opds-spec.org/thumbnail"] ||
                      [rel isEqualToString:@"http://opds-spec.org/cover"] ||
                      [type hasPrefix:@"image/"]);
      if (isCover && href != nil && _current.coverURL == nil)
        _current.coverURL = [NSURL URLWithString:href];

      // Subsection link: the per-book OPDS feed containing download links.
      if ([rel isEqualToString:@"subsection"] && href != nil &&
          _current.subsectionURL == nil)
        _current.subsectionURL = [NSURL URLWithString:href];
      return;
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
  if (_text != nil)
    [_text appendString:string];
}

- (void)parser:(NSXMLParser *)parser
 didEndElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI
 qualifiedName:(NSString *)qn
{
  NSString *e = LocalName(elementName);

  if (!_inEntry)
    {
      if ([e isEqualToString:@"title"] && _text != nil)
        {
          NSString *t = [_text stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
          if ([t length] > 0) _feedTitle = t;
        }
      _text = nil;
      return;
    }

  if ([e isEqualToString:@"author"])
    {
      _inAuthor = NO;
      NSString *name = [_text stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if ([name length] > 0 && _current.author == nil)
        _current.author = name;
      _text = nil;
      return;
    }
  if ([_text length] > 0)
    {
      NSString *trimmed = [_text stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if ([e isEqualToString:@"title"])
        _current.title = trimmed;
      else if ([e isEqualToString:@"summary"])
        _current.summary = trimmed;
      else if ([e isEqualToString:@"id"])
        _current.identifier = trimmed;
    }
  _text = nil;

  if ([e isEqualToString:@"entry"])
    {
      if (_current.title != nil)
        [_entries addObject:_current];
      _current = nil;
      _inEntry = NO;
    }
}

@end

#pragma mark - OPDSFeedParser

@implementation OPDSFeedParser
{
  NSOperationQueue *_backgroundQueue;
}

- (instancetype)init
{
  self = [super init];
  if (self)
    {
      _backgroundQueue = [[NSOperationQueue alloc] init];
      [_backgroundQueue setMaxConcurrentOperationCount:1];
    }
  return self;
}

- (void)fetchFeedAtURL:(NSURL *)url
             searchFor:(NSString *)query
            completion:(void (^)(NSArray<OPDSEntry *> *entries,
                                 NSString *feedTitle,
                                 NSError *error))completion
{
  NSURL *fetchURL = url;
  if ([query length] > 0)
    {
      NSString *encoded = [query stringByAddingPercentEscapesUsingEncoding:
          NSUTF8StringEncoding];
      NSString *sep = ([url query] != nil) ? @"&" : @"?";
      fetchURL = [NSURL URLWithString:
          [[url absoluteString] stringByAppendingFormat:@"%@query=%@", sep, encoded]];
    }

  NSURL *finalURL = fetchURL;
  OPDSFeedParser *blockSelf = self;
  NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:^{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/curl"];
    [task setArguments:@[ @"-sL", @"--max-time", @"30",
                          @"-H", @"Accept: application/atom+xml;profile=opds-catalog",
                          [finalURL absoluteString] ]];
    NSPipe *outPipe = [NSPipe pipe];
    [task setStandardOutput:outPipe];
    [task setStandardError:[NSPipe pipe]];
    [task launch];
    [task waitUntilExit];

    NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
    int status = [task terminationStatus];
    if (status != 0 || data == nil || [data length] == 0)
      {
        NSError *err = [NSError errorWithDomain:@"OPDSFeed" code:status
                        userInfo:@{ NSLocalizedDescriptionKey:
                          @"Failed to fetch feed (curl error)" }];
        [blockSelf _deliverFetchError:err completion:completion];
        return;
      }

    OPDSXMLParser *xp = [[OPDSXMLParser alloc] init];
    [xp parseData:data];

    NSArray *entries = [xp.entries copy];
    NSString *feedTitle = [xp.feedTitle copy];
    [blockSelf _deliverFetchResult:entries title:feedTitle completion:completion];
  }];
  [_backgroundQueue addOperation:op];
}

- (void)resolveEPUBLinksForEntries:(NSArray<OPDSEntry *> *)entries
                        completion:(void (^)(NSArray<OPDSEntry *> *resolved))completion
{
  NSArray *entriesCopy = [entries copy];
  NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:^{
    NSMutableArray<OPDSEntry *> *resolved = [NSMutableArray array];
    for (OPDSEntry *entry in entriesCopy)
      {
        // Already has an EPUB link from the top-level feed.
        if (entry.epubURL != nil)
          {
            [resolved addObject:entry];
            continue;
          }
        // Need to follow the subsection link to get EPUB URLs.
        if (entry.subsectionURL == nil)
          continue;

        // Make the subsection URL absolute if it is relative.
        NSURL *subURL = entry.subsectionURL;
        if ([[subURL scheme] length] == 0)
          {
            // Relative to the Gutenberg root.
            subURL = [NSURL URLWithString:[@"https://www.gutenberg.org"
                stringByAppendingString:[subURL absoluteString]]];
          }

        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:@"/usr/bin/curl"];
        [task setArguments:@[ @"-sL", @"--max-time", @"15",
                              [subURL absoluteString] ]];
        NSPipe *outPipe = [NSPipe pipe];
        [task setStandardOutput:outPipe];
        [task setStandardError:[NSPipe pipe]];
        [task launch];
        [task waitUntilExit];

        NSData *data = [[outPipe fileHandleForReading] readDataToEndOfFile];
        if ([task terminationStatus] != 0 || data == nil)
          continue;

        OPDSXMLParser *xp = [[OPDSXMLParser alloc] init];
        [xp parseData:data];

        // The subsection feed has multiple entries, one per format.
        // Pick the best EPUB: prefer EPUB3 with images, then EPUB with images,
        // then the no-images variant.
        NSURL *bestEPUB = nil;
        for (OPDSEntry *detail in xp.entries)
          {
            if (detail.epubURL == nil) continue;
            NSString *path = [[detail.epubURL path] lowercaseString];
            if ([path hasSuffix:@"epub3.images"])
              { bestEPUB = detail.epubURL; break; }
            if ([path hasSuffix:@"epub.images"] || [path hasSuffix:@"epub3"])
              { if (bestEPUB == nil) bestEPUB = detail.epubURL; }
            if (bestEPUB == nil)
              bestEPUB = detail.epubURL;
          }
        if (bestEPUB != nil)
          {
            entry.epubURL = bestEPUB;
            // Prefer the detail's cover if the search entry had none.
            OPDSEntry *first = [xp.entries count] > 0 ? xp.entries[0] : nil;
            if (entry.coverURL == nil && first.coverURL != nil)
              entry.coverURL = first.coverURL;
            [resolved addObject:entry];
          }
      }

    // Deliver on the main queue.
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
      completion(resolved);
    }];
  }];
  [_backgroundQueue addOperation:op];
}

- (void)downloadEPUBAtURL:(NSURL *)url
               completion:(void (^)(NSString *path, NSError *error))completion
{
  NSURL *finalURL = url;
  OPDSFeedParser *blockSelf = self;
  NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:^{
    NSString *tmp = NSTemporaryDirectory();
    NSString *dir = [tmp stringByAppendingPathComponent:@"BooksDownloads"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    NSString *dest = [dir stringByAppendingPathComponent:
        ([[url lastPathComponent] length] > 0 ? [url lastPathComponent] : @"download.epub")];

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/curl"];
    [task setArguments:@[ @"-sL", @"--max-time", @"120",
                          @"-o", dest,
                          [finalURL absoluteString] ]];
    [task setStandardOutput:[NSPipe pipe]];
    [task setStandardError:[NSPipe pipe]];
    [task launch];
    [task waitUntilExit];

    int status = [task terminationStatus];
    if (status != 0)
      {
        NSError *err = [NSError errorWithDomain:@"OPDSFeed" code:status
                        userInfo:@{ NSLocalizedDescriptionKey:
                          @"Failed to download EPUB" }];
        [blockSelf _deliverDownloadError:err completion:completion];
        return;
      }

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:dest
                                                                           error:NULL];
    unsigned long long size = [attrs fileSize];
    if (size < 100)
      {
        NSError *err = [NSError errorWithDomain:@"OPDSFeed" code:-1
                        userInfo:@{ NSLocalizedDescriptionKey:
                          @"Downloaded file is too small to be an EPUB" }];
        [blockSelf _deliverDownloadError:err completion:completion];
        return;
      }

    [blockSelf _deliverDownloadResult:dest completion:completion];
  }];
  [_backgroundQueue addOperation:op];
}

#pragma mark - Main-thread delivery helpers

- (void)_deliverFetchResult:(NSArray<OPDSEntry *> *)entries
                      title:(NSString *)feedTitle
                 completion:(void (^)(NSArray<OPDSEntry *> *, NSString *, NSError *))completion
{
  [completion copy]; // ensure block is on heap
  NSArray *e = [entries copy];
  NSString *t = [feedTitle copy];
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    completion(e, t, nil);
  }];
}

- (void)_deliverFetchError:(NSError *)err
                completion:(void (^)(NSArray<OPDSEntry *> *, NSString *, NSError *))completion
{
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    completion(nil, nil, err);
  }];
}

- (void)_deliverDownloadResult:(NSString *)path
                    completion:(void (^)(NSString *, NSError *))completion
{
  NSString *p = [path copy];
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    completion(p, nil);
  }];
}

- (void)_deliverDownloadError:(NSError *)err
                   completion:(void (^)(NSString *, NSError *))completion
{
  [[NSOperationQueue mainQueue] addOperationWithBlock:^{
    completion(nil, err);
  }];
}

@end

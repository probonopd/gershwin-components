/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSHelpHistory.h"

@interface GSHelpHistory ()
{
    NSMutableArray<NSURL *> *_entries;
    NSInteger _position;  /* -1 = nothing visited yet */
}
@end

@implementation GSHelpHistory

- (instancetype)init
{
    self = [super init];
    if (self != nil)
      {
        _entries = [NSMutableArray new];
        _position = -1;
      }
    return self;
}

- (void)pushURL:(NSURL *)url
{
    if (url == nil)
      {
        return;
      }

    /* A fresh push drops the forward branch, matching browser
     * semantics (SPEC 44: opening a link creates a new entry). */
    while (_position + 1 < (NSInteger)[_entries count])
      {
        [_entries removeLastObject];
      }
    /* Re-pushing the URL we already sit on would make goBack a no-op
     * loop; skip instead. */
    if (_position >= 0 && [[_entries objectAtIndex: _position] isEqual: url])
      {
        return;
      }
    [_entries addObject: url];
    _position = (NSInteger)[_entries count] - 1;
}

- (nullable NSURL *)goBack
{
    if (_position <= 0)
      {
        return nil;
      }
    _position -= 1;
    return [_entries objectAtIndex: _position];
}

- (nullable NSURL *)goForward
{
    if (_position + 1 >= (NSInteger)[_entries count])
      {
        return nil;
      }
    _position += 1;
    return [_entries objectAtIndex: _position];
}

- (BOOL)canBack
{
    return _position > 0;
}

- (BOOL)canForward
{
    return _position + 1 < (NSInteger)[_entries count];
}

- (nullable NSURL *)currentURL
{
    if (_position < 0)
      {
        return nil;
      }
    return [_entries objectAtIndex: _position];
}

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSMenuExtraInstance.h"

@implementation GSMenuExtraInstance

- (instancetype)initWithExtra:(id<GSMenuExtra>)extra
                   identifier:(NSString *)identifier
                  displayName:(NSString *)displayName
                     priority:(NSInteger)priority
{
    self = [super init];
    if (self) {
        _extra = extra;
        _identifier = [identifier copy];
        _displayName = [displayName copy];
        _priority = priority;
        _cachedWidth = 0;
    }
    return self;
}

- (NSString *)title
{
    return [_extra title];
}

- (NSMenu *)menu
{
    return [_extra menu];
}

- (NSImage *)icon
{
    return [_extra image];
}

- (CGFloat)width
{
    if (_cachedWidth > 0) return _cachedWidth;
    NSFont *font = [NSFont menuBarFontOfSize:0];
    NSDictionary *attrs = @{ NSFontAttributeName: font };
    NSString *display = [self title];
    if (!display || [display length] == 0) display = @"  ";
    NSSize size = [display sizeWithAttributes:attrs];
    _cachedWidth = ceil(size.width) + 16.0;
    return _cachedWidth;
}

- (void)invalidateWidth
{
    _cachedWidth = 0;
}

- (void)unload
{
    if ([_extra respondsToSelector:@selector(menuExtraWillUnload)]) {
        [_extra menuExtraWillUnload];
    }
}

- (void)menuWillOpen
{
    if ([_extra respondsToSelector:@selector(menuExtraWillOpenMenu)]) {
        [_extra menuExtraWillOpenMenu];
    }
}

- (void)menuDidClose
{
    if ([_extra respondsToSelector:@selector(menuExtraDidCloseMenu)]) {
        [_extra menuExtraDidCloseMenu];
    }
}

- (NSInteger)displayPriority
{
    return _priority;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %@>", [self class], _identifier];
}

@end

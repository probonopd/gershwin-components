/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSMenuExtraInstance.h"
#import "GSMenuExtraContext.h"
#import "MenuExtraManager.h"

@implementation GSMenuExtraInstance
{
    id<GSMenuExtra> _extra;
    NSString *_identifier;
    NSString *_displayName;
    NSInteger _priority;
    GSMenuExtraContext *_context;
}

- (instancetype)initWithExtra:(id<GSMenuExtra>)extra
                   identifier:(NSString *)identifier
                  displayName:(NSString *)displayName
                     priority:(NSInteger)priority
                     manager:(MenuExtraManager *)manager
{
    self = [super init];
    if (self) {
        _extra = extra;
        _identifier = [identifier copy];
        _displayName = [displayName copy];
        _priority = priority;
        _cachedWidth = 0;

        _context = [[GSMenuExtraContext alloc] initWithManager:manager
                                                    identifier:_identifier];
        if ([_extra respondsToSelector:@selector(setContext:)]) {
            [_extra setContext:_context];
        }
    }
    return self;
}

- (BOOL)load
{
    @try {
        if ([_extra respondsToSelector:@selector(menuExtraDidLoad)]) {
            [_extra menuExtraDidLoad];
        }
        return YES;
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in load for %@: %@", _identifier, e);
        return NO;
    }
}

- (void)unload
{
    @try {
        if ([_extra respondsToSelector:@selector(menuExtraWillUnload)]) {
            [_extra menuExtraWillUnload];
        }
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in unload for %@: %@", _identifier, e);
    }
}

- (NSString *)title
{
    @try {
        return [_extra title];
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in title for %@: %@", _identifier, e);
        return _identifier;
    }
}

- (NSMenu *)menu
{
    @try {
        return [_extra menu];
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in menu for %@: %@", _identifier, e);
        return nil;
    }
}

- (NSImage *)icon
{
    @try {
        return [_extra image];
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in icon for %@: %@", _identifier, e);
        return nil;
    }
}

- (CGFloat)width
{
    if (_cachedWidth > 0) return _cachedWidth;
    NSString *display = [self title];
    if (!display || [display length] == 0) display = @"  ";
    NSFont *font = [NSFont menuBarFontOfSize:0];
    NSSize size = [display sizeWithAttributes:@{ NSFontAttributeName: font }];
    _cachedWidth = ceil(size.width) + 8.0;
    return _cachedWidth;
}

- (void)invalidateWidth
{
    _cachedWidth = 0;
}

- (void)tick
{
    @try {
        if ([_extra respondsToSelector:@selector(tick)]) {
            [(id)_extra performSelector:@selector(tick)];
        }
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in tick for %@: %@", _identifier, e);
    }
}

- (void)menuWillOpen
{
    @try {
        if ([_extra respondsToSelector:@selector(menuExtraWillOpenMenu)]) {
            [_extra menuExtraWillOpenMenu];
        }
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in menuWillOpen for %@: %@", _identifier, e);
    }
}

- (void)menuDidClose
{
    @try {
        if ([_extra respondsToSelector:@selector(menuExtraDidCloseMenu)]) {
            [_extra menuExtraDidCloseMenu];
        }
    } @catch (NSException *e) {
        NSLog(@"GSMenuExtraInstance: exception in menuDidClose for %@: %@", _identifier, e);
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

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageObject.h"

@interface DUStorageObject ()
@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, readwrite) DUStorageObjectType type;
@end

@implementation DUStorageObject {
    NSMutableArray<DUStorageObject *> *_childList;
}

- (instancetype)initWithType:(DUStorageObjectType)type
                  identifier:(NSString *)identifier
{
    NSParameterAssert(identifier != nil);
    NSParameterAssert(identifier.length > 0);
    if ((self = [super init]) == nil) {
        return nil;
    }
    _type = type;
    _identifier = [identifier copy];
    _displayName = [_identifier copy];
    _capabilities = [DUStorageCapabilities capabilitiesWithAll:NO];
    _childList = [NSMutableArray array];
    return self;
}

- (NSArray<DUStorageObject *> *)children
{
    return [_childList copy];
}

- (void)addChild:(DUStorageObject *)child
{
    NSParameterAssert(child != nil);
    NSParameterAssert(child != self);
    // Keep the single-parent invariant; re-parenting moves the child.
    if (child.parent != nil && child.parent != self) {
        [child.parent removeChild:child];
    }
    if ([_childList containsObject:child]) {
        return;
    }
    child.parent = self;
    [_childList addObject:child];
}

- (void)removeChild:(DUStorageObject *)child
{
    NSParameterAssert(child != nil);
    if (![_childList containsObject:child]) {
        return;
    }
    [_childList removeObject:child];
    if (child.parent == self) {
        child.parent = nil;
    }
}

- (DUStorageObject *)objectForIdentifier:(NSString *)identifier
{
    if ([_identifier isEqualToString:identifier]) {
        return self;
    }
    for (DUStorageObject *child in _childList) {
        DUStorageObject *match = [child objectForIdentifier:identifier];
        if (match != nil) {
            return match;
        }
    }
    return nil;
}

- (NSArray<DUStorageObject *> *)flattenObjects
{
    NSMutableArray<DUStorageObject *> *flat =
        [NSMutableArray arrayWithObject:self];
    for (DUStorageObject *child in _childList) {
        [flat addObjectsFromArray:[child flattenObjects]];
    }
    return flat;
}

@end

/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSMenuExtraInstance.h"
#import "StatusItemView.h"

@implementation GSMenuExtraInstance

- (instancetype)initWithProvider:(id<StatusItemProvider>)provider
                            view:(StatusItemView *)view
{
    self = [super init];
    if (self) {
        _provider = provider;
        _view = view;
        _identifier = [[provider identifier] copy];
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %@>", [self class], _identifier];
}

@end

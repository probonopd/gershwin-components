/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSMenuExtraContext.h"
#import "StatusItemManager.h"

@implementation GSMenuExtraContext

- (instancetype)initWithManager:(StatusItemManager *)manager
                     identifier:(NSString *)identifier
{
    self = [super init];
    if (self) {
        _manager = manager;
        _identifier = [identifier copy];
    }
    return self;
}

- (void)invalidatePresentation
{
    [_manager refreshExtraWithIdentifier:_identifier];
}

@end

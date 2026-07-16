/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class StatusItemManager;

@interface GSMenuExtraContext : NSObject

@property (nonatomic, weak) StatusItemManager *manager;
@property (nonatomic, copy) NSString *identifier;

- (instancetype)initWithManager:(StatusItemManager *)manager
                     identifier:(NSString *)identifier;

- (void)invalidatePresentation;

@end

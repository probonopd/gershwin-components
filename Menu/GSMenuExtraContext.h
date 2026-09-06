/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@class MenuExtraManager;

@interface GSMenuExtraContext : NSObject

@property (nonatomic, weak) MenuExtraManager *manager;
@property (nonatomic, copy) NSString *identifier;

- (instancetype)initWithManager:(MenuExtraManager *)manager
                     identifier:(NSString *)identifier;

- (void)invalidatePresentation;

@end

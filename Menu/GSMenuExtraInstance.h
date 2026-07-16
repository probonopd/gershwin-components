/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "StatusItemProvider.h"

@class StatusItemView;

@interface GSMenuExtraInstance : NSObject

@property (readonly) id<StatusItemProvider> provider;
@property (readonly) StatusItemView *view;
@property (readonly) NSString *identifier;

- (instancetype)initWithProvider:(id<StatusItemProvider>)provider
                            view:(StatusItemView *)view;

@end

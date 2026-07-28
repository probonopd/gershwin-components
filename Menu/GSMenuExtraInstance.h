/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "GSMenuExtra.h"

@interface GSMenuExtraInstance : NSObject

@property (readonly) id<GSMenuExtra> extra;
@property (readonly) NSString *identifier;
@property (readonly) NSString *displayName;
@property (readonly) NSInteger priority;
@property (assign) CGFloat cachedWidth;

- (instancetype)initWithExtra:(id<GSMenuExtra>)extra
                   identifier:(NSString *)identifier
                  displayName:(NSString *)displayName
                     priority:(NSInteger)priority;

- (NSString *)title;
- (NSMenu *)menu;
- (NSImage *)icon;
- (CGFloat)width;
- (void)invalidateWidth;
- (void)unload;
- (void)menuWillOpen;
- (void)menuDidClose;
- (NSInteger)displayPriority;

@end

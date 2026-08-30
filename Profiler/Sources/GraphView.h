/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <AppKit/AppKit.h>

@interface GraphView : NSView
{
    NSMutableArray *_values;
    NSString *_title;
    NSString *_unit;
}

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *unit;
- (void)addValue:(double)value;
- (void)clear;

@end

/*
 * Copyright (c) 2026 Simon Peter / SPDX-License-Identifier: BSD-2-Clause
 */

#import "MBVariant.h"

@implementation MBVariant

@synthesize signature = _signature;
@synthesize value = _value;

- (instancetype)initWithSignature:(NSString *)signature value:(id)value
{
    self = [super init];
    if (self) {
        _signature = [signature copy];
        _value = [value retain];
    }
    return self;
}

+ (instancetype)variantWithSignature:(NSString *)signature value:(id)value
{
    return [[self alloc] initWithSignature:signature value:value];
}

- (void)dealloc
{
    [_signature release];
    [_value release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<MBVariant %@: %@>", _signature, _value];
}

@end

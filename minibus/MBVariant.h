/*
 * Copyright (c) 2026 Simon Peter / SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef MB_VARIANT_H
#define MB_VARIANT_H

#import <Foundation/Foundation.h>

/**
 * MBVariant - a D-Bus variant value: a signature plus the contained value.
 *
 * The daemon must round-trip messages byte-faithfully, so variants need to
 * remember their own signature (the contained value alone does not carry
 * enough type information, e.g. "i" vs "u" vs "b").
 */
@interface MBVariant : NSObject
{
    NSString *_signature;
    id _value;
}

@property (nonatomic, copy) NSString *signature;
@property (nonatomic, retain) id value;

- (instancetype)initWithSignature:(NSString *)signature value:(id)value;
+ (instancetype)variantWithSignature:(NSString *)signature value:(id)value;

@end

#endif // MB_VARIANT_H

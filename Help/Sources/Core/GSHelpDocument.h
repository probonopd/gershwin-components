/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#import "GSHelpNode.h"

NS_ASSUME_NONNULL_BEGIN

@class GSHelpHeading;

/* One entry of a document's derived table of contents (SPEC 16):
 * a heading plus its level (1...4), in document order. */
@interface GSHelpTOCEntry : NSObject

- (instancetype)initWithLevel:(NSUInteger)level
                      heading:(GSHelpHeading *)heading;

@property (nonatomic, readonly) NSUInteger level;
@property (nonatomic, readonly) GSHelpHeading *heading;

@end

/* The normalized document all parsers produce (SPEC 7). TOC and
 * anchors are derived lazily from rootNode and recomputed when the
 * root changes. */
@interface GSHelpDocument : NSObject

@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *identifier;
@property (nonatomic, strong, nullable) NSURL *sourceURL;
@property (nonatomic, copy, nullable) NSString *sourceType;
@property (nonatomic, copy) NSDictionary<NSString *, id> *metadata;

@property (nonatomic, strong, nullable) GSHelpSection *rootNode;

/* Derived lazily from rootNode; empty until a root is set. */
@property (nonatomic, readonly) NSArray<GSHelpTOCEntry *> *tableOfContents;

/* Anchor name -> node, derived lazily from rootNode. */
@property (nonatomic, readonly)
    NSDictionary<NSString *, __kindof GSHelpNode *> *anchors;

@end

NS_ASSUME_NONNULL_END

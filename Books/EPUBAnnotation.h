/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

// A single reader annotation (highlight, bookmark or note) modelled on the
// W3C Web Annotation Data Model as profiled by EPUB Annotations 1.0. The JSON
// emitted by -webAnnotationDictionary is a standards-compliant Annotation; the
// per-document offsets and the absolute reading-text offsets are the
// reader-internal anchors used to paint and jump.
typedef NS_ENUM(NSInteger, EPUBAnnotationMotivation) {
  EPUBAnnotationHighlighting = 0,
  EPUBAnnotationBookmarking = 1,
  EPUBAnnotationCommenting = 2,
};

@interface EPUBAnnotation : NSObject

@property (nonatomic, copy) NSString *uuid;
@property (nonatomic, assign) EPUBAnnotationMotivation motivation;
@property (nonatomic, copy) NSDate *created;
@property (nonatomic, copy) NSDate *modified;

// Standard EPUB Annotation selectors.
@property (nonatomic, copy) NSString *source;     // content document, relative to EPUB root
@property (nonatomic, assign) NSUInteger docStart; // char offset within that document's reading text
@property (nonatomic, assign) NSUInteger docEnd;
@property (nonatomic, copy) NSString *exact;      // TextQuoteSelector: the quoted text

// Reader-internal absolute range in the concatenated reading text (not serialized).
@property (nonatomic, assign) NSUInteger absStart;
@property (nonatomic, assign) NSUInteger absEnd;

// Optional note body (commenting).
@property (nonatomic, copy) NSString *note;
// Highlight colour label; one of yellow/green/blue/red/pink.
@property (nonatomic, copy) NSString *colorLabel;

+ (NSColor *)colorForLabel:(NSString *)label;
+ (NSString *)defaultColorLabel;

- (instancetype)init;
- (NSDictionary *)webAnnotationDictionary;
- (instancetype)initWithWebAnnotationDictionary:(NSDictionary *)dict;

@end

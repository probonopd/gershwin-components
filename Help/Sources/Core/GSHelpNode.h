/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Normalizes an ALL-UPPERCASE label (man section names like "NAME",
 * document names like "COPYING") to title case ("Name", "Copying").
 * Mixed-case strings are returned unchanged so real headings such as
 * "Getting Started" survive. */
NSString *GSHelpTitleCased(NSString *string);

/* Base class of the normalized document model (SPEC 8). Nodes form a
 * tree; every node knows its parent weakly and owns its children. */
@interface GSHelpNode : NSObject

/* Nil for a detached node or a document root. Weak to avoid retain
 * cycles in the parent<->child relation. */
@property (nonatomic, nullable, weak) GSHelpNode *parent;

/* Immutable view of the child nodes, in document order. */
@property (nonatomic, readonly) NSArray<__kindof GSHelpNode *> *children;

/* Appends node to children and sets its parent. */
- (void)appendNode:(GSHelpNode *)node;

@end

#pragma mark -

/* Top-level structural container; a document's rootNode is one. */
@interface GSHelpSection : GSHelpNode
@property (nonatomic, copy, nullable) NSString *title;
@end

/* Section heading; level is clamped to 1...4 (SPEC 16). */
@interface GSHelpHeading : GSHelpNode
@property (nonatomic, copy, nullable) NSString *text;
@property (nonatomic) NSUInteger level;
@end

/* Plain prose block; inline content lives in children (GSHelpText runs,
 * GSHelpLink, GSHelpImage). */
@interface GSHelpParagraph : GSHelpNode
@end

typedef NS_OPTIONS(NSUInteger, GSHelpTextStyle) {
    GSHelpTextStylePlain   = 0,
    GSHelpTextStyleBold    = 1 << 0,
    GSHelpTextStyleItalic  = 1 << 1,
    GSHelpTextStyleCode    = 1 << 2,
};

/* A run of styled text inside a paragraph or link label. */
@interface GSHelpText : GSHelpNode
@property (nonatomic, copy, nullable) NSString *string;
@property (nonatomic) GSHelpTextStyle style;
@end

/* Verbatim block of source code, optionally tagged with a language. */
@interface GSHelpCodeBlock : GSHelpNode
@property (nonatomic, copy, nullable) NSString *code;
@property (nonatomic, copy, nullable) NSString *language;
@end

/* List container; items are GSHelpListItem children and may nest by
 * holding further GSHelpList nodes among their own children. */
@interface GSHelpList : GSHelpNode
@property (nonatomic, getter=isOrdered) BOOL ordered;
@end

@interface GSHelpListItem : GSHelpNode
@end

/* Table structure: Table -> Row -> Cell. Cells carry plain text. */
@interface GSHelpTableCell : GSHelpNode
@property (nonatomic, copy, nullable) NSString *text;
@end

@interface GSHelpTableRow : GSHelpNode
/* Cell children of this row, in column order. */
@property (nonatomic, readonly) NSArray<GSHelpTableCell *> *cells;
- (void)appendCellWithText:(nullable NSString *)text;
@end

@interface GSHelpTable : GSHelpNode
/* Row children of this table, in document order. */
@property (nonatomic, readonly) NSArray<GSHelpTableRow *> *rows;
@end

/* Local documentation image resource (SPEC 49). */
@interface GSHelpImage : GSHelpNode
@property (nonatomic, copy, nullable) NSString *path;
@property (nonatomic, copy, nullable) NSString *altText;
@end

/* Documentation/resource link (SPEC 13). The target is a URL string:
 * relative document/anchor, local file or help:// reference. Label
 * text runs are held as GSHelpText children. */
@interface GSHelpLink : GSHelpNode
@property (nonatomic, copy, nullable) NSString *target;
@property (nonatomic, readonly) NSArray<GSHelpText *> *labelRuns;

/* Appends a GSHelpText run with the given style as label content. */
- (void)appendLabelRun:(NSString *)text
                 style:(GSHelpTextStyle)style;

/* Concatenation of all label run strings. */
- (nullable NSString *)labelText;
@end

/* Block quotation container. */
@interface GSHelpQuote : GSHelpNode
@end

/* Named location inside a document, resolvable via -anchors. */
@interface GSHelpAnchor : GSHelpNode
@property (nonatomic, copy, nullable) NSString *name;
@end

NS_ASSUME_NONNULL_END

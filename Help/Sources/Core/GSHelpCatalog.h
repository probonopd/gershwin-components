/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* One node of the documentation catalog shown in the sidebar. Leaf
 * nodes carry a file URL that opens the document; group nodes only
 * have children. */
@interface GSHelpCatalogItem : NSObject

- (instancetype)initWithTitle:(NSString *)title
                          url:(nullable NSURL *)url
                     children:(nullable NSArray<GSHelpCatalogItem *> *)children;

@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly, nullable) NSURL *url;
@property (nonatomic, readonly) NSArray<GSHelpCatalogItem *> *children;

@end

/* Builds the sidebar catalog (SPEC 52): application help bundles,
 * man pages grouped by section, and Markdown documentation under
 * given roots. All inputs are injected so callers can scan the real
 * system or tests can use fixtures. */
@interface GSHelpCatalog : NSObject

/* Roots contain *.app bundles (only those with Resources/Help are
 * listed), manN directories, and arbitrary trees to search for
 * .md/.markdown files respectively. */
+ (NSArray<GSHelpCatalogItem *> *)catalogItemsWithAppRoots:
                                     (NSArray<NSString *> *)appRoots
                                            manRoots:
                                                (NSArray<NSString *> *)manRoots
                                           fileRoots:
                                               (NSArray<NSString *> *)fileRoots;

/* Each root is a Library/Documentation/Developer directory. Every
 * *.gsdoc file below it becomes a leaf; subdirectories mirror the
 * on-disk tree as group rows. Roots arrive in domain precedence
 * order and a relative path seen twice keeps its first copy.
 * Returns zero or one group. */
+ (NSArray<GSHelpCatalogItem *> *)developerDocItemsWithRoots:
    (NSArray<NSString *> *)roots;

/* Convenience for the live system: /System application roots plus
 * MANPATH/standard man trees via GSHelpManLocator. */
+ (NSArray<GSHelpCatalogItem *> *)systemCatalogItems;

@end

NS_ASSUME_NONNULL_END

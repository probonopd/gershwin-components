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
 * listed), manN directories, markdown trees (fileRoots) and gsdoc
 * trees (developerRoots). The Documentation group leads the list,
 * then Applications, then Manual Pages. */
+ (NSArray<GSHelpCatalogItem *> *)catalogItemsWithAppRoots:
                                     (NSArray<NSString *> *)appRoots
                                            manRoots:
                                                (NSArray<NSString *> *)manRoots
                                           fileRoots:
                                               (NSArray<NSString *> *)fileRoots
                                       developerRoots:
                                           (NSArray<NSString *> *)developerRoots;

/* "3" -> "Section 3: Library Functions", "1p" ->
 * "Section 1p: User Commands (POSIX)"; unknown labels pass
 * through as before. */
+ (NSString *)displayNameForManSection:(NSString *)section;

/* Convenience for the live system: /System application roots plus
 * MANPATH/standard man trees via GSHelpManLocator. */
+ (NSArray<GSHelpCatalogItem *> *)systemCatalogItems;

@end

NS_ASSUME_NONNULL_END

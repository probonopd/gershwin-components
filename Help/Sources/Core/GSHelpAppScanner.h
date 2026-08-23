/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Result of scanning one application's Resources/Help bundle
 * (SPEC 14/15). */
@interface GSHelpAppScan : NSObject

- (instancetype)initWithDirectory:(NSString *)directory
                         entryURL:(nullable NSURL *)entryURL
                            items:(NSArray<NSDictionary *> *)items;

@property (nonatomic, readonly) NSString *helpDirectory;
@property (nonatomic, readonly, nullable) NSURL *entryURL;
/* Dictionaries with keys @"Title" and @"FileURL" (NSURL). */
@property (nonatomic, readonly) NSArray<NSDictionary *> *items;

@end

/* Discovers help bundles inside .app directories. The Help.plist
 * manifest is honored when present; otherwise index.md and the
 * remaining Markdown files drive navigation. */
@interface GSHelpAppScanner : NSObject

+ (nullable GSHelpAppScan *)scanApplicationHelpAtPath:
                                 (NSString *)appPath
                                               error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

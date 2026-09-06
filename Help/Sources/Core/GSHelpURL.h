/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Internal help:// URL namespace (SPEC 31):
 *
 *   help://app/<application>/<document>
 *   help://man/<command>/<section>
 *   help://gsdoc/<framework>/<symbol>
 *
 * These are application-internal identifiers, independent of any
 * physical filename. All accessors tolerate garbage input and return
 * nil instead of raising. */
@interface GSHelpURL : NSObject

/* The URL scheme owned by this namespace. */
+ (NSString *)helpScheme;

#pragma mark Building

+ (nullable NSURL *)appURLWithApplication:(nullable NSString *)application
                                 document:(nullable NSString *)document;

+ (nullable NSURL *)manURLWithCommand:(nullable NSString *)command
                              section:(nullable NSString *)section;

+ (nullable NSURL *)gsdocURLWithFramework:(nullable NSString *)framework
                                   symbol:(nullable NSString *)symbol;

#pragma mark Decomposing

/* YES if url is non-nil and uses the help:// scheme. */
+ (BOOL)isHelpURL:(nullable NSURL *)url;

/* Kind string of the URL: @"app", @"man" or @"gsdoc";
 * nil for non-help URLs or unknown kinds. */
+ (nullable NSString *)kindOfURL:(nullable NSURL *)url;

/* Generic path components (percent-decoded) below the kind;
 * nil for non-help URLs. */
+ (nullable NSArray<NSString *> *)componentsOfURL:(nullable NSURL *)url;

/* help://app/<application>/<document> */
+ (nullable NSString *)applicationOfURL:(nullable NSURL *)url;
+ (nullable NSString *)documentOfURL:(nullable NSURL *)url;

/* help://man/<command>/<section> */
+ (nullable NSString *)commandOfURL:(nullable NSURL *)url;
+ (nullable NSString *)sectionOfURL:(nullable NSURL *)url;

/* help://gsdoc/<framework>/<symbol> */
+ (nullable NSString *)frameworkOfURL:(nullable NSURL *)url;
+ (nullable NSString *)symbolOfURL:(nullable NSURL *)url;

@end

NS_ASSUME_NONNULL_END

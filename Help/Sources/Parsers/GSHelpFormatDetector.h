/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Format type identifiers returned by GSHelpFormatDetector (SPEC 10).
 * The values are the constant names themselves so they can round-trip
 * through plists and logs unambiguously. */
extern NSString * const GSHelpFormatMarkdown;
extern NSString * const GSHelpFormatMan;
extern NSString * const GSHelpFormatGSDoc;
extern NSString * const GSHelpFormatText;

/* Determines the documentation format of a file URL, following the
 * SPEC 10 detection priority:
 *
 *   1. explicit format hint
 *   2. help-bundle metadata (Help.plist "FileFormats" hook)
 *   3. file extension (.md/.markdown, .\d+\w*, .\d+.{gz,bz2,xz},
 *      .gsdoc, .txt)
 *   4. content sniffing (gzip/bzip2/xz magic, roff .TH/'-line,
 *      XML with gsdoc root, markdown ATX heading near the top)
 *   5. plain-text fallback
 */
@interface GSHelpFormatDetector : NSObject

/* Extension -> content -> text fallback for url. Never returns nil. */
+ (NSString *)detectFormatForURL:(nullable NSURL *)url;

/* As above, but an explicit hint wins when it names a known format.
 * Hints may be given as the format constants or by short name
 * ("markdown", "man", "gsdoc", "text", case-insensitive). Unknown
 * hints are ignored so detection proceeds down the chain. */
+ (NSString *)detectFormatForURL:(nullable NSURL *)url
                      formatHint:(nullable NSString *)hint;

/* Full SPEC 10 chain. Extension point for help bundles: plist is a
 * Help.plist-style dictionary; if it contains a "FileFormats"
 * dictionary mapping file names to known format constants, an entry
 * matching url's last path component takes precedence over the
 * extension and content checks. */
+ (NSString *)detectFormatForURL:(nullable NSURL *)url
                      formatHint:(nullable NSString *)hint
                  bundleMetadata:(nullable NSDictionary<NSString *, id> *)plist;

/* YES if format is one of the four declared constants. */
+ (BOOL)isKnownFormat:(nullable NSString *)format;

@end

NS_ASSUME_NONNULL_END

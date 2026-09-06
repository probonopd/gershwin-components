/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Back/forward navigation stack (SPEC 44). Entries are NSURLs - both
 * file URLs and internal help:// URLs live here verbatim. */
@interface GSHelpHistory : NSObject

- (void)pushURL:(nullable NSURL *)url;
- (nullable NSURL *)goBack;
- (nullable NSURL *)goForward;

@property (nonatomic, readonly) BOOL canBack;
@property (nonatomic, readonly) BOOL canForward;
@property (nonatomic, readonly, nullable) NSURL *currentURL;

@end

NS_ASSUME_NONNULL_END

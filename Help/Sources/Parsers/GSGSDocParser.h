/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#import "GSHelpParser.h"

NS_ASSUME_NONNULL_BEGIN

/* Parses GSdoc XML (the autogsdoc documentation format, DTD 0.6.x)
 * into the shared GSHelpDocument model. Prose structure maps to
 * headings, paragraphs, lists and code blocks; API declaration
 * blocks (class/category/protocol/method/function/...) are
 * reconstructed as readable signatures. No HTML is produced. */
@interface GSGSDocParser : NSObject <GSHelpParser>

@end

NS_ASSUME_NONNULL_END

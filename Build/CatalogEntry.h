/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface CatalogEntry : NSObject

@property (copy) NSString *name;
@property (copy) NSString *gitURL;
@property (copy) NSString *desc;
@property (copy) NSString *makefilePath;

+ (NSArray *)loadCatalog;

@end

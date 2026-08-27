/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import "EPUBAnnotation.h"
#import "LibraryBook.h"

// Per-book persistence of annotations as a standards-compliant EPUB Annotations
// 1.0 AnnotationSet document (a JSON-LD list of Web Annotation objects). Kept as
// a sidecar next to the library database so the data is portable and editable
// with any conforming tool.
@interface AnnotationStore : NSObject

- (instancetype)initWithBook:(LibraryBook *)book;
- (NSString *)path;
- (NSArray<EPUBAnnotation *> *)load;
- (BOOL)saveAnnotations:(NSArray<EPUBAnnotation *> *)annotations;

@end

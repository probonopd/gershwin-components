/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUIcons.h"

@implementation DUIcons

+ (NSImage *)iconNamed:(NSString *)name
{
    if (name.length == 0) {
        return nil;
    }
    NSBundle *bundle = [NSBundle mainBundle];

    // Installed layout: gnustep-make flattens Resources/Icons into the
    // resource root, so "verify.png" sits at <bundle>/Resources/verify.png.
    NSString *path = [bundle pathForResource:name ofType:@"png"];
    if (path.length == 0) {
        // Unflattened bundle layout: Icons sits below the resource root.
        path = [bundle pathForResource:name
                                ofType:@"png"
                           inDirectory:@"Icons"];
    }
    if (path.length == 0) {
        // Running uninstalled from the project directory: the relative
        // path resolves against the current working directory.
        path = [[NSString stringWithFormat:@"Resources/Icons/%@.png", name]
            stringByStandardizingPath];
    }
    if (path.length == 0) {
        return nil;
    }

    NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
    image.size = NSMakeSize(16.0, 16.0);
    return image;
}

@end

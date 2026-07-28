/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "GSMenuExtraBundle.h"

@implementation GSMenuExtraBundle

- (instancetype)initWithURL:(NSURL *)URL
{
    self = [super init];
    if (self) {
        _URL = URL;
        _bundle = [NSBundle bundleWithURL:URL];

        NSString *ext = [[URL pathExtension] lowercaseString];
        _isGSMenuExtra = [ext isEqualToString:@"gsmenuextra"];

        NSString *infoPath = [_bundle pathForResource:@"Info" ofType:@"plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];

        NSString *bundleId = [info objectForKey:@"CFBundleIdentifier"];
        if (bundleId) {
            _identifier = bundleId;
        } else {
            _identifier = [[URL lastPathComponent] stringByDeletingPathExtension];
        }

        NSString *name = [info objectForKey:@"CFBundleName"];
        if (name) {
            _displayName = name;
        } else {
            _displayName = [[URL lastPathComponent] stringByDeletingPathExtension];
        }

        NSNumber *prio = [info objectForKey:@"GSMenuExtraPriority"];
        _priority = prio ? [prio integerValue] : 100;
    }
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %@>", [self class], _identifier];
}

@end

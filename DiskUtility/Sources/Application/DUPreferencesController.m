/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUPreferencesController.h"

@implementation DUPreferencesController

+ (void)registerDefaults
{
    [[NSUserDefaults standardUserDefaults]
        registerDefaults:@{
            @"DUShowDetails" : @NO,
            // Destructive confirmations stay on unless explicitly turned
            // off; storage operations are not a place for silent defaults.
            @"DUConfirmDestructiveOperations" : @YES,
            @"DURefreshInterval" : @10,
        }];
}

+ (BOOL)showDetails
{
    return [[NSUserDefaults standardUserDefaults]
        boolForKey:@"DUShowDetails"];
}

+ (BOOL)confirmDestructiveOperations
{
    return [[NSUserDefaults standardUserDefaults]
        boolForKey:@"DUConfirmDestructiveOperations"];
}

+ (NSTimeInterval)refreshInterval
{
    double value = [[NSUserDefaults standardUserDefaults]
        doubleForKey:@"DURefreshInterval"];
    // Conservative floor keeps a misconfigured preference from hammering
    // the backend with discovery runs.
    if (value < 3.0) {
        value = 10.0;
    }
    return value;
}

@end

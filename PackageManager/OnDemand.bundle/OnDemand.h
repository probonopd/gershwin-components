/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * OnDemand — GNUstep bundle loaded into every GUI app via GSAppKitUserBundles.
 * When an app launches, checks whether it ships a Resources/Dependencies.plist
 * and offers to install missing packages via OnDemand.app.
 */

#import <Foundation/Foundation.h>

@interface OnDemand : NSObject
{
}

+ (void)load;

@end

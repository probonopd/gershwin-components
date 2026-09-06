/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface GNUStepMenuActionHandler : NSObject
+ (void)performMenuAction:(id)sender;

// Returns the cached connection WITHOUT performing a DO name lookup, or nil.
// Safe to call on the main thread even if the client is stalled.
+ (NSConnection *)existingConnectionForClient:(NSString *)clientName;

// Records a connection discovered by a background probe so later main-thread
// lookups are served from the cache and never block on the name server.
+ (void)cacheConnection:(NSConnection *)connection forClient:(NSString *)clientName;
@end

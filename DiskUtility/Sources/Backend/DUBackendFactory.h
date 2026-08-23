/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#import "DUStorageBackend.h"

// Picks the storage backend for the running OS. Never returns nil:
// - DUForceMockBackend user default YES -> mock backend, *error untouched.
// - Known platform (Linux/FreeBSD/OpenBSD/NetBSD) with the matching backend
//   class compiled in -> that backend, *error untouched.
// - Otherwise -> degraded mock whose capabilitiesReport is all NO and whose
//   discovery fails with a clear message (ARCHITECTURE.md 65/66), and
//   *error carries DUErrorBackendUnavailable so callers can surface why.
// The class lookup uses NSClassFromString so this file keeps compiling and
// linking before the wave 3 backends exist, and so --mock style overrides
// keep working when they land.
@interface DUBackendFactory : NSObject

+ (id<DUStorageBackend>)backendWithError:(NSError **)error;

@end

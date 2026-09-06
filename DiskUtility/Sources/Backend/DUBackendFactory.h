/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

#import "DUStorageBackend.h"

// Picks the storage backend for the running OS. Never returns nil:
// - "--mock" in the process arguments -> mock backend, *error untouched.
//   The flag is deliberately read from the argument vector only: a
//   persistent user default once made every later launch silently run
//   the mock backend.
// - Known platform (Linux/FreeBSD/OpenBSD/NetBSD) with the matching backend
//   class compiled in -> that backend, *error untouched.
// - Otherwise -> degraded mock whose capabilitiesReport is all NO and whose
//   discovery fails with a clear message (ARCHITECTURE.md 65/66), and
//   *error carries DUErrorBackendUnavailable so callers can surface why.
// The class lookup uses NSClassFromString so this file keeps compiling and
// linking before the wave 3 backends exist.
@interface DUBackendFactory : NSObject

+ (id<DUStorageBackend>)backendWithError:(NSError **)error;

// Same selection against an explicit argument vector (testable variant of
// backendWithError:).
+ (id<DUStorageBackend>)backendForArguments:(NSArray *)arguments
                                     error:(NSError **)error;

@end

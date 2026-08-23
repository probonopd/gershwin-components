/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

// Central notification-name pins (PLAN.md, ARCHITECTURE.md section 52).
// Every cross-object event in the storage domain is announced through one of
// these so controllers never poll and never reach into global state.
extern NSString *const DUStorageTopologyDidChangeNotification;
extern NSString *const DUStorageSelectionDidChangeNotification;
extern NSString *const DUOperationDidStartNotification;
extern NSString *const DUOperationDidUpdateNotification;
extern NSString *const DUOperationDidFinishNotification;
extern NSString *const DUOperationDidFailNotification;

// UserInfo keys. kDUUserInfoObjectKey carries the DUStorageObject the event
// is about (when there is one), kDUUserInfoOperationKey the DUOperation,
// kDUUserInfoErrorKey the NSError on failure.
extern NSString *const kDUUserInfoObjectKey;
extern NSString *const kDUUserInfoOperationKey;
extern NSString *const kDUUserInfoErrorKey;

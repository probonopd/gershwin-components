/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUNotifications.h"

NSString *const DUStorageTopologyDidChangeNotification =
    @"DUStorageTopologyDidChangeNotification";
NSString *const DUStorageSelectionDidChangeNotification =
    @"DUStorageSelectionDidChangeNotification";
NSString *const DUOperationDidStartNotification =
    @"DUOperationDidStartNotification";
NSString *const DUOperationDidUpdateNotification =
    @"DUOperationDidUpdateNotification";
NSString *const DUOperationDidFinishNotification =
    @"DUOperationDidFinishNotification";
NSString *const DUOperationDidFailNotification =
    @"DUOperationDidFailNotification";

NSString *const kDUUserInfoObjectKey = @"kDUUserInfoObject";
NSString *const kDUUserInfoOperationKey = @"kDUUserInfoOperation";
NSString *const kDUUserInfoErrorKey = @"kDUUserInfoError";

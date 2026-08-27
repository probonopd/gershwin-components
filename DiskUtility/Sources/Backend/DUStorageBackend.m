/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUStorageBackend.h"

NSString *const kDUOperationVerify = @"verify";
NSString *const kDUOperationRepair = @"repair";
NSString *const kDUOperationErase = @"erase";
NSString *const kDUOperationPartition = @"partition";
NSString *const kDUOperationMount = @"mount";
NSString *const kDUOperationUnmount = @"unmount";
NSString *const kDUOperationEject = @"eject";
NSString *const kDUOperationRestore = @"restore";
NSString *const kDUOperationBurn = @"burn";
NSString *const kDUOperationCreateImage = @"createImage";
NSString *const kDUOperationConvertImage = @"convertImage";
NSString *const kDUOperationResizeImage = @"resizeImage";
NSString *const kDUOperationToggleJournaling = @"toggleJournaling";

NSString *const kDUFormatIdentifierKey = @"DUFormatIdentifier";
NSString *const kDUFormatDisplayNameKey = @"DUFormatDisplayName";
NSString *const kDUFormatCanFormatKey = @"DUFormatCanFormat";

NSString *const kDUEraseSecurityMethodKey = @"DUEraseSecurityMethod";
NSString *const kDUEraseMethodStandardKey = @"standard";
NSString *const kDUEraseMethodZerosKey = @"zeros";

NSString *const kDUDiscBlankMethodKey = @"DUDiscBlankMethod";
NSString *const kDUDiscBlankFastKey = @"fast";
NSString *const kDUDiscBlankAllKey = @"all";

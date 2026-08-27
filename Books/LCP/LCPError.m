/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "LCPError.h"

NSString *const LCPErrorDomain = @"io.github.gershwin.Books.LCP";

NSString *const LCPProfileBasic = @"http://readium.org/lcp/basic-profile";
NSString *const LCPProfile1_0   = @"http://readium.org/lcp/profile-1.0";
NSString *const LCPProfile2_0   = @"http://readium.org/lcp/profile-2.0";
NSString *const LCPProfile2_1   = @"http://readium.org/lcp/profile-2.1";

NSString *const LCPAlgorithmAES256CBC  = @"http://www.w3.org/2001/04/xmlenc#aes256-cbc";
NSString *const LCPAlgorithmSHA256     = @"http://www.w3.org/2001/04/xmlenc#sha256";
NSString *const LCPAlgorithmRSASHA256  = @"http://www.w3.org/2001/04/xmldsig-more#rsa-sha256";

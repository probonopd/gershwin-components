/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

/* LCP error domain and codes (see Books/LCP.md section 17). */
extern NSString *const LCPErrorDomain;

typedef NS_ENUM(NSInteger, LCPErrorCode)
{
  LCPErrorNone                 = 0,
  LCPErrorInvalidLicense       = 1,
  LCPErrorInvalidSignature     = 2,
  LCPErrorInvalidCertificate   = 3,
  LCPErrorRevokedCertificate   = 4,
  LCPErrorInvalidPassphrase    = 5,
  LCPErrorLicenseExpired       = 6,
  LCPErrorPublicationUnavailable = 7,
  LCPErrorStatusUnavailable    = 8,
  LCPErrorNetwork              = 9,
  LCPErrorUnsupportedProfile   = 10,
  LCPErrorDecryptionFailed     = 11
};

/* The LCP profile URIs we understand. Basic/Test, profile-1.0, profile-2.0 and
 * profile-2.1 all share the SHA-256 user key + AES-256-CBC content key +
 * RSA-SHA256 signature crypto; the newer profiles only add optional rights and
 * key-delivery features we don't rely on for decryption. */
extern NSString *const LCPProfileBasic;
extern NSString *const LCPProfile1_0;
extern NSString *const LCPProfile2_0;
extern NSString *const LCPProfile2_1;

/* Algorithm URIs from XML-ENC / XML-SIG. */
extern NSString *const LCPAlgorithmAES256CBC;
extern NSString *const LCPAlgorithmSHA256;
extern NSString *const LCPAlgorithmRSASHA256;

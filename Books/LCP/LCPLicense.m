/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "LCPLicense.h"

@implementation LCPLicense

+ (instancetype) licenseWithJSON:(NSData *)json error:(NSError **)error
{
  if (json == nil)
    {
      if (error)
        *error = [NSError errorWithDomain: LCPErrorDomain
                                     code: LCPErrorInvalidLicense
                                 userInfo: @{ NSLocalizedDescriptionKey: @"nil license data" }];
      return nil;
    }

  NSError *parseError = nil;
  id obj = [NSJSONSerialization JSONObjectWithData: json
                                           options: 0
                                             error: &parseError];
  if (obj == nil || ![obj isKindOfClass: [NSDictionary class]])
    {
      if (error)
        *error = [NSError errorWithDomain: LCPErrorDomain
                                     code: LCPErrorInvalidLicense
                                 userInfo: @{ NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat: @"license is not a JSON object: %@",
                                     [parseError localizedDescription]] }];
      return nil;
    }

  LCPLicense *lic = [[self alloc] init];
  NSDictionary *dict = (NSDictionary *)obj;

  lic->_licenseID = [dict[@"id"] copy];
  lic->_issued    = [dict[@"issued"] copy];
  lic->_updated   = [dict[@"updated"] copy];
  lic->_provider  = [dict[@"provider"] copy];

  NSDictionary *enc = dict[@"encryption"];
  lic->_profile = [enc[@"profile"] copy];
  NSDictionary *ck = enc[@"content_key"];
  lic->_contentKeyAlgorithm = [ck[@"algorithm"] copy];
  lic->_contentKeyEncryptedValue = [[NSData alloc]
    initWithBase64EncodedString: ck[@"encrypted_value"] options: 0];
  NSDictionary *uk = enc[@"user_key"];
  lic->_userKeyAlgorithm = [uk[@"algorithm"] copy];
  lic->_userKeyTextHint  = [uk[@"text_hint"] copy];
  lic->_userKeyKeyCheck  = [[NSData alloc]
    initWithBase64EncodedString: uk[@"key_check"] options: 0];

  lic->_links   = [dict[@"links"] copy];
  lic->_rights  = [dict[@"rights"] copy];
  lic->_user    = [dict[@"user"] copy];
  lic->_signature = [dict[@"signature"] copy];

  if ([lic validate: error] == NO)
    {
      return nil;
    }
  return lic;
}

- (BOOL) validate:(NSError **)error
{
  NSMutableArray *missing = [NSMutableArray array];

  /* Core license information (spec 3.3). */
  if (self.licenseID.length == 0)    [missing addObject: @"id"];
  if (self.issued.length == 0)       [missing addObject: @"issued"];
  if (self.provider.length == 0)     [missing addObject: @"provider"];

  /* Encryption object (spec 3.4). */
  if (self.profile.length == 0)      [missing addObject: @"encryption.profile"];
  if (self.contentKeyEncryptedValue == nil) [missing addObject: @"encryption.content_key.encrypted_value"];
  if (self.contentKeyAlgorithm.length == 0) [missing addObject: @"encryption.content_key.algorithm"];
  if (self.userKeyAlgorithm.length == 0)    [missing addObject: @"encryption.user_key.algorithm"];
  if (self.userKeyKeyCheck == nil)          [missing addObject: @"encryption.user_key.key_check"];

  if (missing.count > 0)
    {
      if (error)
        *error = [NSError errorWithDomain: LCPErrorDomain
                                     code: LCPErrorInvalidLicense
                                 userInfo: @{ NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat: @"missing required license fields: %@",
                                     [missing componentsJoinedByString: @", "]] }];
      return NO;
    }

  /* Only the SHA-256 user key + AES-256-CBC content key + RSA-SHA256
   * signature profiles are implemented (spec 6.3). */
  BOOL supportedProfile = [self.profile isEqualToString: LCPProfileBasic]
                        || [self.profile isEqualToString: LCPProfile1_0]
                        || [self.profile isEqualToString: LCPProfile2_0]
                        || [self.profile isEqualToString: LCPProfile2_1];
  if (supportedProfile == NO)
    {
      if (error)
        *error = [NSError errorWithDomain: LCPErrorDomain
                                     code: LCPErrorUnsupportedProfile
                                 userInfo: @{ NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat: @"unsupported LCP profile: %@", self.profile] }];
      return NO;
    }

  if ([self.contentKeyAlgorithm isEqualToString: LCPAlgorithmAES256CBC] == NO)
    {
      if (error)
        *error = [NSError errorWithDomain: LCPErrorDomain
                                     code: LCPErrorUnsupportedProfile
                                 userInfo: @{ NSLocalizedDescriptionKey:
                                   @"unsupported content key algorithm" }];
      return NO;
    }
  if ([self.userKeyAlgorithm isEqualToString: LCPAlgorithmSHA256] == NO)
    {
      if (error)
        *error = [NSError errorWithDomain: LCPErrorDomain
                                     code: LCPErrorUnsupportedProfile
                                 userInfo: @{ NSLocalizedDescriptionKey:
                                   @"unsupported user key algorithm" }];
      return NO;
    }
  return YES;
}

- (NSString *) publicationLink
{
  for (NSDictionary *link in self.links)
    {
      NSArray *rels = link[@"rel"];
      if ([rels isKindOfClass: [NSString class]])
        rels = @[ rels ];
      if ([rels containsObject: @"publication"])
        return link[@"href"];
    }
  return nil;
}

@end

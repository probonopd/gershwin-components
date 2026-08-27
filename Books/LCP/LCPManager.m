/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "LCPManager.h"
#import "LCPError.h"

@implementation LCPManager
{
  id<LCPClientBackend> _backend;
  LCPLicense *_license;
  NSData *_contentKey;
  id<PublicationResourceProvider> _provider;
  NSSet<NSString *> *_encryptedPaths;
}

- (instancetype) initWithBackend:(id<LCPClientBackend>)backend
{
  self = [super init];
  if (self)
    _backend = backend;
  return self;
}

- (LCPLicense *) importLicense:(NSData *)json error:(NSError **)error
{
  _license = [LCPLicense licenseWithJSON: json error: error];
  _contentKey = nil; /* re-lock on each new license */
  return _license;
}

- (NSString *) passphraseHint
{
  return _license.userKeyTextHint;
}

- (BOOL) unlockWithPassphrase:(NSString *)passphrase error:(NSError **)error
{
  if (_license == nil)
    {
      if (error) *error = [NSError errorWithDomain: LCPErrorDomain
                                              code: LCPErrorInvalidLicense
                                          userInfo: @{ NSLocalizedDescriptionKey: @"no license imported" }];
      return NO;
    }
  if ([_backend verifyPassphrase: passphrase forLicense: _license] == NO)
    {
      if (error) *error = [NSError errorWithDomain: LCPErrorDomain
                                              code: LCPErrorInvalidPassphrase
                                          userInfo: @{ NSLocalizedDescriptionKey: @"The passphrase is incorrect." }];
      return NO;
    }
  NSData *ck = [_backend decryptContentKeyFromLicense: _license
                                              userKey: [_backend userKeyFromPassphrase: passphrase]
                                                error: error];
  if (ck == nil)
    return NO;
  _contentKey = ck;
  return YES;
}

- (BOOL) isLocked
{
  return _contentKey == nil;
}

- (void) setResourceProvider:(id<PublicationResourceProvider>)provider
              encryptedPaths:(NSSet<NSString *> *)encryptedPaths
{
  _provider = provider;
  _encryptedPaths = [encryptedPaths copy];
  if ([provider isKindOfClass: [NSObject class]]
      && [_provider respondsToSelector: @selector(setEncryptedPaths:)])
    {
      [(id)_provider setEncryptedPaths: _encryptedPaths];
    }
}

- (NSData *) resourceForPath:(NSString *)relativePath error:(NSError **)error
{
  if (_provider == nil)
    {
      if (error) *error = [NSError errorWithDomain: LCPErrorDomain
                                              code: LCPErrorPublicationUnavailable
                                          userInfo: @{ NSLocalizedDescriptionKey: @"no resource provider" }];
      return nil;
    }
  if (self.isLocked)
    {
      if (error) *error = [NSError errorWithDomain: LCPErrorDomain
                                              code: LCPErrorInvalidLicense
                                          userInfo: @{ NSLocalizedDescriptionKey: @"publication is locked" }];
      return nil;
    }
  return [_provider dataForResource: relativePath error: error];
}

- (NSData *) contentKey
{
  return _contentKey;
}

- (NSData *) decryptResource:(NSData *)ciphertext error:(NSError **)error
{
  if (self.isLocked)
    {
      if (error) *error = [NSError errorWithDomain: LCPErrorDomain
                                              code: LCPErrorInvalidLicense
                                          userInfo: @{ NSLocalizedDescriptionKey: @"publication is locked" }];
      return nil;
    }
  return [_backend decryptResource: ciphertext contentKey: _contentKey error: error];
}

@end

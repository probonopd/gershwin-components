/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "LCPResourceProvider.h"
#import "LCPLicense.h"
#import "LCPClientBackend.h"
#import "LCPError.h"

@implementation NormalEPUBResourceProvider
{
  NSString *_basePath;
}

- (instancetype) initWithBasePath:(NSString *)basePath
{
  self = [super init];
  if (self)
    _basePath = [basePath copy];
  return self;
}

- (BOOL) isEncrypted:(NSString *)relativePath { return NO; }

- (NSData *) dataForResource:(NSString *)relativePath error:(NSError **)error
{
  NSString *full = [_basePath stringByAppendingPathComponent: relativePath];
  NSData *data = [NSData dataWithContentsOfFile: full options: 0 error: error];
  return data;
}

@end


@implementation LCPEPUBResourceProvider
{
  id<PublicationResourceProvider> _base;
  LCPLicense *_license;
  NSData *_contentKey;
  id<LCPClientBackend> _backend;
  NSSet<NSString *> *_encryptedPaths;
}

- (instancetype) initWithBaseProvider:(id<PublicationResourceProvider>)base
                              license:(LCPLicense *)license
                          contentKey:(NSData *)contentKey
                              backend:(id)backend
{
  self = [super init];
  if (self)
    {
      _base = base;
      _license = license;
      _contentKey = contentKey;
      _backend = backend;
    }
  return self;
}

- (void) setEncryptedPaths:(NSSet<NSString *> *)encryptedPaths
{
  _encryptedPaths = [encryptedPaths copy];
}

- (BOOL) isEncrypted:(NSString *)relativePath
{
  return [_encryptedPaths containsObject: relativePath];
}

- (NSData *) dataForResource:(NSString *)relativePath error:(NSError **)error
{
  if ([self isEncrypted: relativePath] == NO)
    return [_base dataForResource: relativePath error: error];

  NSData *ciphertext = [_base dataForResource: relativePath error: error];
  if (ciphertext == nil)
    return nil;
  return [_backend decryptResource: ciphertext contentKey: _contentKey error: error];
}

@end

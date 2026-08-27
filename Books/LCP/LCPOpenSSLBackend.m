/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

#import "LCPClientBackend.h"
#import "LCPError.h"
#import <openssl/evp.h>
#import <openssl/sha.h>
#import <openssl/rand.h>

/* W3C padding (LCP Basic Profile 1.0, section 6.3 / readium-lcp-server
 * issue #18): pad plaintext to a multiple of 16 by suffixing N-1 arbitrary
 * bytes and a final byte whose value is N (1..16). On decrypt, strip N bytes. */

static NSData *LCPAddWC3Padding(NSData *plaintext)
{
  NSUInteger len = [plaintext length];
  NSUInteger pad = 16 - (len % 16);
  if (pad == 0) pad = 16;
  NSMutableData *padded = [NSMutableData dataWithCapacity: len + pad];
  [padded appendData: plaintext];
  /* Last byte is N; the N-1 preceding pad bytes are arbitrary (zeros). */
  for (NSUInteger i = 0; i < pad - 1; i++)
    {
      uint8_t b = 0;
      [padded appendBytes: &b length: 1];
    }
  uint8_t n = (uint8_t)pad;
  [padded appendBytes: &n length: 1];
  return padded;
}

static NSData *LCPStripWC3Padding(NSData *decrypted, NSError **error)
{
  NSUInteger len = [decrypted length];
  if (len == 0)
    {
      if (error) *error = [NSError errorWithDomain: LCPErrorDomain code: LCPErrorDecryptionFailed
                          userInfo: @{ NSLocalizedDescriptionKey: @"empty decryption" }];
      return nil;
    }
  uint8_t n = ((const uint8_t *)[decrypted bytes])[len - 1];
  if (n < 1 || n > 16 || n > len)
    {
      if (error) *error = [NSError errorWithDomain: LCPErrorDomain code: LCPErrorDecryptionFailed
                          userInfo: @{ NSLocalizedDescriptionKey: @"invalid LCP padding" }];
      return nil;
    }
  return [decrypted subdataWithRange: NSMakeRange(0, len - n)];
}

/* AES-256-CBC, no OpenSSL padding (we manage W3C padding), with a random IV
 * prepended to the output. Returns IV(16) || ciphertext. */
static NSData *LCPAES256CBCDecrypt(NSData *input, NSData *key, NSError **error)
{
  if ([key length] != 32)
    {
      if (error) *error = [NSError errorWithDomain: LCPErrorDomain code: LCPErrorDecryptionFailed
                          userInfo: @{ NSLocalizedDescriptionKey: @"content key must be 32 bytes" }];
      return nil;
    }
  if ([input length] < 16)
    {
      if (error) *error = [NSError errorWithDomain: LCPErrorDomain code: LCPErrorDecryptionFailed
                          userInfo: @{ NSLocalizedDescriptionKey: @"ciphertext shorter than IV" }];
      return nil;
    }

  const uint8_t *iv  = (const uint8_t *)[input bytes];
  const uint8_t *ct  = iv + 16;
  size_t ctLen       = [input length] - 16;

  NSMutableData *out = [NSMutableData dataWithLength: ctLen];

  EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
  if (ctx == NULL)
    {
      if (error) *error = [NSError errorWithDomain: LCPErrorDomain code: LCPErrorDecryptionFailed
                          userInfo: @{ NSLocalizedDescriptionKey: @"cannot create cipher context" }];
      return nil;
    }
  int ok = EVP_DecryptInit_ex(ctx, EVP_aes_256_cbc(), NULL, [key bytes], iv);
  if (ok == 1)
    EVP_CIPHER_CTX_set_padding(ctx, 0);
  int outLen = 0, finalLen = 0;
  if (ok == 1)
    ok = EVP_DecryptUpdate(ctx, [out mutableBytes], &outLen, ct, (int)ctLen);
  if (ok == 1)
    ok = EVP_DecryptFinal_ex(ctx, [out mutableBytes] + outLen, &finalLen);
  EVP_CIPHER_CTX_free(ctx);

  if (ok != 1)
    {
      if (error) *error = [NSError errorWithDomain: LCPErrorDomain code: LCPErrorDecryptionFailed
                          userInfo: @{ NSLocalizedDescriptionKey: @"AES decryption failed" }];
      return nil;
    }

  return LCPStripWC3Padding(out, error);
}

/* Encrypt helper (used to build fixtures / key_check). IV || ciphertext. */
static NSData *LCPAES256CBCEncrypt(NSData *plaintext, NSData *key)
{
  NSData *padded = LCPAddWC3Padding(plaintext);
  uint8_t iv[16];
  RAND_bytes(iv, 16);

  NSMutableData *out = [NSMutableData dataWithLength: [padded length]];

  EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
  EVP_EncryptInit_ex(ctx, EVP_aes_256_cbc(), NULL, [key bytes], iv);
  EVP_CIPHER_CTX_set_padding(ctx, 0);
  int outLen = 0, finalLen = 0;
  EVP_EncryptUpdate(ctx, [out mutableBytes], &outLen,
                    [padded bytes], (int)[padded length]);
  EVP_EncryptFinal_ex(ctx, [out mutableBytes] + outLen, &finalLen);
  EVP_CIPHER_CTX_free(ctx);

  NSMutableData *result = [NSMutableData dataWithCapacity: 16 + [out length]];
  [result appendBytes: iv length: 16];
  [result appendData: out];
  return result;
}

@interface LCPOpenSSLBackend : NSObject <LCPClientBackend>
@end

@implementation LCPOpenSSLBackend

- (NSData *) userKeyFromPassphrase:(NSString *)passphrase
{
  NSData *passData = [passphrase dataUsingEncoding: NSUTF8StringEncoding];
  uint8_t digest[SHA256_DIGEST_LENGTH];
  SHA256([passData bytes], [passData length], digest);
  return [NSData dataWithBytes: digest length: SHA256_DIGEST_LENGTH];
}

- (BOOL) verifyPassphrase:(NSString *)passphrase
               forLicense:(LCPLicense *)license
{
  NSData *userKey = [self userKeyFromPassphrase: passphrase];
  NSError *err = nil;
  NSData *decrypted = LCPAES256CBCDecrypt(license.userKeyKeyCheck, userKey, &err);
  if (decrypted == nil)
    return NO;
  NSString *check = [[NSString alloc] initWithData: decrypted
                                          encoding: NSUTF8StringEncoding];
  return [check isEqualToString: license.licenseID];
}

- (NSData *) decryptContentKeyFromLicense:(LCPLicense *)license
                                  userKey:(NSData *)userKey
                                    error:(NSError **)error
{
  return LCPAES256CBCDecrypt(license.contentKeyEncryptedValue, userKey, error);
}

- (NSData *) decryptResource:(NSData *)ciphertext
                  contentKey:(NSData *)contentKey
                       error:(NSError **)error
{
  return LCPAES256CBCDecrypt(ciphertext, contentKey, error);
}

/* Build a key_check value (used by tests that mint a synthetic license). */
+ (NSData *) keyCheckForLicenseID:(NSString *)licenseID userKey:(NSData *)userKey
{
  NSData *idData = [licenseID dataUsingEncoding: NSUTF8StringEncoding];
  return LCPAES256CBCEncrypt(idData, userKey);
}

/* Build an encrypted content key (used by tests that mint a synthetic
 * license). */
+ (NSData *) encryptedContentKey:(NSData *)contentKey userKey:(NSData *)userKey
{
  return LCPAES256CBCEncrypt(contentKey, userKey);
}

/* Build an encrypted resource (used by tests / provider fixtures). */
+ (NSData *) encryptedResource:(NSData *)plaintext contentKey:(NSData *)contentKey
{
  return LCPAES256CBCEncrypt(plaintext, contentKey);
}

@end

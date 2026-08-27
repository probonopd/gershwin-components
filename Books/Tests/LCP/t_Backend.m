/* t_Backend.m - LCPOpenSSLBackend crypto (spec 4.2, 3.4, 2.2, 6.3).
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "LCPLicense.h"
#import "LCPClientBackend.h"
#import "LCPOpenSSLBackend.h"
#import "LCPError.h"

static NSString *Hex(NSData *d)
{
  NSMutableString *s = [NSMutableString string];
  const uint8_t *b = [d bytes];
  for (NSUInteger i = 0; i < [d length]; i++)
    [s appendFormat: @"%02x", b[i]];
  return s;
}

/* Mint a complete .lcpl JSON for a given passphrase + content key. */
static NSData *MintLicense(NSString *licID, NSString *passphrase, NSData *contentKey)
{
  LCPOpenSSLBackend *be = [LCPOpenSSLBackend new];
  NSData *uk = [be userKeyFromPassphrase: passphrase];
  NSData *ckEnc = [LCPOpenSSLBackend encryptedContentKey: contentKey userKey: uk];
  NSData *kc    = [LCPOpenSSLBackend keyCheckForLicenseID: licID userKey: uk];
  NSDictionary *d = @{
    @"id": licID,
    @"issued": @"2020-01-01T00:00:00Z",
    @"provider": @"https://example.com",
    @"encryption": @{
      @"profile": LCPProfileBasic,
      @"content_key": @{
        @"algorithm": LCPAlgorithmAES256CBC,
        @"encrypted_value": [ckEnc base64EncodedStringWithOptions: 0]
      },
      @"user_key": @{
        @"algorithm": LCPAlgorithmSHA256,
        @"key_check": [kc base64EncodedStringWithOptions: 0],
        @"text_hint": @"password"
      }
    }
  };
  return [NSJSONSerialization dataWithJSONObject: d options: 0 error: NULL];
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  LCPOpenSSLBackend *be = [LCPOpenSSLBackend new];

  /* User Key = SHA-256(passphrase). Known vector: SHA-256("test"). */
  {
    NSData *uk = [be userKeyFromPassphrase: @"test"];
    PASS([uk length] == 32, "user key is 32 bytes (AES-256)");
    PASS([[Hex(uk) lowercaseString]
            isEqualToString: @"9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"],
          "user key matches SHA-256(\"test\")");
  }

  /* Passphrase check: correct passphrase validates, wrong one does not. */
  {
    NSData *ck = [@"0123456789abcdef0123456789abcdef" dataUsingEncoding: NSUTF8StringEncoding];
    LCPLicense *lic = [LCPLicense licenseWithJSON: MintLicense(@"id-1", @"secret", ck) error: NULL];
    PASS(lic != nil, "minted license parses");
    PASS([be verifyPassphrase: @"secret" forLicense: lic] == YES, "correct passphrase verifies");
    PASS([be verifyPassphrase: @"wrong" forLicense: lic] == NO, "wrong passphrase rejected");
  }

  /* Content key round-trips through encryption + decryption. */
  {
    NSData *ck = [@"0123456789abcdef0123456789abcdef" dataUsingEncoding: NSUTF8StringEncoding];
    LCPLicense *lic = [LCPLicense licenseWithJSON: MintLicense(@"id-2", @"secret", ck) error: NULL];
    NSData *uk = [be userKeyFromPassphrase: @"secret"];
    NSError *err = nil;
    NSData *got = [be decryptContentKeyFromLicense: lic userKey: uk error: &err];
    PASS(got != nil && err == nil, "content key decrypts without error");
    PASS_EQUAL(got, ck, "decrypted content key matches original");
  }

  /* Resource decryption round-trips (IV prepended, W3C padding). */
  {
    NSData *ck = [@"0123456789abcdef0123456789abcdef" dataUsingEncoding: NSUTF8StringEncoding];
    NSString *plain = @"<html><body>Hello, LCP!</body></html>";
    NSData *pt = [plain dataUsingEncoding: NSUTF8StringEncoding];
    NSData *ct = [LCPOpenSSLBackend encryptedResource: pt contentKey: ck];
    NSError *err = nil;
    NSData *got = [be decryptResource: ct contentKey: ck error: &err];
    PASS(got != nil && err == nil, "resource decrypts without error");
    PASS_EQUAL([NSString stringWithUTF8String: [got bytes]], plain, "decrypted resource matches plaintext");
  }

  [arp release];
  return 0;
}

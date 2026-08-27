/* t_Manager.m - LCPManager facade flow (spec 2): import, lock, unlock,
 * transparent resource decryption.
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "LCPManager.h"
#import "LCPLicense.h"
#import "LCPClientBackend.h"
#import "LCPOpenSSLBackend.h"
#import "LCPResourceProvider.h"
#import "LCPError.h"

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
        @"text_hint": @"your password"
      }
    }
  };
  return [NSJSONSerialization dataWithJSONObject: d options: 0 error: NULL];
}

static NSString *TmpDir(void)
{
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
    [NSString stringWithFormat: @"lcp_mgr_%d", (int)getpid()]];
  [[NSFileManager defaultManager] removeFileAtPath: dir handler: nil];
  [[NSFileManager defaultManager] createDirectoryAtPath: dir
                            withIntermediateDirectories: YES attributes: nil error: NULL];
  [[NSFileManager defaultManager] createDirectoryAtPath: [dir stringByAppendingPathComponent: @"EPUB"]
                            withIntermediateDirectories: YES attributes: nil error: NULL];
  return dir;
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];
  LCPOpenSSLBackend *be = [LCPOpenSSLBackend new];
  NSData *ck = [@"0123456789abcdef0123456789abcdef" dataUsingEncoding: NSUTF8StringEncoding];
  NSString *dir = TmpDir();
  NSString *encPath = @"EPUB/chap.xhtml";

  NSData *ct = [LCPOpenSSLBackend encryptedResource:
    [@"<html>chapter</html>" dataUsingEncoding: NSUTF8StringEncoding] contentKey: ck];
  [ct writeToFile: [dir stringByAppendingPathComponent: encPath] atomically: NO];

  LCPManager *mgr = [[LCPManager alloc] initWithBackend: be];

  /* Import parses the license and exposes the hint. */
  NSError *err = nil;
  LCPLicense *lic = [mgr importLicense: MintLicense(@"lic-1", @"secret", ck) error: &err];
  PASS(lic != nil && err == nil, "manager imports license");
  PASS_EQUAL([mgr passphraseHint], @"your password", "manager exposes passphrase hint");

  /* Wire the provider (realistic: set up at open time). */
  NormalEPUBResourceProvider *np =
    [[NormalEPUBResourceProvider alloc] initWithBasePath: dir];
  LCPEPUBResourceProvider *lp =
    [[LCPEPUBResourceProvider alloc] initWithBaseProvider: np
                                                 license: lic
                                             contentKey: ck
                                                 backend: be];
  [mgr setResourceProvider: lp encryptedPaths: [NSSet setWithObject: encPath]];

  /* Locked until a correct passphrase is supplied. */
  PASS([mgr isLocked] == YES, "manager starts locked");
  NSError *lockErr = nil;
  NSData *locked = [mgr resourceForPath: encPath error: &lockErr];
  PASS(locked == nil && lockErr != nil && lockErr.code == LCPErrorInvalidLicense,
       "reading while locked fails");

  /* Wrong passphrase is rejected. */
  NSError *badErr = nil;
  PASS([mgr unlockWithPassphrase: @"nope" error: &badErr] == NO, "wrong passphrase rejected");
  PASS(badErr != nil && badErr.code == LCPErrorInvalidPassphrase, "wrong passphrase error");

  /* Unlock with the correct passphrase. */
  NSError *okErr = nil;
  PASS([mgr unlockWithPassphrase: @"secret" error: &okErr] == YES, "correct passphrase unlocks");
  PASS([mgr isLocked] == NO, "manager unlocked after correct passphrase");

  NSData *got = [mgr resourceForPath: encPath error: &okErr];
  PASS(got != nil && okErr == nil, "resource decrypted without error");
  PASS_EQUAL([NSString stringWithUTF8String: [got bytes]], @"<html>chapter</html>",
             "manager returns decrypted plaintext");

  [[NSFileManager defaultManager] removeFileAtPath: dir handler: nil];
  [arp release];
  return 0;
}

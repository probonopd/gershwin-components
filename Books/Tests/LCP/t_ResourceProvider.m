/* t_ResourceProvider.m - Normal vs LCP resource providers (spec 1, 8, 9).
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "LCPResourceProvider.h"
#import "LCPClientBackend.h"
#import "LCPOpenSSLBackend.h"

static NSString *TmpDir(void)
{
  NSString *base = NSTemporaryDirectory();
  NSString *dir = [base stringByAppendingPathComponent:
    [NSString stringWithFormat: @"lcp_rp_%d", (int)getpid()]];
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
  NSString *dir = TmpDir();

  NSString *plainPath = @"EPUB/chapter1.xhtml";
  NSString *encPath   = @"EPUB/secret.xhtml";
  NSData *ck = [@"0123456789abcdef0123456789abcdef" dataUsingEncoding: NSUTF8StringEncoding];

  /* Seed: a normal plaintext file and an LCP-encrypted file. */
  NSString *plain = @"<html>plain</html>";
  [[plain dataUsingEncoding: NSUTF8StringEncoding]
    writeToFile: [dir stringByAppendingPathComponent: plainPath] atomically: NO];
  NSData *ct = [LCPOpenSSLBackend encryptedResource:
    [@"<html>secret</html>" dataUsingEncoding: NSUTF8StringEncoding] contentKey: ck];
  [ct writeToFile: [dir stringByAppendingPathComponent: encPath] atomically: NO];

  /* Normal provider: returns bytes verbatim, never encrypted. */
  {
    NormalEPUBResourceProvider *np =
      [[NormalEPUBResourceProvider alloc] initWithBasePath: dir];
    PASS([np isEncrypted: plainPath] == NO, "normal provider: nothing encrypted");
    NSError *err = nil;
    NSData *d = [np dataForResource: plainPath error: &err];
    PASS(d != nil && err == nil, "normal provider reads file");
    PASS_EQUAL([NSString stringWithUTF8String: [d bytes]], plain, "normal provider content");
  }

  /* LCP provider: decrypts only the paths marked encrypted. */
  {
    NormalEPUBResourceProvider *np =
      [[NormalEPUBResourceProvider alloc] initWithBasePath: dir];
    LCPEPUBResourceProvider *lp =
      [[LCPEPUBResourceProvider alloc] initWithBaseProvider: np
                                                   license: nil
                                               contentKey: ck
                                                   backend: be];
    [lp setEncryptedPaths: [NSSet setWithObject: encPath]];

    PASS([lp isEncrypted: encPath] == YES, "lcp provider flags encrypted path");
    PASS([lp isEncrypted: plainPath] == NO, "lcp provider leaves others normal");

    NSError *err = nil;
    NSData *d = [lp dataForResource: encPath error: &err];
    PASS(d != nil && err == nil, "lcp provider decrypts without error");
    PASS_EQUAL([NSString stringWithUTF8String: [d bytes]], @"<html>secret</html>",
               "lcp provider returns decrypted plaintext");

    /* The same path through the normal provider is still ciphertext. */
    NSData *raw = [np dataForResource: encPath error: NULL];
    PASS_EQUAL(raw, ct, "underlying storage stays encrypted on disk");
  }

  [[NSFileManager defaultManager] removeFileAtPath: dir handler: nil];
  [arp release];
  return 0;
}

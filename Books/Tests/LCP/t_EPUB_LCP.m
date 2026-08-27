/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>
#import <zlib.h>
#import "Testing.h"
#import "EPUBBook.h"
#import "LCP/LCPManager.h"
#import "LCP/LCPLicense.h"
#import "LCP/LCPOpenSSLBackend.h"
#import "LCP/LCPError.h"

static NSString *const kPassphrase = @"test";
static NSString *const kLicenseID = @"urn:uuid:11112222-3333-4444-5555-666677778888";
static NSString *const kAlgAES = @"http://www.w3.org/2001/04/xmlenc#aes256-cbc";
static NSString *const kAlgSHA = @"http://www.w3.org/2001/04/xmlenc#sha256";

static NSData *randomData(NSUInteger n)
{
  NSMutableData *d = [NSMutableData dataWithLength:n];
  arc4random_buf([d mutableBytes], n);
  return d;
}

/* zlib-deflate (Compression Method=8) like LCP does before encrypting. */
static NSData *deflateData(NSData *in)
{
  uLongf destLen = compressBound([in length]);
  NSMutableData *out = [[NSMutableData alloc] initWithLength: destLen];
  if (compress([out mutableBytes], &destLen, [in bytes], (uLong)[in length]) != Z_OK)
    return nil;
  [out setLength: destLen];
  return out;
}

/* Build a complete LCP-protected EPUB in a temp dir and zip it to |outPath|.
 * |profile| selects the LCP profile URI; when |compress| is set, resources are
 * DEFLATEd before encryption (LCP Compression Method=8), exercising the
 * inflate path used by real-world books (e.g. EDRLab). */
static void buildSyntheticLCPepub(NSString *outPath,
                                  NSString *profile,
                                  BOOL compress,
                                  NSData **chapterPlain,
                                  NSData **imagePlain,
                                  NSError **error)
{
  NSString *work = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"lcptest-%@", [[NSUUID UUID] UUIDString]]];
  [[NSFileManager defaultManager] createDirectoryAtPath:work
                            withIntermediateDirectories:YES attributes:nil error:NULL];
  NSString *epubDir = [work stringByAppendingPathComponent:@"epub"];
  NSString *meta = [epubDir stringByAppendingPathComponent:@"META-INF"];
  NSString *content = [epubDir stringByAppendingPathComponent:@"EPUB"];
  [[NSFileManager defaultManager] createDirectoryAtPath:meta
                            withIntermediateDirectories:YES attributes:nil error:NULL];
  [[NSFileManager defaultManager] createDirectoryAtPath:content
                            withIntermediateDirectories:YES attributes:nil error:NULL];

  NSData *chap = [@"<html><body><h1>Secret Chapter</h1><p>Hello LCP world.</p>"
                 "</body></html>" dataUsingEncoding:NSUTF8StringEncoding];
  NSData *img = randomData(2048);
  *chapterPlain = chap;
  *imagePlain = img;

  NSData *contentKey = randomData(32);
  NSData *userKey = [[LCPOpenSSLBackend new] userKeyFromPassphrase:kPassphrase];

  NSData *chapCT, *imgCT;
  NSString *chapCompAttr = @"", *imgCompAttr = @"";
  if (compress)
    {
      NSData *chapDef = deflateData(chap);
      NSData *imgDef = deflateData(img);
      chapCT = [LCPOpenSSLBackend encryptedResource:chapDef contentKey:contentKey];
      imgCT = [LCPOpenSSLBackend encryptedResource:imgDef contentKey:contentKey];
      chapCompAttr = [NSString stringWithFormat:
          @"<EncryptionProperties xmlns=\"http://www.w3.org/2001/04/xmlenc#\">"
          @"<EncryptionProperty><Compression "
          @"xmlns=\"http://www.idpf.org/2016/encryption#compression\" "
          @"Method=\"8\" OriginalLength=\"%lu\"></Compression></EncryptionProperty>"
          @"</EncryptionProperties>", (unsigned long)[chap length]];
      imgCompAttr = [NSString stringWithFormat:
          @"<EncryptionProperties xmlns=\"http://www.w3.org/2001/04/xmlenc#\">"
          @"<EncryptionProperty><Compression "
          @"xmlns=\"http://www.idpf.org/2016/encryption#compression\" "
          @"Method=\"8\" OriginalLength=\"%lu\"></Compression></EncryptionProperty>"
          @"</EncryptionProperties>", (unsigned long)[img length]];
    }
  else
    {
      chapCT = [LCPOpenSSLBackend encryptedResource:chap contentKey:contentKey];
      imgCT = [LCPOpenSSLBackend encryptedResource:img contentKey:contentKey];
    }
  [chapCT writeToFile:[content stringByAppendingPathComponent:@"chapter1.xhtml"]
           atomically:NO];
  [imgCT writeToFile:[content stringByAppendingPathComponent:@"img1.png"]
          atomically:NO];

  NSData *encCK = [LCPOpenSSLBackend encryptedContentKey:contentKey userKey:userKey];
  NSData *keyCheck = [LCPOpenSSLBackend keyCheckForLicenseID:kLicenseID
                                                     userKey:userKey];
  NSDictionary *lic = @{
    @"id": kLicenseID,
    @"issued": @"2025-01-01T00:00:00Z",
    @"provider": @"Test Provider",
    @"encryption": @{
      @"profile": profile,
      @"content_key": @{
        @"algorithm": kAlgAES,
        @"encrypted_value": [encCK base64EncodedStringWithOptions:0]
      },
      @"user_key": @{
        @"algorithm": kAlgSHA,
        @"key_check": [keyCheck base64EncodedStringWithOptions:0],
        @"text_hint": @"the passphrase is 'test'"
      }
    },
    @"rights": @{},
    @"signature": @{ @"algorithm": @"http://www.w3.org/2001/04/xmldsig-more#rsa-sha256",
                     @"certificate": @"", @"value": @"" }
  };
  NSData *licJSON = [NSJSONSerialization dataWithJSONObject:lic options:0 error:NULL];
  [licJSON writeToFile:[meta stringByAppendingPathComponent:@"license.lcpl"] atomically:NO];

  NSString *encXml = [NSString stringWithFormat:
    @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    @"<encryption xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"\n"
    @"  xmlns:enc=\"http://www.w3.org/2001/04/xmlenc#\"\n"
    @"  xmlns:ds=\"http://www.w3.org/2000/09/xmldsig#\">\n"
    @"  <enc:EncryptedData Id=\"ED-chap\">\n"
    @"    <enc:EncryptionMethod Algorithm=\"%@\"/>\n"
    @"    <ds:KeyInfo><ds:RetrievalMethod URI=\"license.lcpl#/encryption/content_key\"/></ds:KeyInfo>\n"
    @"    <enc:CipherData><enc:CipherReference URI=\"EPUB/chapter1.xhtml\"/></enc:CipherData>\n"
    @"    %@\n"
    @"  </enc:EncryptedData>\n"
    @"  <enc:EncryptedData Id=\"ED-img\">\n"
    @"    <enc:EncryptionMethod Algorithm=\"%@\"/>\n"
    @"    <ds:KeyInfo><ds:RetrievalMethod URI=\"license.lcpl#/encryption/content_key\"/></ds:KeyInfo>\n"
    @"    <enc:CipherData><enc:CipherReference URI=\"EPUB/img1.png\"/></enc:CipherData>\n"
    @"    %@\n"
    @"  </enc:EncryptedData>\n"
    @"</encryption>\n", kAlgAES, chapCompAttr, kAlgAES, imgCompAttr];
  [encXml writeToFile:[meta stringByAppendingPathComponent:@"encryption.xml"]
           atomically:NO encoding:NSUTF8StringEncoding error:NULL];

  NSString *container =
    @"<?xml version=\"1.0\"?>\n"
    @"<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\n"
    @"  <rootfiles><rootfile full-path=\"EPUB/content.opf\" "
    @"media-type=\"application/oebps-package+xml\"/></rootfiles>\n"
    @"</container>\n";
  [container writeToFile:[meta stringByAppendingPathComponent:@"container.xml"]
              atomically:NO encoding:NSUTF8StringEncoding error:NULL];

  NSString *opf = [NSString stringWithFormat:
    @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    @"<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"bk\">\n"
    @"  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n"
    @"    <dc:identifier id=\"bk\">%@</dc:identifier>\n"
    @"    <dc:title>LCP Test Book</dc:title>\n"
    @"    <dc:language>en</dc:language>\n"
    @"  </metadata>\n"
    @"  <manifest>\n"
    @"    <item id=\"c1\" href=\"chapter1.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
    @"    <item id=\"i1\" href=\"img1.png\" media-type=\"image/png\"/>\n"
    @"  </manifest>\n"
    @"  <spine>\n"
    @"    <itemref idref=\"c1\"/>\n"
    @"  </spine>\n"
    @"</package>\n", kLicenseID];
  opf = [NSString stringWithFormat:opf, kLicenseID];
  [opf writeToFile:[content stringByAppendingPathComponent:@"content.opf"]
         atomically:NO encoding:NSUTF8StringEncoding error:NULL];
  [@"application/epub+zip" writeToFile:[epubDir stringByAppendingPathComponent:@"mimetype"]
                             atomically:NO encoding:NSUTF8StringEncoding error:NULL];

  NSTask *zip = [[NSTask alloc] init];
  [zip setLaunchPath:@"/usr/bin/zip"];
  [zip setCurrentDirectoryPath:epubDir];
  [zip setArguments:@[ @"-X", @"-r", @"-q", outPath, @"." ]];
  [zip launch];
  [zip waitUntilExit];
  if ([zip terminationStatus] != 0 && error)
    *error = [NSError errorWithDomain:@"zip" code:1 userInfo:nil];

  [[NSFileManager defaultManager] removeItemAtPath:work error:NULL];
}

static int runScenario(NSString *label, NSString *profile, BOOL compress)
{
  int failed = 0;
  NSString *epub = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"lcpbook-%@-%@.epub",
              label, [[NSUUID UUID] UUIDString]]];
  NSData *chapPlain = nil, *imgPlain = nil;
  NSError *e = nil;
  buildSyntheticLCPepub(epub, profile, compress, &chapPlain, &imgPlain, &e);
  if (e != nil) { NSLog(@"build failed: %@", e); return 1; }

  EPUBBook *b = [[EPUBBook alloc] initWithEPUBAtPath:epub error:&e];
  PASS(b != nil, "%s: LCP EPUB opens", [label UTF8String]);
  if (b == nil) return 1;
  PASS(b.lcpProtected == YES, "%s: detected as LCP-protected", [label UTF8String]);

  PASS([b lcpUnlockWithPassphrase:@"wrong" error:&e] == NO,
       "%s: wrong passphrase rejected", [label UTF8String]);
  PASS([b lcpUnlockWithPassphrase:kPassphrase error:&e] == YES,
       "%s: correct passphrase unlocks", [label UTF8String]);

  NSString *spineAbs = [b.spine firstObject];
  NSString *decChapter = [b materializedPathForPath:spineAbs error:&e];
  PASS(decChapter != nil, "%s: encrypted spine materializes", [label UTF8String]);
  if (decChapter != nil)
    {
      NSData *got = [NSData dataWithContentsOfFile:decChapter];
      PASS([got isEqualToData:chapPlain], "%s: decrypted spine equals plaintext", [label UTF8String]);
    }

  NSString *imgAbs = [b.extractedRoot stringByAppendingPathComponent:@"EPUB/img1.png"];
  NSString *decImg = [b materializedPathForPath:imgAbs error:&e];
  PASS(decImg != nil, "%s: encrypted image materializes", [label UTF8String]);
  if (decImg != nil)
    {
      NSData *got = [NSData dataWithContentsOfFile:decImg];
      PASS([got isEqualToData:imgPlain], "%s: decrypted image equals plaintext", [label UTF8String]);
    }
  [b cleanupExtraction];
  return failed;
}

int main(int argc, char **argv)
{
  CREATE_AUTORELEASE_POOL(pool);
  (void)pool;
  int failed = 0;
  failed += runScenario(@"basic", LCPProfileBasic, NO);
  failed += runScenario(@"profile-2.1-compressed", LCPProfile2_1, YES);
  return failed;
}

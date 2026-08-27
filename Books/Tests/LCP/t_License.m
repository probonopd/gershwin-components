/* t_License.m - LCPLicense parse/validate (spec 3.3, 3.4, 6.3).
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "LCPLicense.h"
#import "LCPError.h"

static NSData *JSONWith(NSDictionary *dict)
{
  return [NSJSONSerialization dataWithJSONObject: dict options: 0 error: NULL];
}

static NSDictionary *ValidDict(void)
{
  return @{
    @"id": @"abc-123",
    @"issued": @"2020-01-01T00:00:00Z",
    @"provider": @"https://example.com",
    @"encryption": @{
      @"profile": LCPProfileBasic,
      @"content_key": @{
        @"algorithm": LCPAlgorithmAES256CBC,
        @"encrypted_value": @"AAAA"
      },
      @"user_key": @{
        @"algorithm": LCPAlgorithmSHA256,
        @"key_check": @"BBBB",
        @"text_hint": @"Enter your passphrase"
      }
    },
    @"links": @[ @{ @"rel": @"publication", @"href": @"https://example.com/b.epub" } ]
  };
}

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  /* Invalid JSON is rejected. */
  {
    NSData *bad = [@"not json" dataUsingEncoding: NSUTF8StringEncoding];
    NSError *err = nil;
    LCPLicense *lic = [LCPLicense licenseWithJSON: bad error: &err];
    PASS(lic == nil, "non-JSON license is rejected");
    PASS(err != nil && [err.domain isEqualToString: LCPErrorDomain]
         && err.code == LCPErrorInvalidLicense, "non-JSON yields LCPErrorInvalidLicense");
  }

  /* Missing required field (id) is rejected. */
  {
    NSMutableDictionary *d = [ValidDict() mutableCopy];
    [d removeObjectForKey: @"id"];
    NSError *err = nil;
    LCPLicense *lic = [LCPLicense licenseWithJSON: JSONWith(d) error: &err];
    PASS(lic == nil, "license missing id is rejected");
    PASS(err != nil && err.code == LCPErrorInvalidLicense, "missing id yields LCPErrorInvalidLicense");
  }

  /* Unsupported profile is rejected. */
  {
    NSMutableDictionary *d = [ValidDict() mutableCopy];
    NSMutableDictionary *e = [d[@"encryption"] mutableCopy];
    e[@"profile"] = @"http://readium.org/lcp/unknown";
    d[@"encryption"] = e;
    NSError *err = nil;
    LCPLicense *lic = [LCPLicense licenseWithJSON: JSONWith(d) error: &err];
    PASS(lic == nil, "unsupported profile is rejected");
    PASS(err != nil && err.code == LCPErrorUnsupportedProfile, "unsupported profile yields LCPErrorUnsupportedProfile");
  }

  /* Valid license parses and exposes fields. */
  {
    NSError *err = nil;
    LCPLicense *lic = [LCPLicense licenseWithJSON: JSONWith(ValidDict()) error: &err];
    PASS(lic != nil, "valid license parses");
    PASS(err == nil, "valid license has no error");
    PASS_EQUAL(lic.licenseID, @"abc-123", "license id exposed");
    PASS_EQUAL(lic.profile, LCPProfileBasic, "profile exposed");
    PASS_EQUAL(lic.userKeyTextHint, @"Enter your passphrase", "text hint exposed");
    PASS_EQUAL(lic.publicationLink, @"https://example.com/b.epub", "publication link found");
  }

  [arp release];
  return 0;
}

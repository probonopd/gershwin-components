/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

// NIST FIPS 180-4 test vectors pin the in-process SHA-256 used by the
// copy/verify checksum passes, so a silent math regression can never pass
// as a "verified" restore or image.

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "DUSHA256.h"

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;

    // Empty input.
    DUSHA256 *empty = [[DUSHA256 alloc] init];
    PASS_EQUAL([empty finalHex],
               @"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
               "SHA-256 of empty input matches the NIST vector");

    // Single-block vector ("abc").
    DUSHA256 *abc = [[DUSHA256 alloc] init];
    [abc updateWithBytes:"abc" length:3];
    PASS_EQUAL([abc finalHex],
               @"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
               "SHA-256 of \"abc\" matches the NIST vector");

    // Multi-block vector across several updates to exercise buffering.
    NSString *longInput = @"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    DUSHA256 *chunked = [[DUSHA256 alloc] init];
    NSData *data = [longInput dataUsingEncoding:NSUTF8StringEncoding];
    NSData *firstHalf = [data subdataWithRange:NSMakeRange(0, 13)];
    NSData *secondHalf =
        [data subdataWithRange:NSMakeRange(13, data.length - 13)];
    [chunked updateWithData:firstHalf];
    [chunked updateWithData:secondHalf];
    PASS_EQUAL([chunked finalHex],
               @"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
               "split multi-block update matches the NIST vector");

    // Byte-at-a-time feeding exercises the partial-block path.
    DUSHA256 *byteWise = [[DUSHA256 alloc] init];
    for (NSUInteger i = 0; i < data.length; i++) {
        unsigned char byte = ((const unsigned char *)data.bytes)[i];
        [byteWise updateWithBytes:&byte length:1];
    }
    PASS_EQUAL([byteWise finalHex],
               @"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
               "byte-wise feeding matches the one-shot result");

    // A million 'a' characters, fed in irregular chunks (the classic
    // million-'a' vector), guards against length arithmetic bugs.
    DUSHA256 *million = [[DUSHA256 alloc] init];
    char buffer[1000];
    memset(buffer, 'a', sizeof(buffer));
    [million updateWithBytes:buffer length:7];
    for (int i = 0; i < 999; i++) {
        [million updateWithBytes:buffer length:1000];
    }
    [million updateWithBytes:buffer length:993];
    PASS_EQUAL([million finalHex],
               @"cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
               "one million 'a' characters match the NIST vector");

    return 0;
}

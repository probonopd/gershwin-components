/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "DUSHA256.h"

// FIPS 180-4 constants and per-round words.
static const unsigned int DUSHA256K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

@interface DUSHA256 ()
{
    unsigned int _state[8];
    unsigned long long _bitCount;
    unsigned char _buffer[64];
    NSUInteger _bufferLength;
    BOOL _finished;
}
@end

@implementation DUSHA256

- (instancetype)init
{
    if ((self = [super init]) == nil) {
        return nil;
    }
    _state[0] = 0x6a09e667;
    _state[1] = 0xbb67ae85;
    _state[2] = 0x3c6ef372;
    _state[3] = 0xa54ff53a;
    _state[4] = 0x510e527f;
    _state[5] = 0x9b05688c;
    _state[6] = 0x1f83d9ab;
    _state[7] = 0x5be0cd19;
    _bitCount = 0;
    _bufferLength = 0;
    _finished = NO;
    return self;
}

// Processes one full 64-byte block (FIPS 180-4 section 6.2.2).
- (void)_compressBlock:(const unsigned char *)block
{
    unsigned int w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = ((unsigned int)block[i * 4] << 24) |
               ((unsigned int)block[i * 4 + 1] << 16) |
               ((unsigned int)block[i * 4 + 2] << 8) |
               ((unsigned int)block[i * 4 + 3]);
    }
    for (int i = 16; i < 64; i++) {
        unsigned int s0 = ROTR(w[i - 15], 7) ^ ROTR(w[i - 15], 18) ^
                          (w[i - 15] >> 3);
        unsigned int s1 = ROTR(w[i - 2], 17) ^ ROTR(w[i - 2], 19) ^
                          (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    unsigned int a = _state[0], b = _state[1], c = _state[2], d = _state[3];
    unsigned int e = _state[4], f = _state[5], g = _state[6], h = _state[7];

    for (int i = 0; i < 64; i++) {
        unsigned int s1 =
            ROTR(e, 6) ^ ROTR(e, 11) ^ ROTR(e, 25);
        unsigned int ch = (e & f) ^ (~e & g);
        unsigned int temp1 = h + s1 + ch + DUSHA256K[i] + w[i];
        unsigned int s0 =
            ROTR(a, 2) ^ ROTR(a, 13) ^ ROTR(a, 22);
        unsigned int maj = (a & b) ^ (a & c) ^ (b & c);
        unsigned int temp2 = s0 + maj;
        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }

    _state[0] += a;
    _state[1] += b;
    _state[2] += c;
    _state[3] += d;
    _state[4] += e;
    _state[5] += f;
    _state[6] += g;
    _state[7] += h;
}

- (void)updateWithBytes:(const void *)bytes length:(NSUInteger)length
{
    NSParameterAssert(!_finished);
    if (bytes == NULL || length == 0) {
        return;
    }
    const unsigned char *cursor = bytes;
    _bitCount += (unsigned long long)length * 8;

    // Top up the partial block first so the main loop stays aligned.
    if (_bufferLength > 0) {
        NSUInteger need = 64 - _bufferLength;
        NSUInteger take = length < need ? length : need;
        memcpy(_buffer + _bufferLength, cursor, take);
        _bufferLength += take;
        cursor += take;
        length -= take;
        if (_bufferLength == 64) {
            [self _compressBlock:_buffer];
            _bufferLength = 0;
        }
    }
    while (length >= 64) {
        [self _compressBlock:cursor];
        cursor += 64;
        length -= 64;
    }
    if (length > 0) {
        memcpy(_buffer, cursor, length);
        _bufferLength = length;
    }
}

- (void)updateWithData:(NSData *)data
{
    [self updateWithBytes:data.bytes length:data.length];
}

- (NSString *)finalHex
{
    NSParameterAssert(!_finished);

    // Padding: 0x80, zeros, then the 64-bit big-endian bit count.
    unsigned long long bitCount = _bitCount;
    unsigned char pad = 0x80;
    [self updateWithBytes:&pad length:1];
    unsigned char zero = 0;
    while (_bufferLength != 56) {
        [self updateWithBytes:&zero length:1];
    }
    unsigned char lengthBytes[8];
    for (int i = 0; i < 8; i++) {
        lengthBytes[i] = (unsigned char)(bitCount >> (56 - i * 8));
    }
    // Bypass the counter update of updateWithBytes for the trailer.
    memcpy(_buffer + _bufferLength, lengthBytes, 8);
    _bufferLength += 8;
    [self _compressBlock:_buffer];
    _bufferLength = 0;

    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < 8; i++) {
        [hex appendFormat:@"%08x", _state[i]];
    }
    _finished = YES;
    return hex;
}

@end

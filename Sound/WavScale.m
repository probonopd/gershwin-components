/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "WavScale.h"

typedef struct
{
    NSUInteger sampleOffset;   /* offset of the data chunk payload */
    NSUInteger sampleBytes;    /* size of the data chunk payload */
    uint16_t formatTag;        /* 1 = PCM, 3 = IEEE float */
    uint16_t bitsPerSample;
} SoundWavInfo;

/* Minimal RIFF/WAVE walker: finds the fmt and data chunks. Handles
 * WAVE_FORMAT_EXTENSIBLE by reading the real tag from its subformat GUID. */
static BOOL SoundParseWav(const uint8_t *b, NSUInteger len, SoundWavInfo *out)
{
    if (len < 12 || memcmp(b, "RIFF", 4) != 0 || memcmp(b + 8, "WAVE", 4) != 0)
        return NO;

    NSUInteger off = 12;
    BOOL haveFmt = NO, haveData = NO;

    while (off + 8 <= len) {
        uint32_t size = (uint32_t)b[off + 4] | ((uint32_t)b[off + 5] << 8) |
                        ((uint32_t)b[off + 6] << 16) | ((uint32_t)b[off + 7] << 24);

        if (!haveFmt && memcmp(b + off, "fmt ", 4) == 0) {
            if (off + 24 > len) return NO;
            out->formatTag = (uint16_t)(b[off + 8] | (b[off + 9] << 8));
            out->bitsPerSample = (uint16_t)(b[off + 22] | (b[off + 23] << 8));
            if (out->formatTag == 0xFFFE && off + 48 <= len) {
                out->formatTag = (uint16_t)(b[off + 32] | (b[off + 33] << 8));
            }
            haveFmt = YES;
        } else if (!haveData && memcmp(b + off, "data", 4) == 0) {
            NSUInteger avail = len - off - 8;
            out->sampleOffset = off + 8;
            out->sampleBytes = (size <= avail) ? size : avail;
            haveData = YES;
        }

        /* Chunks are word aligned, so odd payloads carry a pad byte */
        off += 8 + size + (size & 1);
        if (haveFmt && haveData) break;
    }

    return haveFmt && haveData && out->sampleBytes > 0;
}

static int32_t SoundClamp(double v, double lo, double hi)
{
    if (v < lo) return (int32_t)lo;
    if (v > hi) return (int32_t)hi;
    return (int32_t)v;
}

NSData *SoundScaleWavData(NSData *wavData, float gain)
{
    const uint8_t *src = [wavData bytes];
    SoundWavInfo info = {0};

    if (!SoundParseWav(src, [wavData length], &info))
        return nil;

    switch (info.formatTag) {
        case 1:
            if (info.bitsPerSample != 8 && info.bitsPerSample != 16 &&
                info.bitsPerSample != 24 && info.bitsPerSample != 32)
                return nil;
            break;
        case 3:
            if (info.bitsPerSample != 32 && info.bitsPerSample != 64)
                return nil;
            break;
        default:
            return nil;
    }

    NSMutableData *out = [wavData mutableCopy];
    uint8_t *d = [out mutableBytes] + info.sampleOffset;
    NSUInteger n = info.sampleBytes;

    switch (info.formatTag) {
        case 1: {
            switch (info.bitsPerSample) {
                case 8: {
                    /* 8 bit WAV is unsigned, centred on 128 */
                    for (NSUInteger i = 0; i < n; i++) {
                        int v = SoundClamp((d[i] - 128) * gain, -128, 127);
                        d[i] = (uint8_t)(v + 128);
                    }
                    break;
                }
                case 16: {
                    for (NSUInteger i = 0; i + 1 < n; i += 2) {
                        int16_t s = (int16_t)((uint16_t)d[i] | ((uint16_t)d[i + 1] << 8));
                        s = (int16_t)SoundClamp(s * gain, -32768, 32767);
                        d[i] = (uint8_t)(s & 0xff);
                        d[i + 1] = (uint8_t)(((uint16_t)s >> 8) & 0xff);
                    }
                    break;
                }
                case 24: {
                    for (NSUInteger i = 0; i + 2 < n; i += 3) {
                        int32_t s = (int32_t)((uint32_t)d[i] | ((uint32_t)d[i + 1] << 8) |
                                              ((uint32_t)d[i + 2] << 16));
                        if (s & 0x800000) s -= 0x1000000;
                        s = SoundClamp(s * gain, -8388608, 8388607);
                        d[i] = (uint8_t)(s & 0xff);
                        d[i + 1] = (uint8_t)((s >> 8) & 0xff);
                        d[i + 2] = (uint8_t)((s >> 16) & 0xff);
                    }
                    break;
                }
                case 32: {
                    for (NSUInteger i = 0; i + 3 < n; i += 4) {
                        int32_t s = (int32_t)((uint32_t)d[i] | ((uint32_t)d[i + 1] << 8) |
                                              ((uint32_t)d[i + 2] << 16) |
                                              ((uint32_t)d[i + 3] << 24));
                        s = SoundClamp((double)s * gain, -2147483648.0, 2147483647.0);
                        d[i] = (uint8_t)(s & 0xff);
                        d[i + 1] = (uint8_t)((s >> 8) & 0xff);
                        d[i + 2] = (uint8_t)((s >> 16) & 0xff);
                        d[i + 3] = (uint8_t)((s >> 24) & 0xff);
                    }
                    break;
                }
            }
            break;
        }
        case 3: {
            size_t step = (info.bitsPerSample == 32) ? 4 : 8;
            for (NSUInteger i = 0; i + step <= n; i += step) {
                if (step == 4) {
                    float f;
                    memcpy(&f, d + i, 4);
                    f *= gain;
                    memcpy(d + i, &f, 4);
                } else {
                    double f;
                    memcpy(&f, d + i, 8);
                    f *= gain;
                    memcpy(d + i, &f, 8);
                }
            }
            break;
        }
    }

    return out;
}

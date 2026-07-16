/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "SoundVolume.h"
#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>
#import <sys/ioctl.h>
#ifndef __OpenBSD__
#import <sys/soundcard.h>
#endif
#import <fcntl.h>
#import <unistd.h>

typedef NS_ENUM(NSInteger, VolumeBackend) {
    VolumeBackendNone,
    VolumeBackendALSA,
    VolumeBackendOSS
};

static VolumeBackend _backend = VolumeBackendNone;
static int _ossMixerFd = -1;
static NSString *_alsaControl = nil;
static int _alsaCard = -1;

#ifdef __linux__
static BOOL _detectALSA(void)
{
    // Check if amixer exists and can find a card
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/aplay"];
    [task setArguments:@[@"-l"]];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        return NO;
    }
    if ([task terminationStatus] != 0) return NO;
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!output) return NO;

    // Try to find "card N:" in output
    NSScanner *scanner = [NSScanner scannerWithString:output];
    while (![scanner isAtEnd]) {
        if ([scanner scanString:@"card" intoString:NULL]) {
            int card;
            if ([scanner scanInt:&card]) {
                _alsaCard = card;
                break;
            }
        }
        [scanner scanUpToString:@"card" intoString:NULL];
    }
    if (_alsaCard < 0) return NO;

    // Find mixer control
    task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/amixer"];
    [task setArguments:@[@"-c", [NSString stringWithFormat:@"%d", _alsaCard], @"scontrols"]];
    pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        return NO;
    }
    data = [[pipe fileHandleForReading] readDataToEndOfFile];
    output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!output) return NO;

    NSArray *priorities = @[@"Master", @"PCM", @"Speaker", @"Headphone"];
    for (NSString *name in priorities) {
        if ([output rangeOfString:name].location != NSNotFound) {
            _alsaControl = name;
            return YES;
        }
    }
    return NO;
}
#else
static BOOL _detectALSA(void) { return NO; }
#endif /* __linux__ */

#ifndef __OpenBSD__
static BOOL _detectOSS(void)
{
    _ossMixerFd = open("/dev/mixer", O_RDWR);
    if (_ossMixerFd < 0) return NO;
    // Verify we can read PCM channel
    int vol = -1;
    if (ioctl(_ossMixerFd, MIXER_READ(SOUND_MIXER_PCM), &vol) < 0) {
        // Try master volume
        if (ioctl(_ossMixerFd, MIXER_READ(SOUND_MIXER_VOLUME), &vol) < 0) {
            close(_ossMixerFd);
            _ossMixerFd = -1;
            return NO;
        }
    }
    return YES;
}
#else
static BOOL _detectOSS(void) { return NO; }
#endif

static void _ensureBackend(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (_detectALSA()) {
            _backend = VolumeBackendALSA;
        } else if (_detectOSS()) {
            _backend = VolumeBackendOSS;
        }
    });
}

#ifdef __linux__
static NSString *_runAmixer(NSArray *args)
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/amixer"];
    [task setArguments:args];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        return nil;
    }
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static float _parseAmixerVolume(NSString *output)
{
    NSScanner *scanner = [NSScanner scannerWithString:output];
    while (![scanner isAtEnd]) {
        [scanner scanUpToString:@"[" intoString:NULL];
        if ([scanner scanString:@"[" intoString:NULL]) {
            int val;
            if ([scanner scanInt:&val]) {
                return (float)val / 100.0f;
            }
        }
    }
    return 0.0f;
}
#else
static NSString *_runAmixer(NSArray *args) { return nil; }
static float _parseAmixerVolume(NSString *output) { return 0.0f; }
#endif /* __linux__ */

@implementation SoundVolume

+ (float)outputVolume
{
    _ensureBackend();
    if (_backend == VolumeBackendALSA) {
        NSString *output = _runAmixer(@[@"-c", [NSString stringWithFormat:@"%d", _alsaCard],
                                         @"sget", _alsaControl]);
        if (!output) return 0.0f;
        return _parseAmixerVolume(output);
#ifndef __OpenBSD__
    } else if (_backend == VolumeBackendOSS) {
        int vol = -1;
        if (ioctl(_ossMixerFd, MIXER_READ(SOUND_MIXER_PCM), &vol) < 0) {
            if (ioctl(_ossMixerFd, MIXER_READ(SOUND_MIXER_VOLUME), &vol) < 0) {
                return 0.0f;
            }
        }
        // OSS returns left vol in low byte, right in high byte; average them
        int left = vol & 0xFF;
        int right = (vol >> 8) & 0xFF;
        return (float)((left + right) / 2) / 100.0f;
#endif
    }
    return 0.0f;
}

+ (void)setOutputVolume:(float)volume
{
    _ensureBackend();
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    int percent = (int)(volume * 100.0f);

    if (_backend == VolumeBackendALSA) {
        _runAmixer(@[@"-c", [NSString stringWithFormat:@"%d", _alsaCard],
                      @"sset", _alsaControl, [NSString stringWithFormat:@"%d%%", percent]]);
#ifndef __OpenBSD__
    } else if (_backend == VolumeBackendOSS) {
        int packed = (percent << 8) | percent;  // same value for left and right
        if (ioctl(_ossMixerFd, MIXER_WRITE(SOUND_MIXER_PCM), &packed) < 0) {
            ioctl(_ossMixerFd, MIXER_WRITE(SOUND_MIXER_VOLUME), &packed);
        }
#endif
    }
}

+ (void)increaseVolume
{
    float vol = [self outputVolume];
    vol += 0.05f;
    if (vol > 1.0f) vol = 1.0f;
    [self setOutputVolume:vol];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SoundVolumeChanged" object:nil];
}

+ (void)decreaseVolume
{
    float vol = [self outputVolume];
    vol -= 0.05f;
    if (vol < 0.0f) vol = 0.0f;
    [self setOutputVolume:vol];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SoundVolumeChanged" object:nil];
}

+ (void)toggleMute
{
    _ensureBackend();
    if (_backend == VolumeBackendALSA) {
        NSString *output = _runAmixer(@[@"-c", [NSString stringWithFormat:@"%d", _alsaCard],
                                         @"sget", _alsaControl]);
        BOOL muted = (output && [output rangeOfString:@"[off]"].location != NSNotFound);
        _runAmixer(@[@"-c", [NSString stringWithFormat:@"%d", _alsaCard],
                      @"sset", _alsaControl, muted ? @"unmute" : @"mute"]);
#ifndef __OpenBSD__
    } else if (_backend == VolumeBackendOSS) {
        int vol = -1;
        if (ioctl(_ossMixerFd, MIXER_READ(SOUND_MIXER_PCM), &vol) < 0) {
            ioctl(_ossMixerFd, MIXER_READ(SOUND_MIXER_VOLUME), &vol);
        }
        int left = vol & 0xFF;
        BOOL muted = (left == 0);
        int newVol = muted ? 80 : 0;  // restore to 80% or mute
        int packed = (newVol << 8) | newVol;
        if (ioctl(_ossMixerFd, MIXER_WRITE(SOUND_MIXER_PCM), &packed) < 0) {
            ioctl(_ossMixerFd, MIXER_WRITE(SOUND_MIXER_VOLUME), &packed);
        }
#endif
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SoundVolumeChanged" object:nil];
}

+ (BOOL)isMuted
{
    _ensureBackend();
    if (_backend == VolumeBackendALSA) {
        NSString *output = _runAmixer(@[@"-c", [NSString stringWithFormat:@"%d", _alsaCard],
                                         @"sget", _alsaControl]);
        return (output && [output rangeOfString:@"[off]"].location != NSNotFound);
#ifndef __OpenBSD__
    } else if (_backend == VolumeBackendOSS) {
        int vol = -1;
        if (ioctl(_ossMixerFd, MIXER_READ(SOUND_MIXER_PCM), &vol) < 0) {
            ioctl(_ossMixerFd, MIXER_READ(SOUND_MIXER_VOLUME), &vol);
        }
        return ((vol & 0xFF) == 0);
#endif
    }
    return NO;
}

+ (void)toggleMicMute
{
    _ensureBackend();
    if (_backend == VolumeBackendALSA) {
        // Try "Capture" first, then "Mic" as fallback
        NSArray *controls = @[@"Capture", @"Mic"];
        BOOL muted = NO;
        NSString *foundControl = nil;
        for (NSString *ctl in controls) {
            NSString *output = _runAmixer(@[@"-c", [NSString stringWithFormat:@"%d", _alsaCard],
                                             @"sget", ctl]);
            if (output) {
                foundControl = ctl;
                muted = ([output rangeOfString:@"[off]"].location != NSNotFound);
                break;
            }
        }
        if (foundControl) {
            _runAmixer(@[@"-c", [NSString stringWithFormat:@"%d", _alsaCard],
                          @"sset", foundControl, muted ? @"unmute" : @"mute"]);
        }
#ifndef __OpenBSD__
    } else if (_backend == VolumeBackendOSS) {
        int vol = -1;
        if (ioctl(_ossMixerFd, MIXER_READ(SOUND_MIXER_MIC), &vol) < 0) return;
        int left = vol & 0xFF;
        BOOL muted = (left == 0);
        int newVol = muted ? 80 : 0;
        int packed = (newVol << 8) | newVol;
        ioctl(_ossMixerFd, MIXER_WRITE(SOUND_MIXER_MIC), &packed);
#endif
    }
}

@end

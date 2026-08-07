/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "EvdevBrightnessKeySource.h"
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <fcntl.h>
#import <unistd.h>
#import <poll.h>
#import <errno.h>

#ifdef __linux__
#import <linux/input.h>
#import <sys/ioctl.h>

#define MAX_DEVICES 16

@interface EvdevBrightnessKeySource ()
{
    int _deviceFDs[MAX_DEVICES];
    int _deviceCount;
    void (^_handler)(int delta);
    NSThread *_monitorThread;
    volatile BOOL _shouldStop;
}
@end

@implementation EvdevBrightnessKeySource

- (instancetype)init
{
    self = [super init];
    if (self) {
        _deviceCount = 0;
        _shouldStop = NO;
        _handler = nil;
        _monitorThread = nil;

        for (int i = 0; i < MAX_DEVICES; i++) {
            _deviceFDs[i] = -1;
        }

        [self enumerateDevices];
    }
    return self;
}

- (void)enumerateDevices
{
    // Scan /proc/bus/input/devices for devices that support
    // EV_KEY and KEY_BRIGHTNESSUP / KEY_BRIGHTNESSDOWN.
    FILE *f = fopen("/proc/bus/input/devices", "r");
    if (!f) {
        // Fallback: try direct scan of /dev/input/event*
        [self enumerateByScanningDevInput];
        return;
    }

    // Parse section by section.  Each section is terminated by a blank line
    // (or end-of-file).  We track the event handler for the current section
    // and whether it has EV_KEY with brightness keys.
    char line[512];
    char eventNum[16] = {0};
    BOOL hasEVKey = NO;
    BOOL hasBrightnessKeys = NO;

    while (fgets(line, sizeof(line), f)) {
        // Remove trailing newline.
        size_t len = strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) {
            line[--len] = '\0';
        }

        if (len == 0) {
            // End of section -- open device if it matched.
            if (hasEVKey && hasBrightnessKeys && eventNum[0] != '\0') {
                [self openDevice:eventNum];
            }
            eventNum[0] = '\0';
            hasEVKey = NO;
            hasBrightnessKeys = NO;
            continue;
        }

        if (line[0] == 'I' && line[1] == ':') {
            // New device section, reset.
            eventNum[0] = '\0';
            hasEVKey = NO;
            hasBrightnessKeys = NO;
            continue;
        }

        // H: Handlers=...event3...
        if (line[0] == 'H' && line[1] == ':') {
            const char *p = strstr(line, "event");
            if (p) {
                p += 5; // skip "event"
                int i = 0;
                while (p[i] >= '0' && p[i] <= '9' && i < 15) {
                    eventNum[i] = p[i];
                    i++;
                }
                eventNum[i] = '\0';
            }
            continue;
        }

        // B: EV=b...  -- check EV_KEY bit (bit 1)
        if (line[0] == 'B' && line[1] == ':' &&
            (line[2] == ' ' || line[2] == '\t') &&
            line[3] == 'E' && line[4] == 'V' && line[5] == '=') {
            char *end = NULL;
            unsigned long long evBits = strtoull(line + 6, &end, 16);
            if ((evBits & (1ULL << EV_KEY)) != 0) {
                hasEVKey = YES;
            }
            continue;
        }

        // B: KEY=...  -- check bits 224 (KEY_BRIGHTNESSUP) and 225 (KEY_BRIGHTNESSDOWN).
        if (line[0] == 'B' && line[1] == ':' &&
            (line[2] == ' ' || line[2] == '\t') &&
            line[3] == 'K' && line[4] == 'E' && line[5] == 'Y' && line[6] == '=') {
            if (hasBrightnessKeys) continue; // already found
            hasBrightnessKeys = [self bitmapHasBrightnessKeys:line + 7];
            continue;
        }
    }

    // Last section (no trailing blank line).
    if (hasEVKey && hasBrightnessKeys && eventNum[0] != '\0') {
        [self openDevice:eventNum];
    }

    fclose(f);
}

- (BOOL)bitmapHasBrightnessKeys:(const char *)hexStr
{
    // The KEY bitmap in /proc/bus/input/devices is space-separated
    // hex words (64-bit on 64-bit platforms, 32-bit on 32-bit).
    // Bits are ordered from MSB to LSB in the printed output;
    // within each word bit 0 (LSB) corresponds to the lowest
    // bit for that word's range.
    //
    // We parse the hex string into a byte array and check
    // KEY_BRIGHTNESSUP (224) and KEY_BRIGHTNESSDOWN (225).

    // Copy and null-terminate so strtok is safe.
    char buf[2048];
    strncpy(buf, hexStr, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';

    // Count words and allocate the largest possible bit array.
    unsigned long bits[256] = {0};
    int totalBits = 0;

    // Parse from right to left: the last hex word contains the LSBs.
    char *tokens[64];
    int nTokens = 0;

    char *save = NULL;
    char *tok = strtok_r(buf, " ", &save);
    while (tok && nTokens < 64) {
        tokens[nTokens++] = tok;
        tok = strtok_r(NULL, " ", &save);
    }

    if (nTokens == 0) {
        return NO;
    }

    // Kernel prints the bitmap in unsigned long words (BITS_PER_LONG).
    int bitsPerWord = (int)(sizeof(unsigned long) * 8);

    for (int i = 0; i < nTokens; i++) {
        unsigned long long val = strtoull(tokens[i], NULL, 16);
        int wordStart = (nTokens - 1 - i) * bitsPerWord;

        int bmax = (sizeof(unsigned long long) * 8 < (size_t)bitsPerWord)
                 ? (int)(sizeof(unsigned long long) * 8) : bitsPerWord;
        for (int b = 0; b < bmax; b++) {
            if (val & (1ULL << b)) {
                int bitPos = wordStart + b;
                if (bitPos >= 0 && bitPos < 256 * (int)sizeof(unsigned long) * 8) {
                    bits[bitPos / (sizeof(unsigned long) * 8)] |=
                        (1UL << (bitPos % (sizeof(unsigned long) * 8)));
                    totalBits = MAX(totalBits, bitPos + 1);
                }
            }
        }
    }

    int upWord = KEY_BRIGHTNESSUP / (sizeof(unsigned long) * 8);
    int upBit = KEY_BRIGHTNESSUP % (sizeof(unsigned long) * 8);
    int downWord = KEY_BRIGHTNESSDOWN / (sizeof(unsigned long) * 8);
    int downBit = KEY_BRIGHTNESSDOWN % (sizeof(unsigned long) * 8);

    return (bits[upWord] & (1UL << upBit)) ||
           (bits[downWord] & (1UL << downBit));
}

- (void)enumerateByScanningDevInput
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:@"/dev/input" error:NULL];
    if (!contents) {
        return;
    }

    for (NSString *entry in contents) {
        if (![entry hasPrefix:@"event"]) {
            continue;
        }

        NSString *path = [NSString stringWithFormat:@"/dev/input/%@", entry];
        const char *cpath = [path UTF8String];

        int fd = open(cpath, O_RDONLY | O_NONBLOCK);
        if (fd < 0) {
            continue;
        }

        if ([self deviceHasBrightnessKeys:fd]) {
            if (_deviceCount < MAX_DEVICES) {
                _deviceFDs[_deviceCount++] = fd;
                NSDebugLLog(@"gwcomp", @"EvdevBrightnessKeySource: opened device %s", cpath);
            } else {
                close(fd);
            }
        } else {
            close(fd);
        }
    }
}

- (void)openDevice:(const char *)eventNum
{
    char path[64];
    snprintf(path, sizeof(path), "/dev/input/event%s", eventNum);

    int fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0) {
        return;
    }

    // Verify with ioctl -- the proc parsing can be architecture-sensitive.
    if (![self deviceHasBrightnessKeys:fd]) {
        close(fd);
        return;
    }

    if (_deviceCount < MAX_DEVICES) {
        _deviceFDs[_deviceCount++] = fd;
        NSDebugLLog(@"gwcomp", @"EvdevBrightnessKeySource: opened device %s", path);
    } else {
        close(fd);
    }
}

- (BOOL)deviceHasBrightnessKeys:(int)fd
{
    unsigned long evBits[EV_MAX / 32 + 1];
    memset(evBits, 0, sizeof(evBits));

    if (ioctl(fd, EVIOCGBIT(0, sizeof(evBits)), evBits) < 0) {
        return NO;
    }

    if (!(evBits[EV_KEY / 32] & (1UL << (EV_KEY % 32)))) {
        return NO;
    }

    unsigned long keyBits[KEY_MAX / 32 + 1];
    memset(keyBits, 0, sizeof(keyBits));

    if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keyBits)), keyBits) < 0) {
        return NO;
    }

    int upWord = KEY_BRIGHTNESSUP / 32;
    int upBit = KEY_BRIGHTNESSUP % 32;
    int downWord = KEY_BRIGHTNESSDOWN / 32;
    int downBit = KEY_BRIGHTNESSDOWN % 32;

    return (keyBits[upWord] & (1UL << upBit)) ||
           (keyBits[downWord] & (1UL << downBit));
}

- (void)start:(void (^)(int delta))handler
{
    if (!handler) {
        return;
    }

    _handler = [handler copy];

    if (_deviceCount == 0) {
        NSDebugLLog(@"gwcomp", @"EvdevBrightnessKeySource: no devices to monitor");
        return;
    }

    _shouldStop = NO;
    _monitorThread = [[NSThread alloc] initWithTarget:self
                                             selector:@selector(monitorThreadMain)
                                               object:nil];
    [_monitorThread start];

    NSDebugLLog(@"gwcomp", @"EvdevBrightnessKeySource: monitoring %d device(s)", _deviceCount);
}

- (void)monitorThreadMain
{
    @autoreleasepool {
        struct pollfd fds[MAX_DEVICES];
        int srcIdx[MAX_DEVICES];   /* fds[] entry -> _deviceFDs[] slot */
        int nfds = 0;

        for (int i = 0; i < _deviceCount; i++) {
            if (_deviceFDs[i] >= 0) {
                fds[nfds].fd = _deviceFDs[i];
                fds[nfds].events = POLLIN;
                fds[nfds].revents = 0;
                srcIdx[nfds] = i;
                nfds++;
            }
        }

        while (!_shouldStop) {
            int ret = poll(fds, nfds, 1000);

            if (ret < 0) {
                if (errno == EINTR) continue;
                NSDebugLLog(@"gwcomp", @"EvdevBrightnessKeySource: poll error: %s",
                      strerror(errno));
                break;
            }

            if (ret == 0 || _shouldStop) {
                continue;
            }

            for (int i = 0; i < nfds; i++) {
                if (fds[i].fd < 0) continue;
                /* A deleted/replaced input device leaves its fd permanently
                 * readable with POLLHUP/POLLERR, so poll() returns immediately
                 * and the loop busy-spins at 100% CPU.  Close the dead fd and
                 * stop polling the slot (poll() ignores entries with fd < 0). */
                if (fds[i].revents & (POLLHUP | POLLERR | POLLNVAL)) {
                    close(fds[i].fd);
                    _deviceFDs[srcIdx[i]] = -1;
                    fds[i].fd = -1;
                    continue;
                }
                if (!(fds[i].revents & POLLIN)) {
                    continue;
                }

                [self readEventsFromFD:fds[i].fd];
            }
        }
    }

    NSDebugLLog(@"gwcomp", @"EvdevBrightnessKeySource: monitor thread terminated");
}

- (void)readEventsFromFD:(int)fd
{
    struct input_event ev;

    while (1) {
        ssize_t n = read(fd, &ev, sizeof(ev));
        if (n == (ssize_t)sizeof(ev)) {
            if (ev.type == EV_KEY && ev.value == 1) {
                int delta = 0;
                if (ev.code == KEY_BRIGHTNESSUP) {
                    delta = 1;
                } else if (ev.code == KEY_BRIGHTNESSDOWN) {
                    delta = -1;
                }

                if (delta != 0 && _handler) {
                    [self performSelectorOnMainThread:@selector(_callHandlerWithDelta:)
                                           withObject:@(delta)
                                        waitUntilDone:NO];
                }
            }
        } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            break;
        } else {
            break;
        }
    }
}

- (void)_callHandlerWithDelta:(NSNumber *)deltaNum
{
    int delta = [deltaNum intValue];
    if (_handler) {
        _handler(delta);
    }
}

- (void)stop
{
    _shouldStop = YES;

    if (_monitorThread) {
        while (![_monitorThread isFinished]) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                     beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        _monitorThread = nil;
    }

    for (int i = 0; i < _deviceCount; i++) {
        if (_deviceFDs[i] >= 0) {
            close(_deviceFDs[i]);
            _deviceFDs[i] = -1;
        }
    }
    _deviceCount = 0;

    _handler = nil;
}

- (void)dealloc
{
    [self stop];
}

@end

#else

@implementation EvdevBrightnessKeySource

- (instancetype)init
{
    self = [super init];
    return self;
}

- (void)start:(void (^)(int delta))handler
{
    (void)handler;
    NSDebugLLog(@"gwcomp", @"EvdevBrightnessKeySource: not supported on this platform");
}

- (void)stop
{
}

@end

#endif

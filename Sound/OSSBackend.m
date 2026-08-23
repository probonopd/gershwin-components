/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * OSS Backend Implementation for FreeBSD
 *
 * Uses the Open Sound System (OSS) API for audio device control.
 * On FreeBSD, OSS provides audio device control through:
 *   - /dev/mixer for volume control (ioctl)
 *   - /dev/dsp for audio playback/capture
 *   - /dev/sndstat for device enumeration
 *   - sysctl hw.snd.default_unit for default device
 */

#import "OSSBackend.h"
#import "WavScale.h"
#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>
#import <sys/ioctl.h>
#import <sys/soundcard.h>
#import <fcntl.h>
#import <unistd.h>

@implementation OSSBackend

@synthesize delegate;

#pragma mark - Initialization

- (id)init
{
    self = [super init];
    if (self) {
        cachedOutputDevices = [[NSMutableArray alloc] init];
        cachedInputDevices = [[NSMutableArray alloc] init];
        cachedAlertSounds = [[NSMutableArray alloc] init];
        defaultOutput = nil;
        defaultInput = nil;
        currentAlert = nil;
        alertDevice = nil;
        cachedAlertVolume = 1.0;
        playUIEffects = YES;
        playVolumeChangeFeedback = YES;
        isMonitoringInputLevel = NO;
        inputLevelTimer = nil;
        mixerFd = -1;
        defaultUnit = 0;
        cachedOutputVolume = 75;
        cachedInputVolume = 75;
        isOutputMutedFlag = NO;
        isInputMutedFlag = NO;

        // Set up preferences file path
        NSString *home = NSHomeDirectory();
        defaultsFilePath = [[home stringByAppendingPathComponent:
                            @".config/gershwin/sound-defaults.plist"] retain];

        // Initialize
        [self enumerateDevices];
        [self loadAlertSounds];
        [self loadDefaultDevices];
    }
    return self;
}

- (void)dealloc
{
    [self stopInputLevelMonitoring];
    [self closeMixer];
    [cachedOutputDevices release];
    [cachedInputDevices release];
    [cachedAlertSounds release];
    [defaultOutput release];
    [defaultInput release];
    [currentAlert release];
    [alertDevice release];
    [defaultsFilePath release];
    [super dealloc];
}

#pragma mark - Mixer Control

- (BOOL)openMixer
{
    return [self openMixerForUnit:defaultUnit];
}

- (BOOL)openMixerForUnit:(int)unit
{
    [self closeMixer];

    NSString *mixerPath;
    if (unit == 0) {
        mixerPath = @"/dev/mixer";
    } else {
        mixerPath = [NSString stringWithFormat:@"/dev/mixer%d", unit];
    }

    mixerFd = open([mixerPath fileSystemRepresentation], O_RDWR);
    if (mixerFd < 0) {
        // Try read-only
        mixerFd = open([mixerPath fileSystemRepresentation], O_RDONLY);
    }

    if (mixerFd < 0) {
        NSDebugLLog(@"gwcomp", @"OSSBackend: Failed to open %@", mixerPath);
        return NO;
    }

    NSDebugLLog(@"gwcomp", @"OSSBackend: Opened %@ (fd=%d)", mixerPath, mixerFd);
    return YES;
}

- (void)closeMixer
{
    if (mixerFd >= 0) {
        close(mixerFd);
        mixerFd = -1;
    }
}

- (int)getMixerChannel:(int)channel
{
    if (mixerFd < 0) {
        if (![self openMixer]) {
            return -1;
        }
    }

    int vol = 0;
    int request = MIXER_READ(channel);

    if (ioctl(mixerFd, request, &vol) < 0) {
        NSDebugLLog(@"gwcomp", @"OSSBackend: Failed to read mixer channel %d", channel);
        return -1;
    }

    // OSS returns left in low byte, right in high byte (0-100 each)
    // Return average for mono value
    int left = vol & 0xFF;
    int right = (vol >> 8) & 0xFF;
    return (left + right) / 2;
}

- (BOOL)setMixerChannel:(int)channel value:(int)value
{
    if (mixerFd < 0) {
        if (![self openMixer]) {
            return NO;
        }
    }

    if (value < 0) value = 0;
    if (value > 100) value = 100;

    // Set both left and right channels to same value
    int vol = value | (value << 8);
    int request = MIXER_WRITE(channel);

    if (ioctl(mixerFd, request, &vol) < 0) {
        NSDebugLLog(@"gwcomp", @"OSSBackend: Failed to write mixer channel %d", channel);
        return NO;
    }

    NSDebugLLog(@"gwcomp", @"OSSBackend: Set mixer channel %d to %d", channel, value);
    return YES;
}

- (int)getMixerChannelForUnit:(int)unit channel:(int)channel
{
    NSString *mixerPath;
    if (unit == 0) {
        mixerPath = @"/dev/mixer";
    } else {
        mixerPath = [NSString stringWithFormat:@"/dev/mixer%d", unit];
    }

    int fd = open([mixerPath fileSystemRepresentation], O_RDONLY);
    if (fd < 0) {
        return -1;
    }

    int vol = 0;
    int request = MIXER_READ(channel);

    if (ioctl(fd, request, &vol) < 0) {
        close(fd);
        return -1;
    }

    close(fd);

    int left = vol & 0xFF;
    int right = (vol >> 8) & 0xFF;
    return (left + right) / 2;
}

- (BOOL)setMixerChannelForUnit:(int)unit channel:(int)channel value:(int)value
{
    NSString *mixerPath;
    if (unit == 0) {
        mixerPath = @"/dev/mixer";
    } else {
        mixerPath = [NSString stringWithFormat:@"/dev/mixer%d", unit];
    }

    int fd = open([mixerPath fileSystemRepresentation], O_RDWR);
    if (fd < 0) {
        return NO;
    }

    if (value < 0) value = 0;
    if (value > 100) value = 100;

    int vol = value | (value << 8);
    int request = MIXER_WRITE(channel);

    BOOL success = (ioctl(fd, request, &vol) >= 0);
    close(fd);

    return success;
}

- (int)getMixerDevMask
{
    if (mixerFd < 0) {
        if (![self openMixer]) {
            return 0;
        }
    }

    int mask = 0;
    if (ioctl(mixerFd, SOUND_MIXER_READ_DEVMASK, &mask) < 0) {
        return 0;
    }
    return mask;
}

- (int)getMixerRecMask
{
    if (mixerFd < 0) {
        if (![self openMixer]) {
            return 0;
        }
    }

    int mask = 0;
    if (ioctl(mixerFd, SOUND_MIXER_READ_RECMASK, &mask) < 0) {
        return 0;
    }
    return mask;
}

- (BOOL)setMixerRecMask:(int)mask
{
    if (mixerFd < 0) {
        if (![self openMixer]) {
            return NO;
        }
    }

    return (ioctl(mixerFd, SOUND_MIXER_WRITE_RECSRC, &mask) >= 0);
}

#pragma mark - SoundBackend Protocol - Identification

- (NSString *)backendName
{
    return @"OSS";
}

- (NSString *)backendVersion
{
    // Get OSS version via ioctl
    if (mixerFd < 0) {
        [self openMixer];
    }

    if (mixerFd >= 0) {
        int version = 0;
        if (ioctl(mixerFd, OSS_GETVERSION, &version) >= 0) {
            int major = (version >> 16) & 0xFF;
            int minor = (version >> 8) & 0xFF;
            int patch = version & 0xFF;
            return [NSString stringWithFormat:@"%d.%d.%d", major, minor, patch];
        }
    }

    return @"4.0";
}

- (BOOL)isAvailable
{
    // Check if /dev/mixer exists (FreeBSD OSS)
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:@"/dev/mixer"];
    if (!exists) {
        return NO;
    }

    // Try to open it
    int fd = open("/dev/mixer", O_RDONLY);
    if (fd < 0) {
        return NO;
    }
    close(fd);

    return YES;
}

#pragma mark - Device Enumeration

- (void)enumerateDevices
{
    [cachedOutputDevices removeAllObjects];
    [cachedInputDevices removeAllObjects];

    [self parseSndstat];

    // Get current default unit
    defaultUnit = [self getDefaultUnit];

    // Set default devices based on default unit
    for (AudioDevice *device in cachedOutputDevices) {
        if (device.cardIndex == defaultUnit) {
            device.isDefault = YES;
            [defaultOutput release];
            defaultOutput = [device retain];
        } else {
            device.isDefault = NO;
        }
    }

    for (AudioDevice *device in cachedInputDevices) {
        if (device.cardIndex == defaultUnit) {
            device.isDefault = YES;
            [defaultInput release];
            defaultInput = [device retain];
        } else {
            device.isDefault = NO;
        }
    }

    // If no default set, use first device
    if (!defaultOutput && [cachedOutputDevices count] > 0) {
        defaultOutput = [[cachedOutputDevices objectAtIndex:0] retain];
        defaultOutput.isDefault = YES;
    }

    if (!defaultInput && [cachedInputDevices count] > 0) {
        defaultInput = [[cachedInputDevices objectAtIndex:0] retain];
        defaultInput.isDefault = YES;
    }

    // Open mixer for default device
    if (defaultOutput) {
        [self openMixerForUnit:defaultOutput.cardIndex];
    } else {
        [self openMixer];
    }
}

- (void)parseSndstat
{
    // Read /dev/sndstat for device information
    // Note: /dev/sndstat is a device file, not a regular file, so we need to
    // use file handle to read it properly instead of stringWithContentsOfFile
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:@"/dev/sndstat"];
    if (!fh) {
        NSDebugLLog(@"gwcomp", @"OSSBackend: Failed to open /dev/sndstat");
        [self enumerateDevicesFromDevfs];
        return;
    }

    NSData *data = [fh readDataToEndOfFile];
    [fh closeFile];

    if (!data || [data length] == 0) {
        NSDebugLLog(@"gwcomp", @"OSSBackend: Failed to read data from /dev/sndstat");
        [self enumerateDevicesFromDevfs];
        return;
    }

    NSString *sndstat = [[[NSString alloc] initWithData:data
                                               encoding:NSUTF8StringEncoding] autorelease];
    if (!sndstat) {
        NSDebugLLog(@"gwcomp", @"OSSBackend: Failed to decode /dev/sndstat as UTF-8");
        [self enumerateDevicesFromDevfs];
        return;
    }

    NSDebugLLog(@"gwcomp", @"OSSBackend: Parsing /dev/sndstat:\n%@", sndstat);

    // Parse sndstat output
    // Format on FreeBSD:
    // Installed devices:
    // pcm0: <NVIDIA (0x00a6) (HDMI/DP 8ch)> (play)
    // pcm4: <Realtek ALC897 (Analog)> (play/rec) default

    NSArray *lines = [sndstat componentsSeparatedByString:@"\n"];
    BOOL inDeviceSection = NO;

    for (NSString *line in lines) {
        if ([line hasPrefix:@"Installed devices"] ||
            [line hasPrefix:@"pcm"]) {
            inDeviceSection = YES;
        }

        if (!inDeviceSection) continue;

        // Match pcmN: <description> (play/rec)
        if ([line hasPrefix:@"pcm"]) {
            NSScanner *scanner = [NSScanner scannerWithString:line];
            [scanner scanString:@"pcm" intoString:nil];

            int unitNum = 0;
            [scanner scanInt:&unitNum];

            // Get description between < and >
            NSString *description = nil;
            NSRange openAngle = [line rangeOfString:@"<"];
            NSRange closeAngle = [line rangeOfString:@">"];
            if (openAngle.location != NSNotFound &&
                closeAngle.location != NSNotFound &&
                closeAngle.location > openAngle.location) {
                description = [line substringWithRange:
                    NSMakeRange(openAngle.location + 1,
                               closeAngle.location - openAngle.location - 1)];
            }

            // If we couldn't extract a description, use a fallback with unit number
            if (!description || [description length] == 0) {
                description = [NSString stringWithFormat:@"Audio Device %d", unitNum];
            }

            // Check for play/rec capabilities
            BOOL canPlay = [line containsString:@"play"];
            BOOL canRec = [line containsString:@"rec"];
            BOOL isDefault = [line containsString:@"default"];

            // Skip HDMI/DisplayPort audio devices (consistent with Linux behavior)
            NSString *lowerDesc = [description lowercaseString];
            if ([lowerDesc containsString:@"hdmi"] ||
                [lowerDesc containsString:@"displayport"] ||
                [lowerDesc containsString:@"hdmi/dp"]) {
                NSDebugLLog(@"gwcomp", @"OSSBackend: Skipping HDMI/DP device pcm%d: '%@'", unitNum, description);
                continue;
            }

            NSDebugLLog(@"gwcomp", @"OSSBackend: Found pcm%d: '%@' (play=%d, rec=%d, default=%d)",
                  unitNum, description, canPlay, canRec, isDefault);

            // Create output device if it can play
            if (canPlay) {
                AudioDevice *device = [[AudioDevice alloc] init];
                device.identifier = [NSString stringWithFormat:@"pcm%d", unitNum];
                device.name = [NSString stringWithFormat:@"pcm%d: %@", unitNum, description];
                device.displayName = description;
                device.cardName = description;
                device.cardIndex = unitNum;
                device.deviceIndex = 0;
                device.direction = AudioDeviceDirectionOutput;
                device.state = AudioDeviceStateAvailable;
                device.isDefault = isDefault;
                device.type = [self guessDeviceType:device.identifier
                                        description:description];

                // Get volume control info
                int vol = [self getMixerChannelForUnit:unitNum channel:SOUND_MIXER_PCM];
                if (vol >= 0) {
                    AudioControl *volControl = [[AudioControl alloc] init];
                    volControl.identifier = @"pcm";
                    volControl.name = @"PCM";
                    volControl.value = vol / 100.0;
                    volControl.hasMuteControl = YES;
                    volControl.isMuted = (vol == 0);
                    device.volumeControl = volControl;
                    [volControl release];
                }

                [cachedOutputDevices addObject:device];
                [device release];
            }

            // Create input device if it can record
            if (canRec) {
                AudioDevice *device = [[AudioDevice alloc] init];
                device.identifier = [NSString stringWithFormat:@"pcm%d", unitNum];
                device.name = [NSString stringWithFormat:@"pcm%d: %@", unitNum, description];
                device.displayName = description;
                device.cardName = description;
                device.cardIndex = unitNum;
                device.deviceIndex = 0;
                device.direction = AudioDeviceDirectionInput;
                device.state = AudioDeviceStateAvailable;
                device.isDefault = isDefault;
                device.type = AudioDeviceTypeBuiltInMicrophone;

                // Get input volume
                int vol = [self getMixerChannelForUnit:unitNum channel:SOUND_MIXER_MIC];
                if (vol < 0) {
                    vol = [self getMixerChannelForUnit:unitNum channel:SOUND_MIXER_RECLEV];
                }
                if (vol >= 0) {
                    AudioControl *volControl = [[AudioControl alloc] init];
                    volControl.identifier = @"mic";
                    volControl.name = @"Mic";
                    volControl.value = vol / 100.0;
                    volControl.hasMuteControl = YES;
                    volControl.isMuted = (vol == 0);
                    device.volumeControl = volControl;
                    [volControl release];
                }

                [cachedInputDevices addObject:device];
                [device release];
            }
        }
    }
}

- (void)enumerateDevicesFromDevfs
{
    // Fallback: scan /dev for dsp and mixer devices
    NSFileManager *fm = [NSFileManager defaultManager];

    for (int i = 0; i < 16; i++) {
        NSString *dspPath;
        NSString *mixerPath;

        if (i == 0) {
            dspPath = @"/dev/dsp";
            mixerPath = @"/dev/mixer";
        } else {
            dspPath = [NSString stringWithFormat:@"/dev/dsp%d", i];
            mixerPath = [NSString stringWithFormat:@"/dev/mixer%d", i];
        }

        if ([fm fileExistsAtPath:dspPath] || [fm fileExistsAtPath:mixerPath]) {
            NSDebugLLog(@"gwcomp", @"OSSBackend: Found device at unit %d", i);

            // Create output device
            AudioDevice *outDevice = [[AudioDevice alloc] init];
            outDevice.identifier = [NSString stringWithFormat:@"pcm%d", i];
            outDevice.name = outDevice.identifier;
            outDevice.displayName = [NSString stringWithFormat:@"Audio Device %d", i];
            outDevice.cardName = outDevice.displayName;
            outDevice.cardIndex = i;
            outDevice.deviceIndex = 0;
            outDevice.direction = AudioDeviceDirectionOutput;
            outDevice.state = AudioDeviceStateAvailable;
            outDevice.type = AudioDeviceTypeBuiltInSpeaker;

            [cachedOutputDevices addObject:outDevice];
            [outDevice release];

            // Create input device
            AudioDevice *inDevice = [[AudioDevice alloc] init];
            inDevice.identifier = [NSString stringWithFormat:@"pcm%d", i];
            inDevice.name = inDevice.identifier;
            inDevice.displayName = [NSString stringWithFormat:@"Audio Device %d", i];
            inDevice.cardName = inDevice.displayName;
            inDevice.cardIndex = i;
            inDevice.deviceIndex = 0;
            inDevice.direction = AudioDeviceDirectionInput;
            inDevice.state = AudioDeviceStateAvailable;
            inDevice.type = AudioDeviceTypeBuiltInMicrophone;

            [cachedInputDevices addObject:inDevice];
            [inDevice release];
        }
    }
}

- (AudioDeviceType)guessDeviceType:(NSString *)name description:(NSString *)desc
{
    NSString *lower = [desc lowercaseString];

    if ([lower containsString:@"usb"]) {
        return AudioDeviceTypeUSBAudio;
    }
    if ([lower containsString:@"hdmi"]) {
        return AudioDeviceTypeHDMI;
    }
    if ([lower containsString:@"displayport"] || [lower containsString:@"dp"]) {
        return AudioDeviceTypeDisplayPort;
    }
    if ([lower containsString:@"bluetooth"] || [lower containsString:@"bt"]) {
        return AudioDeviceTypeBluetooth;
    }
    if ([lower containsString:@"headphone"]) {
        return AudioDeviceTypeHeadphones;
    }
    if ([lower containsString:@"spdif"] || [lower containsString:@"digital"]) {
        return AudioDeviceTypeSPDIF;
    }

    return AudioDeviceTypeBuiltInSpeaker;
}

#pragma mark - Default Device Management

- (int)getDefaultUnit
{
    // Use sysctl to get hw.snd.default_unit
    NSString *output = [self runCommand:@"/sbin/sysctl"
                          withArguments:@[@"-n", @"hw.snd.default_unit"]];

    if (output) {
        return [output intValue];
    }

    return 0;
}

- (BOOL)setDefaultUnit:(int)unit
{
    NSDebugLLog(@"gwcomp", @"OSSBackend: Setting default unit to %d", unit);

    // Use sysctl to set hw.snd.default_unit
    // This typically requires root privileges
    NSString *value = [NSString stringWithFormat:@"hw.snd.default_unit=%d", unit];
    NSString *output = [self runCommand:@"/sbin/sysctl"
                          withArguments:@[value]];

    if (output && [output containsString:@"default_unit"]) {
        defaultUnit = unit;
        [self openMixerForUnit:unit];
        NSDebugLLog(@"gwcomp", @"OSSBackend: Successfully set default unit to %d", unit);
        return YES;
    }

    NSDebugLLog(@"gwcomp", @"OSSBackend: Failed to set default unit (may require root)");
    return NO;
}

- (void)loadDefaultDevices
{
    // Load saved preferences
    NSString *configDir = [defaultsFilePath stringByDeletingLastPathComponent];

    if (![[NSFileManager defaultManager] fileExistsAtPath:configDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:configDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }

    if ([[NSFileManager defaultManager] fileExistsAtPath:defaultsFilePath]) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:defaultsFilePath];
        if (prefs) {
            NSString *outputId = [prefs objectForKey:@"defaultOutput"];
            NSString *inputId = [prefs objectForKey:@"defaultInput"];
            NSString *alertId = [prefs objectForKey:@"alertDevice"];
            NSString *alertSoundName = [prefs objectForKey:@"alertSound"];
            NSNumber *alertVol = [prefs objectForKey:@"alertVolume"];
            NSNumber *uiEffects = [prefs objectForKey:@"playUIEffects"];
            NSNumber *volFeedback = [prefs objectForKey:@"playVolumeFeedback"];

            if (outputId) {
                AudioDevice *dev = [self outputDeviceWithIdentifier:outputId];
                if (dev) {
                    [self setDefaultOutputDevice:dev];
                }
            }

            if (inputId) {
                AudioDevice *dev = [self inputDeviceWithIdentifier:inputId];
                if (dev) {
                    [self setDefaultInputDevice:dev];
                }
            }

            if (alertId) {
                alertDevice = [[self outputDeviceWithIdentifier:alertId] retain];
            }

            if (alertSoundName) {
                for (AlertSound *sound in cachedAlertSounds) {
                    if ([sound.name isEqualToString:alertSoundName]) {
                        [currentAlert release];
                        currentAlert = [sound retain];
                        break;
                    }
                }
            }

            if (alertVol) {
                cachedAlertVolume = [alertVol floatValue];
            }

            if (uiEffects) {
                playUIEffects = [uiEffects boolValue];
            }

            if (volFeedback) {
                playVolumeChangeFeedback = [volFeedback boolValue];
            }
        }
    }
}

- (BOOL)savePreferences
{
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];

    if (defaultOutput) {
        [prefs setObject:defaultOutput.identifier forKey:@"defaultOutput"];
    }
    if (defaultInput) {
        [prefs setObject:defaultInput.identifier forKey:@"defaultInput"];
    }
    if (alertDevice) {
        [prefs setObject:alertDevice.identifier forKey:@"alertDevice"];
    }
    if (currentAlert) {
        [prefs setObject:currentAlert.name forKey:@"alertSound"];
    }
    [prefs setObject:@(cachedAlertVolume) forKey:@"alertVolume"];
    [prefs setObject:@(playUIEffects) forKey:@"playUIEffects"];
    [prefs setObject:@(playVolumeChangeFeedback) forKey:@"playVolumeFeedback"];

    NSString *configDir = [defaultsFilePath stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] fileExistsAtPath:configDir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:configDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }

    return [prefs writeToFile:defaultsFilePath atomically:YES];
}

#pragma mark - Output Device Management

- (NSArray *)outputDevices
{
    return [[cachedOutputDevices copy] autorelease];
}

- (AudioDevice *)defaultOutputDevice
{
    return [[defaultOutput retain] autorelease];
}

- (BOOL)setDefaultOutputDevice:(AudioDevice *)device
{
    NSDebugLLog(@"gwcomp", @"OSSBackend: setDefaultOutputDevice: %@", device ? device.name : @"(nil)");

    if (!device) {
        return NO;
    }

    // Update cached default
    for (AudioDevice *dev in cachedOutputDevices) {
        dev.isDefault = [dev.identifier isEqualToString:device.identifier];
        if (dev.isDefault) {
            [defaultOutput release];
            defaultOutput = [dev retain];
        }
    }

    // Set system default via sysctl
    BOOL success = [self setDefaultUnit:device.cardIndex];

    // Save preferences
    [self savePreferences];

    return success;
}

- (AudioDevice *)outputDeviceWithIdentifier:(NSString *)identifier
{
    for (AudioDevice *device in cachedOutputDevices) {
        if ([device.identifier isEqualToString:identifier]) {
            return device;
        }
    }
    return nil;
}

#pragma mark - Input Device Management

- (NSArray *)inputDevices
{
    return [[cachedInputDevices copy] autorelease];
}

- (AudioDevice *)defaultInputDevice
{
    return [[defaultInput retain] autorelease];
}

- (BOOL)setDefaultInputDevice:(AudioDevice *)device
{
    NSDebugLLog(@"gwcomp", @"OSSBackend: setDefaultInputDevice: %@", device ? device.name : @"(nil)");

    if (!device) {
        return NO;
    }

    for (AudioDevice *dev in cachedInputDevices) {
        dev.isDefault = [dev.identifier isEqualToString:device.identifier];
        if (dev.isDefault) {
            [defaultInput release];
            defaultInput = [dev retain];
        }
    }

    // Note: OSS doesn't have a separate input device selector
    // Recording source is controlled via mixer

    [self savePreferences];
    return YES;
}

- (AudioDevice *)inputDeviceWithIdentifier:(NSString *)identifier
{
    for (AudioDevice *device in cachedInputDevices) {
        if ([device.identifier isEqualToString:identifier]) {
            return device;
        }
    }
    return nil;
}

#pragma mark - Master Volume Control

- (float)outputVolume
{
    if (!defaultOutput) return 0.0;

    // Try PCM first, then master volume
    int vol = [self getMixerChannel:SOUND_MIXER_PCM];
    if (vol < 0) {
        vol = [self getMixerChannel:SOUND_MIXER_VOLUME];
    }

    if (vol >= 0) {
        return vol / 100.0;
    }

    return defaultOutput.volumeControl ? defaultOutput.volumeControl.value : 0.0;
}

- (BOOL)setOutputVolume:(float)volume
{
    NSDebugLLog(@"gwcomp", @"OSSBackend: setOutputVolume: %.2f", volume);

    if (volume < 0.0) volume = 0.0;
    if (volume > 1.0) volume = 1.0;

    int percent = (int)(volume * 100);

    // Try to set PCM first, then master
    BOOL success = [self setMixerChannel:SOUND_MIXER_PCM value:percent];
    if (!success) {
        success = [self setMixerChannel:SOUND_MIXER_VOLUME value:percent];
    }

    if (success) {
        cachedOutputVolume = percent;
        isOutputMutedFlag = NO;

        if (defaultOutput.volumeControl) {
            defaultOutput.volumeControl.value = volume;
            defaultOutput.volumeControl.isMuted = NO;
        }

        // Play feedback if enabled
        if (playVolumeChangeFeedback) {
            [self playVolumeFeedback];
        }
    }

    return success;
}

- (BOOL)isOutputMuted
{
    if (isOutputMutedFlag) {
        return YES;
    }

    // Check if volume is 0
    int vol = [self getMixerChannel:SOUND_MIXER_PCM];
    if (vol < 0) {
        vol = [self getMixerChannel:SOUND_MIXER_VOLUME];
    }

    return (vol == 0);
}

- (BOOL)setOutputMuted:(BOOL)muted
{
    NSDebugLLog(@"gwcomp", @"OSSBackend: setOutputMuted: %@", muted ? @"YES" : @"NO");

    if (muted) {
        // Save current volume and set to 0
        int currentVol = [self getMixerChannel:SOUND_MIXER_PCM];
        if (currentVol < 0) {
            currentVol = [self getMixerChannel:SOUND_MIXER_VOLUME];
        }
        if (currentVol > 0) {
            cachedOutputVolume = currentVol;
        }

        BOOL success = [self setMixerChannel:SOUND_MIXER_PCM value:0];
        if (!success) {
            success = [self setMixerChannel:SOUND_MIXER_VOLUME value:0];
        }

        if (success) {
            isOutputMutedFlag = YES;
            if (defaultOutput.volumeControl) {
                defaultOutput.volumeControl.isMuted = YES;
            }
        }
        return success;
    } else {
        // Restore saved volume
        int restoreVol = cachedOutputVolume > 0 ? cachedOutputVolume : 75;

        BOOL success = [self setMixerChannel:SOUND_MIXER_PCM value:restoreVol];
        if (!success) {
            success = [self setMixerChannel:SOUND_MIXER_VOLUME value:restoreVol];
        }

        if (success) {
            isOutputMutedFlag = NO;
            if (defaultOutput.volumeControl) {
                defaultOutput.volumeControl.isMuted = NO;
                defaultOutput.volumeControl.value = restoreVol / 100.0;
            }
        }
        return success;
    }
}

- (float)outputBalance
{
    // OSS uses left/right in a single ioctl call
    // We'd need to read raw left/right values to compute balance
    // For now, return center
    return 0.5;
}

- (BOOL)setOutputBalance:(float)balance
{
    NSDebugLLog(@"gwcomp", @"OSSBackend: setOutputBalance: %.2f", balance);

    if (balance < 0.0) balance = 0.0;
    if (balance > 1.0) balance = 1.0;

    if (mixerFd < 0) {
        if (![self openMixer]) {
            return NO;
        }
    }

    // Get current volume
    int vol = 0;
    if (ioctl(mixerFd, MIXER_READ(SOUND_MIXER_PCM), &vol) < 0) {
        if (ioctl(mixerFd, MIXER_READ(SOUND_MIXER_VOLUME), &vol) < 0) {
            return NO;
        }
    }

    int left = vol & 0xFF;
    int right = (vol >> 8) & 0xFF;
    int avg = (left + right) / 2;

    // Calculate new left/right based on balance
    // balance 0.0 = full left, 0.5 = center, 1.0 = full right
    int newLeft, newRight;
    if (balance < 0.5) {
        newLeft = avg;
        newRight = (int)(avg * (balance * 2));
    } else if (balance > 0.5) {
        newLeft = (int)(avg * ((1.0 - balance) * 2));
        newRight = avg;
    } else {
        newLeft = avg;
        newRight = avg;
    }

    int newVol = newLeft | (newRight << 8);

    BOOL success = (ioctl(mixerFd, MIXER_WRITE(SOUND_MIXER_PCM), &newVol) >= 0);
    if (!success) {
        success = (ioctl(mixerFd, MIXER_WRITE(SOUND_MIXER_VOLUME), &newVol) >= 0);
    }

    return success;
}

#pragma mark - Input Volume Control

- (float)inputVolume
{
    if (!defaultInput) return 0.0;

    // Try mic, then reclev, then igain
    int vol = [self getMixerChannelForUnit:defaultInput.cardIndex
                                   channel:SOUND_MIXER_MIC];
    if (vol < 0) {
        vol = [self getMixerChannelForUnit:defaultInput.cardIndex
                                   channel:SOUND_MIXER_RECLEV];
    }
    if (vol < 0) {
        vol = [self getMixerChannelForUnit:defaultInput.cardIndex
                                   channel:SOUND_MIXER_IGAIN];
    }

    if (vol >= 0) {
        return vol / 100.0;
    }

    return defaultInput.volumeControl ? defaultInput.volumeControl.value : 0.0;
}

- (BOOL)setInputVolume:(float)volume
{
    NSDebugLLog(@"gwcomp", @"OSSBackend: setInputVolume: %.2f", volume);

    if (!defaultInput) return NO;

    if (volume < 0.0) volume = 0.0;
    if (volume > 1.0) volume = 1.0;

    int percent = (int)(volume * 100);

    // Try mic, then reclev, then igain
    BOOL success = [self setMixerChannelForUnit:defaultInput.cardIndex
                                        channel:SOUND_MIXER_MIC
                                          value:percent];
    if (!success) {
        success = [self setMixerChannelForUnit:defaultInput.cardIndex
                                       channel:SOUND_MIXER_RECLEV
                                         value:percent];
    }
    if (!success) {
        success = [self setMixerChannelForUnit:defaultInput.cardIndex
                                       channel:SOUND_MIXER_IGAIN
                                         value:percent];
    }

    if (success) {
        cachedInputVolume = percent;
        isInputMutedFlag = NO;

        if (defaultInput.volumeControl) {
            defaultInput.volumeControl.value = volume;
            defaultInput.volumeControl.isMuted = NO;
        }
    }

    return success;
}

- (BOOL)isInputMuted
{
    if (isInputMutedFlag) {
        return YES;
    }

    int vol = [self getMixerChannelForUnit:defaultInput.cardIndex
                                   channel:SOUND_MIXER_MIC];
    if (vol < 0) {
        vol = [self getMixerChannelForUnit:defaultInput.cardIndex
                                   channel:SOUND_MIXER_RECLEV];
    }

    return (vol == 0);
}

- (BOOL)setInputMuted:(BOOL)muted
{
    NSDebugLLog(@"gwcomp", @"OSSBackend: setInputMuted: %@", muted ? @"YES" : @"NO");

    if (!defaultInput) return NO;

    if (muted) {
        int currentVol = [self getMixerChannelForUnit:defaultInput.cardIndex
                                              channel:SOUND_MIXER_MIC];
        if (currentVol < 0) {
            currentVol = [self getMixerChannelForUnit:defaultInput.cardIndex
                                              channel:SOUND_MIXER_RECLEV];
        }
        if (currentVol > 0) {
            cachedInputVolume = currentVol;
        }

        BOOL success = [self setMixerChannelForUnit:defaultInput.cardIndex
                                            channel:SOUND_MIXER_MIC
                                              value:0];
        if (!success) {
            success = [self setMixerChannelForUnit:defaultInput.cardIndex
                                           channel:SOUND_MIXER_RECLEV
                                             value:0];
        }

        if (success) {
            isInputMutedFlag = YES;
            if (defaultInput.volumeControl) {
                defaultInput.volumeControl.isMuted = YES;
            }
        }
        return success;
    } else {
        int restoreVol = cachedInputVolume > 0 ? cachedInputVolume : 75;

        BOOL success = [self setMixerChannelForUnit:defaultInput.cardIndex
                                            channel:SOUND_MIXER_MIC
                                              value:restoreVol];
        if (!success) {
            success = [self setMixerChannelForUnit:defaultInput.cardIndex
                                           channel:SOUND_MIXER_RECLEV
                                             value:restoreVol];
        }

        if (success) {
            isInputMutedFlag = NO;
            if (defaultInput.volumeControl) {
                defaultInput.volumeControl.isMuted = NO;
                defaultInput.volumeControl.value = restoreVol / 100.0;
            }
        }
        return success;
    }
}

#pragma mark - Input Level Monitoring

- (float)inputLevel
{
    return [self measureInputLevel];
}

- (BOOL)startInputLevelMonitoring
{
    if (isMonitoringInputLevel) return YES;

    isMonitoringInputLevel = YES;
    inputLevelTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                             dispatch_get_main_queue());
    dispatch_source_set_timer(inputLevelTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                              100 * NSEC_PER_MSEC, 0);
    dispatch_source_set_event_handler(inputLevelTimer, ^{
        [self inputLevelTimerFired];
    });
    dispatch_resume(inputLevelTimer);

    return YES;
}

- (BOOL)stopInputLevelMonitoring
{
    if (!isMonitoringInputLevel) return YES;

    isMonitoringInputLevel = NO;
    if (inputLevelTimer) {
        dispatch_source_cancel(inputLevelTimer);
        dispatch_release(inputLevelTimer);
        inputLevelTimer = nil;
    }

    return YES;
}

- (void)inputLevelTimerFired
{
    float level = [self measureInputLevel];

    if ([delegate respondsToSelector:@selector(soundBackend:inputLevelDidChange:)]) {
        [delegate soundBackend:self inputLevelDidChange:level];
    }
}

- (float)measureInputLevel
{
    // A proper implementation would open /dev/dsp and read PCM samples
    // to calculate RMS level. For now, return 0.
    return 0.0;
}

#pragma mark - Device-Specific Volume Control

- (float)volumeForDevice:(AudioDevice *)device
{
    if (!device) return 0.0;

    int vol = [self getMixerChannelForUnit:device.cardIndex channel:SOUND_MIXER_PCM];
    if (vol < 0) {
        vol = [self getMixerChannelForUnit:device.cardIndex channel:SOUND_MIXER_VOLUME];
    }

    if (vol >= 0) {
        return vol / 100.0;
    }

    return device.volumeControl ? device.volumeControl.value : 0.0;
}

- (BOOL)setVolume:(float)volume forDevice:(AudioDevice *)device
{
    if (!device) return NO;

    if (volume < 0.0) volume = 0.0;
    if (volume > 1.0) volume = 1.0;

    int percent = (int)(volume * 100);

    BOOL success = [self setMixerChannelForUnit:device.cardIndex
                                        channel:SOUND_MIXER_PCM
                                          value:percent];
    if (!success) {
        success = [self setMixerChannelForUnit:device.cardIndex
                                       channel:SOUND_MIXER_VOLUME
                                         value:percent];
    }

    if (success && device.volumeControl) {
        device.volumeControl.value = volume;
    }

    return success;
}

- (BOOL)isMutedForDevice:(AudioDevice *)device
{
    if (!device) return NO;
    return device.volumeControl ? device.volumeControl.isMuted : NO;
}

- (BOOL)setMuted:(BOOL)muted forDevice:(AudioDevice *)device
{
    if (!device) return NO;

    if (muted) {
        return [self setVolume:0.0 forDevice:device];
    } else {
        float vol = device.volumeControl ? device.volumeControl.value : 0.75;
        if (vol < 0.1) vol = 0.75;
        return [self setVolume:vol forDevice:device];
    }
}

#pragma mark - Port Selection

- (BOOL)setActivePort:(AudioPort *)port forDevice:(AudioDevice *)device
{
    if (!port || !device) return NO;

    // Update cached state
    for (AudioPort *p in device.ports) {
        p.isActive = [p.identifier isEqualToString:port.identifier];
    }
    device.activePort = port;

    // OSS doesn't have a standard port selection mechanism
    return YES;
}

#pragma mark - Alert Sounds

- (void)loadAlertSounds
{
    [cachedAlertSounds removeAllObjects];

    // Only search Library/Sounds directories (system, local, network, and user)
    NSMutableArray *searchDirs = [NSMutableArray array];
    [searchDirs addObject:@"/System/Library/Sounds"];
    [searchDirs addObject:@"/Local/Library/Sounds"];
    [searchDirs addObject:@"/Network/Library/Sounds"];
    [searchDirs addObject:[self userAlertSoundDirectory]];

    NSArray *extensions = @[@"aiff", @"aif", @"wav", @"au", @"snd"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *userDir = [self userAlertSoundDirectory];

    for (NSString *dir in searchDirs) {
        if (![fm fileExistsAtPath:dir]) continue;

        // Use contentsOfDirectoryAtPath for direct file listing on FreeBSD
        // (FreeBSD typically has sounds directly in the directory)
        NSError *error = nil;
        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:&error];

        for (NSString *file in files) {
            NSString *ext = [[file pathExtension] lowercaseString];
            if ([extensions containsObject:ext]) {
                // "Glass" is reserved for progress bars reaching 100% and must
                // never be selectable as an alert sound
                if ([[file stringByDeletingPathExtension]
                        isEqualToString:@"Glass"]) continue;

                AlertSound *sound = [[AlertSound alloc] init];
                sound.name = [file stringByDeletingPathExtension];
                sound.displayName = sound.name;
                sound.path = [dir stringByAppendingPathComponent:file];
                sound.isSystemSound = ![dir isEqualToString:userDir];

                [cachedAlertSounds addObject:sound];
                [sound release];
            }
        }
    }

    // Sort by name
    [cachedAlertSounds sortUsingComparator:^NSComparisonResult(AlertSound *a, AlertSound *b) {
        return [a.displayName compare:b.displayName];
    }];

    NSDebugLLog(@"gwcomp", @"OSSBackend: loadAlertSounds: found %lu alert sounds",
          (unsigned long)[cachedAlertSounds count]);

    // Set first sound as current if none selected
    if (!currentAlert && [cachedAlertSounds count] > 0) {
        currentAlert = [[cachedAlertSounds objectAtIndex:0] retain];
    }
}

- (NSString *)alertSoundDirectory
{
    return @"/System/Library/Sounds";
}

- (NSString *)userAlertSoundDirectory
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Sounds"];
}

- (NSArray *)availableAlertSounds
{
    return [[cachedAlertSounds copy] autorelease];
}

- (AlertSound *)currentAlertSound
{
    return [[currentAlert retain] autorelease];
}

- (BOOL)setCurrentAlertSound:(AlertSound *)sound
{
    if (!sound) return NO;

    [currentAlert release];
    currentAlert = [sound retain];

    [self savePreferences];
    return YES;
}

- (float)alertVolume
{
    return cachedAlertVolume;
}

- (BOOL)setAlertVolume:(float)volume
{
    if (volume < 0.0) volume = 0.0;
    if (volume > 1.0) volume = 1.0;

    cachedAlertVolume = volume;
    [self savePreferences];

    return YES;
}

- (BOOL)playAlertSound:(AlertSound *)sound
{
    NSDebugLLog(@"gwcomp", @"OSSBackend: playAlertSound: %@", sound ? sound.name : @"(nil)");

    if (!sound || !sound.path) {
        NSBeep();
        return YES;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:sound.path]) {
        NSBeep();
        return YES;
    }

    // Determine which unit to use
    int unit = alertDevice ? alertDevice.cardIndex : defaultUnit;

    // --- Scale the sound file itself so only the alert plays quieter ---
    NSString *playPath = sound.path;
    NSString *tempPath = nil;
    if (cachedAlertVolume < 0.99) {
        NSData *wav = [NSData dataWithContentsOfFile:sound.path];
        NSData *quiet = wav ? SoundScaleWavData(wav, cachedAlertVolume) : nil;
        if (quiet) {
            tempPath = [NSTemporaryDirectory()
                        stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"gs-alert-%d.wav", getpid()]];
            if ([quiet writeToFile:tempPath atomically:YES]) {
                playPath = tempPath;
            }
        }
    }

    BOOL success = [self playSoundFile:playPath onUnit:unit];

    if (tempPath) {
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:NULL];
    }

    return success;
}

- (BOOL)playSoundFile:(NSString *)path onUnit:(int)unit
{
    // Use audioplay if available, otherwise fall back to cat > /dev/dsp
    NSString *audioplayPath = nil;
    NSArray *searchPaths = @[@"/usr/bin/audioplay", @"/usr/local/bin/audioplay",
                             @"/usr/bin/paplay", @"/usr/local/bin/paplay"];

    for (NSString *p in searchPaths) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) {
            audioplayPath = p;
            break;
        }
    }

    NSTask *task = [[NSTask alloc] init];

    if (audioplayPath) {
        [task setLaunchPath:audioplayPath];
        [task setArguments:@[path]];
    } else {
        // Use shell to pipe file to DSP device
        NSString *dspPath = (unit == 0) ? @"/dev/dsp" :
                            [NSString stringWithFormat:@"/dev/dsp%d", unit];

        [task setLaunchPath:@"/bin/sh"];
        [task setArguments:@[@"-c",
            [NSString stringWithFormat:@"cat '%@' > %@", path, dspPath]]];
    }

    BOOL success = YES;
    @try {
        [task launch];
        [task waitUntilExit];
        NSDebugLLog(@"gwcomp", @"OSSBackend: Played sound: %@", path);
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"OSSBackend: Failed to play sound: %@", e);
        success = NO;
    }
    [task release];

    if (!success) {
        NSBeep();
    }
    return success;
}

- (AudioDevice *)alertSoundDevice
{
    return alertDevice ?: defaultOutput;
}

- (BOOL)setAlertSoundDevice:(AudioDevice *)device
{
    [alertDevice release];
    alertDevice = [device retain];
    [self savePreferences];
    return YES;
}

#pragma mark - Sound Effects Settings

- (BOOL)playUserInterfaceSoundEffects
{
    return playUIEffects;
}

- (BOOL)setPlayUserInterfaceSoundEffects:(BOOL)play
{
    playUIEffects = play;
    [self savePreferences];
    return YES;
}

- (BOOL)playFeedbackWhenVolumeIsChanged
{
    return playVolumeChangeFeedback;
}

- (BOOL)setPlayFeedbackWhenVolumeIsChanged:(BOOL)play
{
    playVolumeChangeFeedback = play;
    [self savePreferences];
    return YES;
}

- (void)playVolumeFeedback
{
    if (currentAlert && currentAlert.path) {
        [self playAlertSound:currentAlert];
    } else {
        NSBeep();
    }
}

#pragma mark - Immediate Device Switching

- (BOOL)forceImmediateOutputDeviceSwitch:(AudioDevice *)device
{
    if (!device) {
        NSDebugLLog(@"gwcomp", @"OSSBackend: forceImmediateOutputDeviceSwitch: FAILED - device is nil");
        return NO;
    }

    NSDebugLLog(@"gwcomp", @"OSSBackend: forceImmediateOutputDeviceSwitch: %@ (unit %d)",
          device.name, device.cardIndex);

    // Set as default device
    BOOL success = [self setDefaultOutputDevice:device];

    if (success) {
        // Unmute the device
        [self setMixerChannelForUnit:device.cardIndex
                             channel:SOUND_MIXER_PCM
                               value:cachedOutputVolume > 0 ? cachedOutputVolume : 75];
    }

    return success;
}

- (BOOL)forceImmediateInputDeviceSwitch:(AudioDevice *)device
{
    if (!device) {
        NSDebugLLog(@"gwcomp", @"OSSBackend: forceImmediateInputDeviceSwitch: FAILED - device is nil");
        return NO;
    }

    NSDebugLLog(@"gwcomp", @"OSSBackend: forceImmediateInputDeviceSwitch: %@ (unit %d)",
          device.name, device.cardIndex);

    return [self setDefaultInputDevice:device];
}

#pragma mark - Refresh

- (void)refresh
{
    [self enumerateDevices];

    if ([delegate respondsToSelector:@selector(soundBackend:didUpdateOutputDevices:)]) {
        [delegate soundBackend:self didUpdateOutputDevices:cachedOutputDevices];
    }

    if ([delegate respondsToSelector:@selector(soundBackend:didUpdateInputDevices:)]) {
        [delegate soundBackend:self didUpdateInputDevices:cachedInputDevices];
    }
}

#pragma mark - Helper Methods

- (NSString *)runCommand:(NSString *)command withArguments:(NSArray *)args
{
    if (!command) return nil;

    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];

    [task setLaunchPath:command];
    [task setArguments:args];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSPipe pipe]];

    // Force C locale for consistent tool output
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"C" forKey:@"LC_ALL"];
    [task setEnvironment:env];
    [env release];

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"OSSBackend: Failed to run command %@: %@", command, e);
        [task release];
        return nil;
    }

    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[[NSString alloc] initWithData:data
                                              encoding:NSUTF8StringEncoding] autorelease];

    [task release];
    return [output stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)reportErrorWithMessage:(NSString *)message
{
    NSDebugLLog(@"gwcomp", @"OSSBackend error: %@", message);

    if ([delegate respondsToSelector:@selector(soundBackend:didEncounterError:)]) {
        NSError *error = [NSError errorWithDomain:@"OSSBackend"
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey: message}];
        [delegate soundBackend:self didEncounterError:error];
    }
}

@end

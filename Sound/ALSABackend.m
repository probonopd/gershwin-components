/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * ALSA Backend Implementation
 */

#import "ALSABackend.h"
#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>

// ALSA mixer control names we look for
static NSString *const kMasterControl = @"Master";
static NSString *const kPCMControl = @"PCM";
static NSString *const kSpeakerControl = @"Speaker";
static NSString *const kHeadphoneControl = @"Headphone";
static NSString *const kCaptureControl = @"Capture";
static NSString *const kMicControl = @"Mic";

@implementation ALSABackend

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
        currentOutputCard = 0;
        currentInputCard = 0;
        // Set up file paths
        NSString *home = NSHomeDirectory();
        asoundrcPath = [[home stringByAppendingPathComponent:@".asoundrc"] retain];
        defaultsFilePath = [[home stringByAppendingPathComponent:
                            @".config/gershwin/sound-defaults.plist"] retain];
        
        [self findToolPaths];
        [self enumerateDevices];
        [self loadAlertSounds];
        [self loadDefaultDevices];
    }
    return self;
}

- (void)dealloc
{
    // Cancel any pending deferred save and flush immediately
    if (deferredSaveTimer) {
        dispatch_source_cancel(deferredSaveTimer);
        dispatch_release(deferredSaveTimer);
        deferredSaveTimer = nil;
    }
    [self savePreferences];

    [self stopInputLevelMonitoring];
    [cachedOutputDevices release];
    [cachedInputDevices release];
    [cachedAlertSounds release];
    [defaultOutput release];
    [defaultInput release];
    [currentAlert release];
    [alertDevice release];
    [amixerPath release];
    [aplayPath release];
    [arecordPath release];
    [alsactlPath release];
    [asoundrcPath release];
    [defaultsFilePath release];
    [super dealloc];
}

- (BOOL)findToolPaths
{
    // Find amixer
    NSArray *searchPaths = @[@"/usr/bin/amixer", @"/bin/amixer", 
                             @"/usr/local/bin/amixer", @"/sbin/amixer"];
    
    for (NSString *path in searchPaths) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
            amixerPath = [path retain];
            break;
        }
    }
    
    // Find aplay
    searchPaths = @[@"/usr/bin/aplay", @"/bin/aplay", 
                    @"/usr/local/bin/aplay"];
    for (NSString *path in searchPaths) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
            aplayPath = [path retain];
            break;
        }
    }
    
    // Find arecord
    searchPaths = @[@"/usr/bin/arecord", @"/bin/arecord", 
                    @"/usr/local/bin/arecord"];
    for (NSString *path in searchPaths) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
            arecordPath = [path retain];
            break;
        }
    }
    
    // Find alsactl
    searchPaths = @[@"/usr/sbin/alsactl", @"/sbin/alsactl", 
                    @"/usr/bin/alsactl", @"/usr/local/sbin/alsactl"];
    for (NSString *path in searchPaths) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
            alsactlPath = [path retain];
            break;
        }
    }
    
    NSLog(@"ALSABackend findToolPaths: amixer=%@ aplay=%@ arecord=%@ alsactl=%@",
          amixerPath, aplayPath, arecordPath, alsactlPath);
    return (amixerPath != nil && aplayPath != nil);
}

#pragma mark - SoundBackend Protocol - Identification

- (NSString *)backendName
{
    return @"ALSA";
}

- (NSString *)backendVersion
{
    // Get ALSA version from /proc/asound/version
    NSString *versionPath = @"/proc/asound/version";
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:versionPath 
                                                  encoding:NSUTF8StringEncoding 
                                                     error:&error];
    if (content) {
        // Parse "Advanced Linux Sound Architecture Driver Version X.X.X"
        NSRange range = [content rangeOfString:@"Version "];
        if (range.location != NSNotFound) {
            NSString *version = [content substringFromIndex:NSMaxRange(range)];
            version = [[version componentsSeparatedByString:@"."] 
                       componentsJoinedByString:@"."];
            // Trim whitespace and newlines
            version = [version stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            return version;
        }
    }
    return @"Unknown";
}

- (BOOL)isAvailable
{
    // Check if ALSA is available by looking for /proc/asound
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/proc/asound" 
                                             isDirectory:&isDir]) {
        return isDir && amixerPath != nil;
    }
    return NO;
}

#pragma mark - Device Enumeration

- (void)enumerateDevices
{
    [cachedOutputDevices removeAllObjects];
    [cachedInputDevices removeAllObjects];
    
    NSLog(@"ALSABackend enumerateDevices: starting");

    // Get playback devices: aplay -l
    NSString *playbackOutput = [self runCommand:aplayPath 
                                  withArguments:@[@"-l"]];
    NSLog(@"ALSABackend enumerateDevices: aplay -l output = %@",
          playbackOutput ?: @"(nil)");
    if (playbackOutput) {
        [self parsePlaybackDevices:playbackOutput];
    }
    
    // Get capture devices: arecord -l
    NSString *captureOutput = [self runCommand:arecordPath 
                                 withArguments:@[@"-l"]];
    if (captureOutput) {
        [self parseCaptureDevices:captureOutput];
    }
    
    NSLog(@"ALSABackend enumerateDevices: outputDevices=%lu inputDevices=%lu",
          (unsigned long)[cachedOutputDevices count],
          (unsigned long)[cachedInputDevices count]);
    
    // Update mixer controls for each device
    for (AudioDevice *device in cachedOutputDevices) {
        NSDictionary *controls = [self getMixerControls:device.cardIndex];
        if (controls) {
            [self updateDeviceWithMixerControls:device controls:controls isOutput:YES];
        }
    }
    
    for (AudioDevice *device in cachedInputDevices) {
        NSDictionary *controls = [self getMixerControls:device.cardIndex];
        if (controls) {
            [self updateDeviceWithMixerControls:device controls:controls isOutput:NO];
        }
    }
}

- (void)parsePlaybackDevices:(NSString *)output
{
    // Parse output like:
    // card 0: Audio [Bose USB Audio], device 0: USB Audio [USB Audio]
    //   Subdevices: 1/1
    //   Subdevice #0: subdevice #0

    NSArray *lines = [output componentsSeparatedByString:@"\n"];
    NSLog(@"ALSABackend parsePlaybackDevices: %lu lines", (unsigned long)[lines count]);

    for (NSString *line in lines) {
        NSLog(@"ALSABackend parsePlaybackDevices: line = '%@'", line);
        if ([line hasPrefix:@"card "]) {
            AudioDevice *device = [[AudioDevice alloc] init];
            device.direction = AudioDeviceDirectionOutput;
            device.state = AudioDeviceStateAvailable;

            // Parse card number
            NSScanner *scanner = [NSScanner scannerWithString:line];
            [scanner scanString:@"card " intoString:nil];
            int cardNum = 0;
            [scanner scanInt:&cardNum];
            device.cardIndex = cardNum;

            // Parse card name (between first [ and ])
            NSRange openBracket = [line rangeOfString:@"["];
            NSRange closeBracket = [line rangeOfString:@"]"];
            if (openBracket.location != NSNotFound &&
                closeBracket.location != NSNotFound &&
                closeBracket.location > openBracket.location) {
                NSRange nameRange = NSMakeRange(openBracket.location + 1,
                    closeBracket.location - openBracket.location - 1);
                device.cardName = [line substringWithRange:nameRange];
            }

            // Parse device number and device descriptor
            NSRange deviceRange = [line rangeOfString:@"device "];
            if (deviceRange.location != NSNotFound) {
                NSString *devicePart = [line substringFromIndex:
                                       NSMaxRange(deviceRange)];
                device.deviceIndex = [devicePart intValue];

                // Extract device descriptor after "device N: "
                NSRange colonRange = [devicePart rangeOfString:@": "];
                if (colonRange.location != NSNotFound) {
                    NSString *desc = [devicePart
                        substringFromIndex:NSMaxRange(colonRange)];
                    NSRange parenRange = [desc rangeOfString:@" ("];
                    NSRange bracketRange = [desc rangeOfString:@" ["];
                    NSRange endRange;
                    if (parenRange.location != NSNotFound &&
                        bracketRange.location != NSNotFound) {
                        endRange = (parenRange.location < bracketRange.location)
                            ? parenRange : bracketRange;
                    } else if (parenRange.location != NSNotFound) {
                        endRange = parenRange;
                    } else if (bracketRange.location != NSNotFound) {
                        endRange = bracketRange;
                    } else {
                        endRange = NSMakeRange([desc length], 0);
                    }
                    NSString *deviceName = [[desc
                        substringToIndex:endRange.location]
                        stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
                    if ([deviceName length] > 0 &&
                        ![deviceName isEqualToString:device.cardName]) {
                        device.displayName = [NSString stringWithFormat:
                            @"%@ - %@", device.cardName, deviceName];
                    } else {
                        device.displayName = device.cardName;
                    }
                } else {
                    device.displayName = device.cardName;
                }
            } else {
                device.displayName = device.cardName;
            }

            // Create identifier and stable device ID
            device.identifier = [NSString stringWithFormat:@"hw:%d,%d",
                                cardNum, device.deviceIndex];
            device.name = device.identifier;
            device.stableDeviceId = [self stableDeviceIdForCardIndex:cardNum
                                                         deviceIndex:device.deviceIndex];

            // Probe device to verify it's actually attached and usable.
            // aplay -l lists all cards registered by kernel drivers, but
            // some (e.g., HDMI without a connected display) fail to open.
            BOOL usable = [self isOutputDeviceUsable:device];
            NSLog(@"ALSABackend parsePlaybackDevices: device %@ usable=%d",
                  device.identifier, usable);
            if (!usable) {
                NSDebugLLog(@"gwcomp",
                    @"Skipping unusable output device %@ (%@) — probe failed",
                    device.displayName, device.identifier);
                [device release];
                continue;
            }

            // Guess device type from name
            device.type = [self guessDeviceType:device.displayName
                                       cardName:device.cardName];

            // Set mixer name
            device.mixerName = [NSString stringWithFormat:@"hw:%d", cardNum];

            [cachedOutputDevices addObject:device];
            [device release];
        }
    }

    // Try to pick up the ALSA default from .asoundrc.
    // If no saved default exists at loadDefaultDevices time, this is
    // used instead of just grabbing the first aplay -l entry.
    [self pickDefaultFromAsoundrc];

    // Fall back to first device if nothing is selected yet
    if ([cachedOutputDevices count] > 0 && defaultOutput == nil) {
        AudioDevice *first = [cachedOutputDevices objectAtIndex:0];
        first.isDefault = YES;
        defaultOutput = [first retain];
        currentOutputCard = first.cardIndex;
    }
}

- (void)parseCaptureDevices:(NSString *)output
{
    NSArray *lines = [output componentsSeparatedByString:@"\n"];
    
    for (NSString *line in lines) {
        if ([line hasPrefix:@"card "]) {
            AudioDevice *device = [[AudioDevice alloc] init];
            device.direction = AudioDeviceDirectionInput;
            device.state = AudioDeviceStateAvailable;
            
            // Parse card number
            NSScanner *scanner = [NSScanner scannerWithString:line];
            [scanner scanString:@"card " intoString:nil];
            int cardNum = 0;
            [scanner scanInt:&cardNum];
            device.cardIndex = cardNum;
            
            // Parse card name
            NSRange openBracket = [line rangeOfString:@"["];
            NSRange closeBracket = [line rangeOfString:@"]"];
            if (openBracket.location != NSNotFound && 
                closeBracket.location != NSNotFound &&
                closeBracket.location > openBracket.location) {
                NSRange nameRange = NSMakeRange(openBracket.location + 1,
                    closeBracket.location - openBracket.location - 1);
                device.cardName = [line substringWithRange:nameRange];
            }
            
            // Parse device number and device descriptor
            NSRange deviceRange = [line rangeOfString:@"device "];
            if (deviceRange.location != NSNotFound) {
                NSString *devicePart = [line substringFromIndex:
                                       NSMaxRange(deviceRange)];
                device.deviceIndex = [devicePart intValue];

                // Extract device descriptor after "device N: "
                NSRange colonRange = [devicePart rangeOfString:@": "];
                if (colonRange.location != NSNotFound) {
                    NSString *desc = [devicePart
                        substringFromIndex:NSMaxRange(colonRange)];
                    NSRange parenRange = [desc rangeOfString:@" ("];
                    NSRange bracketRange = [desc rangeOfString:@" ["];
                    NSRange endRange;
                    if (parenRange.location != NSNotFound &&
                        bracketRange.location != NSNotFound) {
                        endRange = (parenRange.location < bracketRange.location)
                            ? parenRange : bracketRange;
                    } else if (parenRange.location != NSNotFound) {
                        endRange = parenRange;
                    } else if (bracketRange.location != NSNotFound) {
                        endRange = bracketRange;
                    } else {
                        endRange = NSMakeRange([desc length], 0);
                    }
                    NSString *deviceName = [[desc
                        substringToIndex:endRange.location]
                        stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
                    if ([deviceName length] > 0 &&
                        ![deviceName isEqualToString:device.cardName]) {
                        device.displayName = [NSString stringWithFormat:
                            @"%@ - %@", device.cardName, deviceName];
                    } else {
                        device.displayName = device.cardName;
                    }
                } else {
                    device.displayName = device.cardName;
                }
            } else {
                device.displayName = device.cardName;
            }
            
            device.identifier = [NSString stringWithFormat:@"hw:%d,%d",
                                cardNum, device.deviceIndex];
            device.name = device.identifier;
            device.stableDeviceId = [self stableDeviceIdForCardIndex:cardNum
                                                         deviceIndex:device.deviceIndex];

            // Probe input device to verify it is actually attached
            if (![self isInputDeviceUsable:device]) {
                NSDebugLLog(@"gwcomp",
                    @"Skipping unusable input device %@ (%@) — probe failed",
                    device.displayName, device.identifier);
                [device release];
                continue;
            }

            device.type = AudioDeviceTypeBuiltInMicrophone;
            device.mixerName = [NSString stringWithFormat:@"hw:%d", cardNum];
            
            [cachedInputDevices addObject:device];
            [device release];
        }
    }
    
    // Set first device as default if none selected
    if ([cachedInputDevices count] > 0 && defaultInput == nil) {
        AudioDevice *first = [cachedInputDevices objectAtIndex:0];
        first.isDefault = YES;
        defaultInput = [first retain];
        currentInputCard = first.cardIndex;
    }
}

- (AudioDeviceType)guessDeviceType:(NSString *)name cardName:(NSString *)cardName
{
    NSString *lowerName = [name lowercaseString];
    NSString *lowerCard = [cardName lowercaseString];
    
    // Check for USB audio
    if ([lowerName containsString:@"usb"] || [lowerCard containsString:@"usb"]) {
        return AudioDeviceTypeUSBAudio;
    }
    
    // Check for HDMI
    if ([lowerName containsString:@"hdmi"] || [lowerCard containsString:@"hdmi"]) {
        return AudioDeviceTypeHDMI;
    }
    
    // Check for DisplayPort
    if ([lowerName containsString:@"displayport"] || [lowerName containsString:@"dp"]) {
        return AudioDeviceTypeDisplayPort;
    }
    
    // Check for Bluetooth
    if ([lowerName containsString:@"bluetooth"] || [lowerName containsString:@"bt"]) {
        return AudioDeviceTypeBluetooth;
    }
    
    // Check for headphones
    if ([lowerName containsString:@"headphone"]) {
        return AudioDeviceTypeHeadphones;
    }
    
    // Check for SPDIF/digital
    if ([lowerName containsString:@"spdif"] || [lowerName containsString:@"digital"]) {
        return AudioDeviceTypeSPDIF;
    }
    
    // Default to built-in speaker for output
    return AudioDeviceTypeBuiltInSpeaker;
}

#pragma mark - Device Probing

// Returns 1 if usable, 0 if not usable, -1 if undetermined (format issue).
- (int)probeOutputWithFormat:(NSString *)format
                    channels:(NSString *)channels
                       rate:(NSString *)rate
                    probeId:(NSString *)probeId
{
    // Build a shell command that pipes a tiny amount of data through aplay.
    // Using -d 1 would play for 1 full second on success, so instead we pipe
    // just 100 bytes via dd and let aplay exit as soon as stdin reaches EOF.
    NSMutableString *cmd = [NSMutableString string];
    [cmd appendString:@"dd if=/dev/zero bs=100 count=1 2>/dev/null | "];
    [cmd appendFormat:@"%@ -D %@ -q", aplayPath, probeId];
    if (format) {
        [cmd appendFormat:@" -f %@", format];
    }
    if (channels) {
        [cmd appendFormat:@" -c %@", channels];
    }
    if (rate) {
        [cmd appendFormat:@" -r %@", rate];
    }
    NSString *output = [self runCommandCaptureError:@"/bin/sh"
                                      withArguments:@[@"-c", cmd]];
    NSLog(@"ALSABackend probeOutput: cmd='%@' output='%@'", cmd,
          output ?: @"(nil)");
    if (!output) return 1;
    if ([output length] == 0) return 1;
    if ([output containsString:@"Device or resource busy"]) return 1;
    if ([output containsString:@"audio open error"]) return 0;
    return -1;
}

- (BOOL)isOutputDeviceUsable:(AudioDevice *)device
{
    if (!aplayPath) {
        NSLog(@"ALSABackend isOutputDeviceUsable: no aplayPath, returning NO");
        return NO;
    }

    NSString *probeId = [NSString stringWithFormat:@"hw:%d,%d",
                         device.cardIndex, device.deviceIndex];
    NSLog(@"ALSABackend isOutputDeviceUsable: probing %@", probeId);

    int result = [self probeOutputWithFormat:@"S16_LE"
                                channels:@"2" rate:@"48000" probeId:probeId];
    if (result != -1) {
        NSLog(@"ALSABackend isOutputDeviceUsable: S16_LE result=%d -> %@",
              result, result ? @"usable" : @"NOT usable");
        return (BOOL)result;
    }

    result = [self probeOutputWithFormat:@"IEC958_SUBFRAME_LE"
                                channels:@"2" rate:@"48000" probeId:probeId];
    if (result != -1) {
        NSLog(@"ALSABackend isOutputDeviceUsable: IEC958 result=%d -> %@",
              result, result ? @"usable" : @"NOT usable");
        return (BOOL)result;
    }

    NSLog(@"ALSABackend isOutputDeviceUsable: both inconclusive, assuming usable");
    return YES;
}

// Returns 1 if usable, 0 if not usable, -1 if undetermined (format issue).
- (int)probeInputWithFormat:(NSString *)format
                   channels:(NSString *)channels
                      rate:(NSString *)rate
                   probeId:(NSString *)probeId
{
    NSMutableArray *args = [NSMutableArray arrayWithObjects:
                            @"-D", probeId, @"-d", @"1", @"-q", @"/dev/zero", nil];
    if (format) {
        [args addObject:@"-f"];
        [args addObject:format];
    }
    if (channels) {
        [args addObject:@"-c"];
        [args addObject:channels];
    }
    if (rate) {
        [args addObject:@"-r"];
        [args addObject:rate];
    }
    NSString *output = [self runCommandCaptureError:arecordPath
                                      withArguments:args];
    if (!output) return 1;
    if ([output length] == 0) return 1;
    if ([output containsString:@"Device or resource busy"]) return 1;
    if ([output containsString:@"audio open error"]) return 0;
    return -1;
}

- (BOOL)isInputDeviceUsable:(AudioDevice *)device
{
    if (!arecordPath) return NO;

    NSString *probeId = [NSString stringWithFormat:@"hw:%d,%d",
                         device.cardIndex, device.deviceIndex];

    int result = [self probeInputWithFormat:@"S16_LE"
                                channels:@"1" rate:@"48000" probeId:probeId];
    if (result != -1) return (BOOL)result;

    result = [self probeInputWithFormat:@"IEC958_SUBFRAME_LE"
                                channels:@"2" rate:@"48000" probeId:probeId];
    if (result != -1) return (BOOL)result;

    // Inconclusive — assume usable.
    return YES;
}

// Run a command and return combined stdout+stderr even if exit code is non-zero.
- (NSString *)runCommandCaptureError:(NSString *)command
                       withArguments:(NSArray *)args
{
    if (!command) return nil;

    NSTask *task = [[NSTask alloc] init];
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];

    [task setLaunchPath:command];
    [task setArguments:args];
    [task setStandardOutput:outPipe];
    [task setStandardError:errPipe];

    // Force C locale so probing error messages are in English.
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [env setObject:@"C" forKey:@"LC_ALL"];
    [task setEnvironment:env];
    [env release];

    @try {
        [task launch];
    } @catch (NSException *e) {
        [task release];
        return nil;
    }

    NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];

    NSString *outStr = [[NSString alloc] initWithData:outData
                                             encoding:NSUTF8StringEncoding];
    NSString *errStr = [[NSString alloc] initWithData:errData
                                             encoding:NSUTF8StringEncoding];
    // Prefer stderr for error messages; fall back to stdout.
    // Retain the chosen one so releasing the other doesn't free it.
    NSString *result;
    if (errStr && [errStr length] > 0) {
        result = [errStr retain];
        [outStr release];
    } else {
        result = [outStr retain];
        [errStr release];
    }
    [task release];

    return [result autorelease];
}

- (void)updateDeviceWithMixerControls:(AudioDevice *)device 
                             controls:(NSDictionary *)controls 
                             isOutput:(BOOL)isOutput
{
    // Find the appropriate volume control
    NSArray *outputControls = @[kMasterControl, kPCMControl, 
                                kSpeakerControl, kHeadphoneControl];
    NSArray *inputControls = @[kCaptureControl, kMicControl];
    
    NSArray *controlsToCheck = isOutput ? outputControls : inputControls;
    
    for (NSString *controlName in controlsToCheck) {
        NSDictionary *ctrl = [controls objectForKey:controlName];
        if (ctrl) {
            AudioControl *volControl = [[AudioControl alloc] init];
            volControl.identifier = controlName;
            volControl.name = controlName;

            NSNumber *volNum = [ctrl objectForKey:@"volume"];
            if (volNum) {
                volControl.value = [volNum floatValue] / 100.0;
                volControl.minValue = 0.0;
                volControl.maxValue = 1.0;
            }

            NSNumber *muteNum = [ctrl objectForKey:@"muted"];
            if (muteNum) {
                volControl.isMuted = [muteNum boolValue];
                volControl.hasMuteControl = YES;
            }

            device.volumeControl = volControl;
            [volControl release];
            return;
        }
    }

    // Fall back to the first listed ALSA control if no known control found.
    if ([controls count] > 0) {
        NSString *firstControl = [[controls allKeys] firstObject];
        NSDictionary *ctrl = [controls objectForKey:firstControl];
        if (ctrl) {
            AudioControl *volControl = [[AudioControl alloc] init];
            volControl.identifier = firstControl;
            volControl.name = firstControl;

            NSNumber *volNum = [ctrl objectForKey:@"volume"];
            if (volNum) {
                volControl.value = [volNum floatValue] / 100.0;
                volControl.minValue = 0.0;
                volControl.maxValue = 1.0;
            }

            NSNumber *muteNum = [ctrl objectForKey:@"muted"];
            if (muteNum) {
                volControl.isMuted = [muteNum boolValue];
                volControl.hasMuteControl = YES;
            }

            device.volumeControl = volControl;
            [volControl release];
            return;
        }
    }

    // No hardware mixer controls found (e.g. HDMI without PCM volume).
    // Create a read-only volume control at 100% so the device is still
    // usable for audio output, but the volume slider will be disabled.
    AudioControl *volControl = [[AudioControl alloc] init];
    volControl.identifier = @"";
    volControl.name = @"";
    volControl.value = 1.0;
    volControl.minValue = 0.0;
    volControl.maxValue = 1.0;
    volControl.isReadOnly = YES;
    volControl.hasMuteControl = NO;
    device.volumeControl = volControl;
    [volControl release];
}

- (NSString *)preferredMixerControlNameForDevice:(AudioDevice *)device 
                                         isOutput:(BOOL)isOutput
{
    if (!device) return nil;

    // Prefer control associated with loaded mixer state, if any.
    if (device.volumeControl && device.volumeControl.identifier.length > 0) {
        return device.volumeControl.identifier;
    }

    NSDictionary *controls = [self getMixerControls:device.cardIndex];
    if (!controls || [controls count] == 0) return nil;

    NSArray *outputPriority = @[kMasterControl, kPCMControl, kSpeakerControl, kHeadphoneControl];
    NSArray *inputPriority = @[kCaptureControl, kMicControl];
    NSArray *priority = isOutput ? outputPriority : inputPriority;

    for (NSString *controlName in priority) {
        if ([controls objectForKey:controlName]) {
            return controlName;
        }
    }

    // Fallback to first found control name
    return [[controls allKeys] firstObject];
}

#pragma mark - Mixer Control

- (NSDictionary *)getMixerControls:(int)cardIndex
{
    // Run amixer to get all controls for a card
    NSString *output = [self runCommand:amixerPath 
                          withArguments:@[@"-c", 
                            [NSString stringWithFormat:@"%d", cardIndex],
                            @"scontrols"]];
    
    if (!output) return nil;
    
    NSMutableDictionary *controls = [NSMutableDictionary dictionary];
    
    // Parse simple control names
    // Format: Simple mixer control 'Master',0
    NSArray *lines = [output componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        NSRange quoteStart = [line rangeOfString:@"'"];
        if (quoteStart.location != NSNotFound) {
            NSRange quoteEnd = [line rangeOfString:@"'" 
                options:0 
                range:NSMakeRange(quoteStart.location + 1, 
                                 [line length] - quoteStart.location - 1)];
            if (quoteEnd.location != NSNotFound) {
                NSString *name = [line substringWithRange:
                    NSMakeRange(quoteStart.location + 1,
                               quoteEnd.location - quoteStart.location - 1)];
                
                // Get control details
                NSDictionary *details = [self getControlDetails:name 
                                                           card:cardIndex];
                if (details) {
                    [controls setObject:details forKey:name];
                }
            }
        }
    }
    
    return controls;
}

- (NSDictionary *)getControlDetails:(NSString *)controlName card:(int)cardIndex
{
    NSString *output = [self runCommand:amixerPath 
                          withArguments:@[@"-c", 
                            [NSString stringWithFormat:@"%d", cardIndex],
                            @"sget", controlName]];
    
    if (!output) return nil;
    
    NSMutableDictionary *details = [NSMutableDictionary dictionary];
    
    // Parse volume percentage
    // Look for patterns like [60%] or Playback 60 [60%]
    NSRange percentRange = [output rangeOfString:@"[" options:0];
    while (percentRange.location != NSNotFound) {
        NSRange endRange = [output rangeOfString:@"%]" 
            options:0 
            range:NSMakeRange(percentRange.location, 
                             [output length] - percentRange.location)];
        if (endRange.location != NSNotFound) {
            NSString *numStr = [output substringWithRange:
                NSMakeRange(percentRange.location + 1,
                           endRange.location - percentRange.location - 1)];
            int percent = [numStr intValue];
            [details setObject:@(percent) forKey:@"volume"];
            break;
        }
        
        NSUInteger nextStart = percentRange.location + 1;
        if (nextStart >= [output length]) break;
        percentRange = [output rangeOfString:@"[" 
            options:0 
            range:NSMakeRange(nextStart, [output length] - nextStart)];
    }
    
    // Parse mute state - look for [on] or [off]
    if ([output containsString:@"[off]"]) {
        [details setObject:@YES forKey:@"muted"];
    } else if ([output containsString:@"[on]"]) {
        [details setObject:@NO forKey:@"muted"];
    }
    
    return details;
}

- (BOOL)setMixerControl:(NSString *)control 
                  value:(NSString *)value 
                   card:(int)cardIndex
{
    NSString *cardStr = [NSString stringWithFormat:@"%d", cardIndex];
    NSArray *args = @[@"-c", cardStr, @"sset", control, value];
    
    NSString *output = [self runCommand:amixerPath withArguments:args];
    
    if (!output) {
        NSDebugLLog(@"gwcomp", @"ALSABackend: setMixerControl: FAILED - %@=%@ on card %d", 
              control, value, cardIndex);
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"ALSABackend: setMixerControl: SUCCESS - %@=%@ on card %d", 
          control, value, cardIndex);
    return YES;
}

#pragma mark - Immediate ALSA Control Switching

- (BOOL)switchALSAControlImmediately:(NSString *)controlName 
                            toValue:(NSString *)value 
                              onCard:(int)cardIndex
{
    NSDebugLLog(@"gwcomp", @"ALSABackend: switchALSAControlImmediately: %@ = %@ on card %d", 
          controlName, value, cardIndex);
    
    // Run amixer with explicit card specification for immediate switching
    NSString *cardStr = [NSString stringWithFormat:@"%d", cardIndex];
    NSArray *args = @[@"-c", cardStr, @"sset", controlName, value, @"-q"];
    
    NSString *output = [self runCommand:amixerPath withArguments:args];
    
    if (output == nil) {
        NSDebugLLog(@"gwcomp", @"ALSABackend: switchALSAControlImmediately: FAILED");
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"ALSABackend: switchALSAControlImmediately: SUCCESS");
    return YES;
}

- (NSArray *)getAvailableALSAControls:(int)cardIndex
{
    NSDebugLLog(@"gwcomp", @"ALSABackend: getAvailableALSAControls: card %d", cardIndex);
    
    NSString *cardStr = [NSString stringWithFormat:@"%d", cardIndex];
    NSString *output = [self runCommand:amixerPath 
                          withArguments:@[@"-c", cardStr, @"scontrols"]];
    
    if (!output) {
        NSDebugLLog(@"gwcomp", @"ALSABackend: getAvailableALSAControls: FAILED - no output from amixer");
        return nil;
    }
    
    NSMutableArray *controls = [NSMutableArray array];
    
    // Parse control names from amixer output
    // Format: Simple mixer control 'Master',0
    NSArray *lines = [output componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        NSRange quoteStart = [line rangeOfString:@"'"];
        if (quoteStart.location != NSNotFound) {
            NSRange quoteEnd = [line rangeOfString:@"'" 
                options:0 
                range:NSMakeRange(quoteStart.location + 1, 
                                 [line length] - quoteStart.location - 1)];
            if (quoteEnd.location != NSNotFound) {
                NSString *name = [line substringWithRange:
                    NSMakeRange(quoteStart.location + 1,
                               quoteEnd.location - quoteStart.location - 1)];
                [controls addObject:name];
                NSDebugLLog(@"gwcomp", @"ALSABackend:   found control: %@", name);
            }
        }
    }
    
    return controls;
}

- (float)parseVolumeFromMixerOutput:(NSString *)output
{
    // Look for [XX%]
    NSRange start = [output rangeOfString:@"["];
    while (start.location != NSNotFound) {
        NSRange end = [output rangeOfString:@"%]" 
            options:0 
            range:NSMakeRange(start.location, [output length] - start.location)];
        if (end.location != NSNotFound) {
            NSString *numStr = [output substringWithRange:
                NSMakeRange(start.location + 1, end.location - start.location - 1)];
            return [numStr floatValue] / 100.0;
        }
        
        NSUInteger nextStart = start.location + 1;
        if (nextStart >= [output length]) break;
        start = [output rangeOfString:@"[" 
            options:0 
            range:NSMakeRange(nextStart, [output length] - nextStart)];
    }
    return 0.0;
}

- (BOOL)parseMuteFromMixerOutput:(NSString *)output
{
    return [output containsString:@"[off]"];
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
    NSDebugLLog(@"gwcomp", @"ALSABackend: setDefaultOutputDevice: %@", device ? device.name : @"(nil)");
    if (!device) {
        NSDebugLLog(@"gwcomp", @"ALSABackend: setDefaultOutputDevice: FAILED - device is nil");
        return NO;
    }
    
    // Update the cached default
    for (AudioDevice *dev in cachedOutputDevices) {
        dev.isDefault = [dev.identifier isEqualToString:device.identifier];
        if (dev.isDefault) {
            [defaultOutput release];
            defaultOutput = [dev retain];
            currentOutputCard = dev.cardIndex;
            NSDebugLLog(@"gwcomp", @"ALSABackend:   set card index to %d", currentOutputCard);
        }
    }
    
    // Save to configuration
    BOOL success = [self saveDefaultDevice:device isOutput:YES];
    NSDebugLLog(@"gwcomp", @"ALSABackend: setDefaultOutputDevice: %@", success ? @"SUCCESS" : @"FAILED");
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
    NSDebugLLog(@"gwcomp", @"ALSABackend: setDefaultInputDevice: %@", device ? device.name : @"(nil)");
    if (!device) {
        NSDebugLLog(@"gwcomp", @"ALSABackend: setDefaultInputDevice: FAILED - device is nil");
        return NO;
    }
    
    for (AudioDevice *dev in cachedInputDevices) {
        dev.isDefault = [dev.identifier isEqualToString:device.identifier];
        if (dev.isDefault) {
            [defaultInput release];
            defaultInput = [dev retain];
            currentInputCard = dev.cardIndex;
            NSDebugLLog(@"gwcomp", @"ALSABackend:   set card index to %d", currentInputCard);
        }
    }
    
    BOOL success = [self saveDefaultDevice:device isOutput:NO];
    NSDebugLLog(@"gwcomp", @"ALSABackend: setDefaultInputDevice: %@", success ? @"SUCCESS" : @"FAILED");
    return success;
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

    if (defaultOutput.volumeControl && defaultOutput.volumeControl.isReadOnly) {
        return defaultOutput.volumeControl.value;
    }

    NSString *controlName = [self preferredMixerControlNameForDevice:defaultOutput isOutput:YES];
    if (!controlName) {
        return defaultOutput.volumeControl ? defaultOutput.volumeControl.value : 0.0;
    }

    NSString *output = [self runCommand:amixerPath
                          withArguments:@[@"-c",
                            [NSString stringWithFormat:@"%d", currentOutputCard],
                            @"sget", controlName]];

    if (!output) {
        // Try fallback controls in priority order
        NSArray *fallbackControls = @[kMasterControl, kPCMControl, kSpeakerControl, kHeadphoneControl];
        for (NSString *candidate in fallbackControls) {
            if ([candidate isEqualToString:controlName]) continue;
            output = [self runCommand:amixerPath
                        withArguments:@[@"-c",
                          [NSString stringWithFormat:@"%d", currentOutputCard],
                          @"sget", candidate]];
            if (output) {
                controlName = candidate;
                break;
            }
        }
    }

    if (output) {
        float volume = [self parseVolumeFromMixerOutput:output];
        if (defaultOutput.volumeControl) {
            defaultOutput.volumeControl.value = volume;
        }
        return volume;
    }

    return defaultOutput.volumeControl ? defaultOutput.volumeControl.value : 0.0;
}

- (BOOL)setOutputVolume:(float)volume
{
    NSDebugLLog(@"gwcomp", @"ALSABackend: setOutputVolume: %.2f", volume);
    if (volume < 0.0) volume = 0.0;
    if (volume > 1.0) volume = 1.0;

    // ReadOnly devices have no hardware volume control — cache value only.
    if (defaultOutput.volumeControl && defaultOutput.volumeControl.isReadOnly) {
        defaultOutput.volumeControl.value = volume;
        return YES;
    }

    int percent = (int)(volume * 100);
    NSString *value = [NSString stringWithFormat:@"%d%%", percent];
    NSDebugLLog(@"gwcomp", @"ALSABackend:   setting to %@, card %d", value, currentOutputCard);

    NSString *controlName = [self preferredMixerControlNameForDevice:defaultOutput isOutput:YES];
    if (!controlName) {
        controlName = kMasterControl;
    }

    BOOL success = [self setMixerControl:controlName
                                   value:value
                                     card:currentOutputCard];

    if (!success) {
        NSArray *fallbackControls = @[kMasterControl, kPCMControl, kSpeakerControl, kHeadphoneControl];
        for (NSString *candidate in fallbackControls) {
            if ([candidate isEqualToString:controlName]) continue;
            if ([self setMixerControl:candidate value:value card:currentOutputCard]) {
                controlName = candidate;
                success = YES;
                break;
            }
        }
    }

    if (success && defaultOutput.volumeControl) {
        defaultOutput.volumeControl.value = volume;
        defaultOutput.volumeControl.identifier = controlName;
    }

    NSDebugLLog(@"gwcomp", @"ALSABackend: setOutputVolume: %@", success ? @"SUCCESS" : @"FAILED");

    if (success && playVolumeChangeFeedback) {
        [self playVolumeFeedback];
    }

    return success;
}

- (BOOL)isOutputMuted
{
    if (!defaultOutput) return NO;

    if (defaultOutput.volumeControl && defaultOutput.volumeControl.isReadOnly) {
        return defaultOutput.volumeControl.isMuted;
    }

    NSString *controlName = [self preferredMixerControlNameForDevice:defaultOutput isOutput:YES];
    if (!controlName) {
        controlName = kMasterControl;
    }

    NSString *output = [self runCommand:amixerPath
                          withArguments:@[@"-c",
                            [NSString stringWithFormat:@"%d", currentOutputCard],
                            @"sget", controlName]];

    if (!output) {
        NSArray *fallbackControls = @[kMasterControl, kPCMControl, kSpeakerControl, kHeadphoneControl];
        for (NSString *candidate in fallbackControls) {
            if ([candidate isEqualToString:controlName]) continue;
            output = [self runCommand:amixerPath
                        withArguments:@[@"-c",
                          [NSString stringWithFormat:@"%d", currentOutputCard],
                          @"sget", candidate]];
            if (output) {
                controlName = candidate;
                break;
            }
        }
    }

    if (output) {
        BOOL muted = [self parseMuteFromMixerOutput:output];
        if (defaultOutput.volumeControl) {
            defaultOutput.volumeControl.isMuted = muted;
            defaultOutput.volumeControl.identifier = controlName;
        }
        return muted;
    }

    return defaultOutput.volumeControl ? defaultOutput.volumeControl.isMuted : NO;
}

- (BOOL)setOutputMuted:(BOOL)muted
{
    NSDebugLLog(@"gwcomp", @"ALSABackend: setOutputMuted: %@", muted ? @"YES" : @"NO");

    if (defaultOutput.volumeControl && defaultOutput.volumeControl.isReadOnly) {
        defaultOutput.volumeControl.isMuted = muted;
        return YES;
    }

    NSString *value = muted ? @"mute" : @"unmute";
    NSDebugLLog(@"gwcomp", @"ALSABackend:   setting to %@, card %d", value, currentOutputCard);

    NSString *controlName = [self preferredMixerControlNameForDevice:defaultOutput isOutput:YES];
    if (!controlName) {
        controlName = kMasterControl;
    }

    BOOL success = [self setMixerControl:controlName
                                   value:value
                                    card:currentOutputCard];

    if (!success) {
        NSArray *fallbackControls = @[kMasterControl, kPCMControl, kSpeakerControl, kHeadphoneControl];
        for (NSString *candidate in fallbackControls) {
            if ([candidate isEqualToString:controlName]) continue;
            if ([self setMixerControl:candidate value:value card:currentOutputCard]) {
                controlName = candidate;
                success = YES;
                break;
            }
        }
    }

    if (success && defaultOutput.volumeControl) {
        defaultOutput.volumeControl.isMuted = muted;
        defaultOutput.volumeControl.identifier = controlName;
    }

    NSDebugLLog(@"gwcomp", @"ALSABackend: setOutputMuted: %@", success ? @"SUCCESS" : @"FAILED");
    return success;
}

- (float)outputBalance
{
    // ALSA doesn't have a standard balance control
    // Would need to compare left/right channel volumes
    return 0.5; // Center
}

- (BOOL)setOutputBalance:(float)balance
{
    NSDebugLLog(@"gwcomp", @"ALSABackend: setOutputBalance: %.2f", balance);
    // TODO: Implement by adjusting left/right channel volumes
    NSDebugLLog(@"gwcomp", @"ALSABackend: setOutputBalance: SUCCESS (not yet implemented)");
    return YES;
}

#pragma mark - Input Volume Control

- (float)inputVolume
{
    if (!defaultInput) return 0.0;

    NSString *controlName = [self preferredMixerControlNameForDevice:defaultInput isOutput:NO];
    if (!controlName) {
        controlName = kCaptureControl;
    }

    NSString *output = [self runCommand:amixerPath 
                          withArguments:@[@"-c", 
                            [NSString stringWithFormat:@"%d", currentInputCard],
                            @"sget", controlName]];

    if (!output) {
        NSArray *fallbackControls = @[kCaptureControl, kMicControl];
        for (NSString *candidate in fallbackControls) {
            if ([candidate isEqualToString:controlName]) continue;
            output = [self runCommand:amixerPath 
                        withArguments:@[@"-c", 
                          [NSString stringWithFormat:@"%d", currentInputCard],
                          @"sget", candidate]];
            if (output) {
                controlName = candidate;
                break;
            }
        }
    }

    if (output) {
        float volume = [self parseVolumeFromMixerOutput:output];
        if (defaultInput.volumeControl) {
            defaultInput.volumeControl.value = volume;
            defaultInput.volumeControl.identifier = controlName;
        }
        return volume;
    }

    return defaultInput.volumeControl ? defaultInput.volumeControl.value : 0.0;
}

- (BOOL)setInputVolume:(float)volume
{
    NSDebugLLog(@"gwcomp", @"ALSABackend: setInputVolume: %.2f", volume);
    if (volume < 0.0) volume = 0.0;
    if (volume > 1.0) volume = 1.0;

    int percent = (int)(volume * 100);
    NSString *value = [NSString stringWithFormat:@"%d%%", percent];
    NSDebugLLog(@"gwcomp", @"ALSABackend:   setting to %@, card %d", value, currentInputCard);

    NSString *controlName = [self preferredMixerControlNameForDevice:defaultInput isOutput:NO];
    if (!controlName) {
        controlName = kCaptureControl;
    }

    BOOL success = [self setMixerControl:controlName 
                                   value:value 
                                    card:currentInputCard];

    if (!success) {
        NSArray *fallbackControls = @[kCaptureControl, kMicControl];
        for (NSString *candidate in fallbackControls) {
            if ([candidate isEqualToString:controlName]) continue;
            if ([self setMixerControl:candidate value:value card:currentInputCard]) {
                controlName = candidate;
                success = YES;
                break;
            }
        }
    }

    if (success && defaultInput.volumeControl) {
        defaultInput.volumeControl.value = volume;
        defaultInput.volumeControl.identifier = controlName;
    }

    NSDebugLLog(@"gwcomp", @"ALSABackend: setInputVolume: %@", success ? @"SUCCESS" : @"FAILED");
    return success;
}

- (BOOL)isInputMuted
{
    if (!defaultInput) return NO;

    NSString *controlName = [self preferredMixerControlNameForDevice:defaultInput isOutput:NO];
    if (!controlName) {
        controlName = kCaptureControl;
    }

    NSString *output = [self runCommand:amixerPath 
                          withArguments:@[@"-c", 
                            [NSString stringWithFormat:@"%d", currentInputCard],
                            @"sget", controlName]];

    if (!output) {
        NSArray *fallbackControls = @[kCaptureControl, kMicControl];
        for (NSString *candidate in fallbackControls) {
            if ([candidate isEqualToString:controlName]) continue;
            output = [self runCommand:amixerPath 
                        withArguments:@[@"-c", 
                          [NSString stringWithFormat:@"%d", currentInputCard],
                          @"sget", candidate]];
            if (output) {
                controlName = candidate;
                break;
            }
        }
    }

    if (output) {
        BOOL muted = [self parseMuteFromMixerOutput:output];
        if (defaultInput.volumeControl) {
            defaultInput.volumeControl.isMuted = muted;
            defaultInput.volumeControl.identifier = controlName;
        }
        return muted;
    }

    return defaultInput.volumeControl ? defaultInput.volumeControl.isMuted : NO;
}

- (BOOL)setInputMuted:(BOOL)muted
{
    NSDebugLLog(@"gwcomp", @"ALSABackend: setInputMuted: %@", muted ? @"YES" : @"NO");
    NSString *value = muted ? @"mute" : @"unmute";
    NSDebugLLog(@"gwcomp", @"ALSABackend:   setting to %@, card %d", value, currentInputCard);

    NSString *controlName = [self preferredMixerControlNameForDevice:defaultInput isOutput:NO];
    if (!controlName) {
        controlName = kCaptureControl;
    }

    BOOL success = [self setMixerControl:controlName 
                                   value:value 
                                    card:currentInputCard];

    if (!success) {
        NSArray *fallbackControls = @[kCaptureControl, kMicControl];
        for (NSString *candidate in fallbackControls) {
            if ([candidate isEqualToString:controlName]) continue;
            if ([self setMixerControl:candidate value:value card:currentInputCard]) {
                controlName = candidate;
                success = YES;
                break;
            }
        }
    }

    if (success && defaultInput.volumeControl) {
        defaultInput.volumeControl.isMuted = muted;
        defaultInput.volumeControl.identifier = controlName;
    }

    NSDebugLLog(@"gwcomp", @"ALSABackend: setInputMuted: %@", success ? @"SUCCESS" : @"FAILED");
    return success;
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
    // This is a simplified implementation
    // A proper implementation would use ALSA's PCM capture to measure actual levels
    // For now, return a simulated value based on capture volume setting
    return 0.0;
}

#pragma mark - Device-Specific Volume Control

- (float)volumeForDevice:(AudioDevice *)device
{
    if (!device) return 0.0;
    return device.volumeControl ? device.volumeControl.value : 0.0;
}

- (BOOL)setVolume:(float)volume forDevice:(AudioDevice *)device
{
    if (!device) return NO;
    
    int percent = (int)(volume * 100);
    NSString *value = [NSString stringWithFormat:@"%d%%", percent];
    NSString *controlName = device.volumeControl ?
                            device.volumeControl.identifier : kMasterControl;

    BOOL success = [self setMixerControl:controlName
                                   value:value
                                    card:device.cardIndex];

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
    
    NSString *value = muted ? @"mute" : @"unmute";
    NSString *controlName = device.volumeControl ?
                            device.volumeControl.identifier : kMasterControl;

    BOOL success = [self setMixerControl:controlName
                                   value:value
                                    card:device.cardIndex];

    if (success && device.volumeControl) {
        device.volumeControl.isMuted = muted;
    }
    
    return success;
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
    
    // ALSA doesn't have a standard way to switch ports
    // This would be hardware/driver specific
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

        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:NULL];

        if (!files) {
            NSDebugLLog(@"gwcomp", @"ALSABackend: loadAlertSounds: could not scan %@", dir);
            continue;
        }

        for (NSString *file in files) {
            NSString *ext = [[file pathExtension] lowercaseString];
            if ([extensions containsObject:ext]) {
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

    NSDebugLLog(@"gwcomp", @"ALSABackend: loadAlertSounds: found %lu alert sounds",
          (unsigned long)[cachedAlertSounds count]);

    // Set first sound as current if none selected
    if (currentAlert == nil && [cachedAlertSounds count] > 0) {
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

    // Coalesce and defer save so it doesn't block the UI
    [self deferSavePreferences];

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
    [self deferSavePreferences];

    return YES;
}

- (BOOL)playAlertSound:(AlertSound *)sound
{
    NSDebugLLog(@"gwcomp", @"ALSABackend: playAlertSound: called");

    if (!sound) {
        NSBeep();
        return YES;
    }

    if (!sound.path || ![[NSFileManager defaultManager] fileExistsAtPath:sound.path]) {
        NSBeep();
        return YES;
    }

    NSString *device = defaultOutput ?
        [NSString stringWithFormat:@"plughw:%d", currentOutputCard] : @"default";

    // --- Apply alert volume by temporarily scaling the output mixer ---
    float savedVolume = -1.0;
    NSString *mixerControl = nil;

    if (cachedAlertVolume < 0.99 && defaultOutput) {
        mixerControl = [self preferredMixerControlNameForDevice:defaultOutput isOutput:YES];
        if (!mixerControl) mixerControl = kMasterControl;

        NSString *output = [self runCommand:amixerPath
                              withArguments:@[@"-c",
                                [NSString stringWithFormat:@"%d", currentOutputCard],
                                @"sget", mixerControl]];
        if (output) {
            savedVolume = [self parseVolumeFromMixerOutput:output];
            float targetVol = savedVolume * cachedAlertVolume;
            if (targetVol < 0.02) targetVol = 0.02;

            int percent = (int)(targetVol * 100.0);
            if (percent < 1) percent = 1;
            NSString *value = [NSString stringWithFormat:@"%d%%", percent];
            [self setMixerControl:mixerControl value:value card:currentOutputCard];
        }
    }

    // --- Play the sound (synchronously on the calling queue) ---
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:aplayPath];
    [task setArguments:@[@"-D", device, @"-q", sound.path]];

    BOOL success = YES;
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *e) {
        NSDebugLLog(@"gwcomp", @"ALSABackend:   aplay failed: %@", e);
        success = NO;
    }
    [task release];

    // --- Restore original volume ---
    if (savedVolume >= 0 && mixerControl) {
        int percent = (int)(savedVolume * 100.0);
        NSString *value = [NSString stringWithFormat:@"%d%%", percent];
        [self setMixerControl:mixerControl value:value card:currentOutputCard];
    }

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
    [self deferSavePreferences];
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
    [self deferSavePreferences];
    return YES;
}

- (BOOL)playFeedbackWhenVolumeIsChanged
{
    return playVolumeChangeFeedback;
}

- (BOOL)setPlayFeedbackWhenVolumeIsChanged:(BOOL)play
{
    playVolumeChangeFeedback = play;
    [self deferSavePreferences];
    return YES;
}

- (void)playVolumeFeedback
{
    // Play a short blip sound to indicate volume change.
    // With synchronous playback on the serial backend queue,
    // there is no risk of overlapping sounds, so no task
    // tracking is needed.
    if (currentAlert && currentAlert.path) {
        [self playAlertSound:currentAlert];
    } else {
        NSBeep();
    }
}

#pragma mark - Default Device Persistence

- (void)loadDefaultDevices
{
    // Load from user preferences
    NSString *configDir = [[defaultsFilePath stringByDeletingLastPathComponent] 
                           stringByExpandingTildeInPath];
    
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
                // Stable device ID match — authoritative, always applies
                AudioDevice *dev = [self outputDeviceWithStableId:outputId];
                if (dev) {
                    dev.isDefault = YES;
                    [defaultOutput release];
                    defaultOutput = [dev retain];
                    currentOutputCard = dev.cardIndex;
                    NSDebugLLog(@"gwcomp", @"ALSABackend: loaded default output by stable ID '%@'", outputId);
                } else {
                    // Legacy "hw:N,M" fallback — only use if asoundrc didn't
                    // already pick a default (avoid overriding a valid match
                    // when card indices have shifted since the plist was saved).
                    if (defaultOutput == nil) {
                        dev = [self outputDeviceWithIdentifier:outputId];
                        if (dev) {
                            dev.isDefault = YES;
                            [defaultOutput release];
                            defaultOutput = [dev retain];
                            currentOutputCard = dev.cardIndex;
                            NSDebugLLog(@"gwcomp", @"ALSABackend: loaded default output by legacy ID '%@'", outputId);
                        }
                    } else {
                        NSDebugLLog(@"gwcomp", @"ALSABackend: stable ID '%@' not found, keeping asoundrc default", outputId);
                    }
                }
            }

            if (inputId) {
                AudioDevice *dev = [self inputDeviceWithStableId:inputId];
                if (dev) {
                    dev.isDefault = YES;
                    [defaultInput release];
                    defaultInput = [dev retain];
                    currentInputCard = dev.cardIndex;
                    NSDebugLLog(@"gwcomp", @"ALSABackend: loaded default input by stable ID '%@'", inputId);
                } else {
                    if (defaultInput == nil) {
                        dev = [self inputDeviceWithIdentifier:inputId];
                        if (dev) {
                            dev.isDefault = YES;
                            [defaultInput release];
                            defaultInput = [dev retain];
                            currentInputCard = dev.cardIndex;
                            NSDebugLLog(@"gwcomp", @"ALSABackend: loaded default input by legacy ID '%@'", inputId);
                        }
                    } else {
                        NSDebugLLog(@"gwcomp", @"ALSABackend: stable ID '%@' not found, keeping asoundrc default", inputId);
                    }
                }
            }

            if (alertId) {
                alertDevice = [[self outputDeviceWithStableId:alertId] retain];
                if (!alertDevice) {
                    alertDevice = [[self outputDeviceWithIdentifier:alertId] retain];
                }
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

- (void)pickDefaultFromAsoundrc
{
    // Only run if no saved plist default was loaded.
    if (defaultOutput != nil) return;

    NSString *asoundrc = [NSString stringWithContentsOfFile:asoundrcPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    if (!asoundrc) return;

    // Helper: match a card reference (name or numeric) against cached devices
    AudioDevice * (^matchCardRef)(NSString *, int) = ^(NSString *cardPart, int devIndex) {
        // Try as card name (string ID) first
        for (AudioDevice *dev in cachedOutputDevices) {
            NSString *cid = [self cardIDForCardIndex:dev.cardIndex];
            if ([cid isEqualToString:cardPart] && dev.deviceIndex == devIndex) {
                return dev;
            }
        }
        // Fall back to numeric card index
        int cardNum = [cardPart intValue];
        for (AudioDevice *dev in cachedOutputDevices) {
            if (dev.cardIndex == cardNum && dev.deviceIndex == devIndex) {
                return dev;
            }
        }
        return (AudioDevice *)nil;
    };

    // ---- Try new format: pcm.dmix_<suffix> block with nested hw card/device ----
    //   pcm.dmix_EarPods_0 {
    //       slave { pcm { type hw card 1 device 0 } }
    //   }
    NSRange dmixRange = [asoundrc rangeOfString:@"pcm.dmix_"];
    if (dmixRange.location != NSNotFound) {
        NSString *afterDmix = [asoundrc substringFromIndex:dmixRange.location];
        // Find opening brace of the dmix block
        NSRange braceRange = [afterDmix rangeOfString:@"{"];
        if (braceRange.location != NSNotFound) {
            NSString *dmixBody = [afterDmix substringFromIndex:braceRange.location + 1];
            // Find closing brace at matching depth (count nesting)
            int depth = 1;
            NSUInteger closeIdx = NSNotFound;
            for (NSUInteger i = 0; i < [dmixBody length] && depth > 0; i++) {
                unichar c = [dmixBody characterAtIndex:i];
                if (c == '{') depth++;
                else if (c == '}') depth--;
                if (depth == 0) closeIdx = i;
            }
            if (closeIdx != NSNotFound) {
                dmixBody = [dmixBody substringToIndex:closeIdx];
            }
            // Scan for "card <N>" inside the slave block
            NSScanner *s = [NSScanner scannerWithString:dmixBody];
            // Look for "card" and "device" after "slave { pcm {"
            NSRange slavePcm = [dmixBody rangeOfString:@"slave"];
            if (slavePcm.location != NSNotFound) {
                NSString *slavePart = [dmixBody substringFromIndex:slavePcm.location];
                int foundCard = -1, foundDev = -1;
                s = [NSScanner scannerWithString:slavePart];
                [s scanUpToString:@"card" intoString:NULL];
                if ([s scanString:@"card" intoString:NULL]) {
                    [s scanInt:&foundCard];
                }
                // Reset scanner for device
                s = [NSScanner scannerWithString:slavePart];
                [s scanUpToString:@"device" intoString:NULL];
                if ([s scanString:@"device" intoString:NULL]) {
                    [s scanInt:&foundDev];
                }
                if (foundCard >= 0 && foundDev >= 0) {
                    for (AudioDevice *dev in cachedOutputDevices) {
                        if (dev.cardIndex == foundCard && dev.deviceIndex == foundDev) {
                            dev.isDefault = YES;
                            defaultOutput = [dev retain];
                            currentOutputCard = dev.cardIndex;
                            return;
                        }
                    }
                }
            }
        }
    }

    // ---- Old format: pcm.!default with pcm "hw:..." ----
    NSRange pcmBlock = [asoundrc rangeOfString:@"pcm.!default"];
    if (pcmBlock.location != NSNotFound) {
        NSString *block = [asoundrc substringFromIndex:pcmBlock.location];
        NSRange closeBrace = [block rangeOfString:@"}"];
        if (closeBrace.location != NSNotFound) {
            block = [block substringToIndex:closeBrace.location];
        }

        NSScanner *scanner = [NSScanner scannerWithString:block];
        [scanner scanUpToString:@"pcm \"hw:" intoString:NULL];
        if ([scanner scanString:@"pcm \"hw:" intoString:NULL]) {
            NSString *cardRef = nil;
            [scanner scanUpToString:@"\"" intoString:&cardRef];
            if (cardRef) {
                NSArray *parts = [cardRef componentsSeparatedByString:@","];
                NSString *cardPart = [parts count] > 0 ? [parts objectAtIndex:0] : nil;
                int devIndex = ([parts count] >= 2) ? [[parts objectAtIndex:1] intValue] : 0;
                if (cardPart) {
                    AudioDevice *match = matchCardRef(cardPart, devIndex);
                    if (match) {
                        match.isDefault = YES;
                        defaultOutput = [match retain];
                        currentOutputCard = match.cardIndex;
                        return;
                    }
                }
            }
        }
    }

    // ---- Fallback: look for "card <name/index>" in ctl block or dmix block ----
    // Scan the whole file for "card <name>" or "card <N>"
    for (NSString *line in [asoundrc componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        if (![trimmed hasPrefix:@"card"] && ![trimmed hasPrefix:@"Card"]) continue;

        NSScanner *s = [NSScanner scannerWithString:trimmed];
        [s scanString:@"card" intoString:NULL];
        [s scanString:@"Card" intoString:NULL];
        [s scanCharactersFromSet:[NSCharacterSet whitespaceCharacterSet]
                     intoString:NULL];

        // Quoted card name
        NSString *quoted = nil;
        if ([s scanString:@"\"" intoString:NULL]
            && [s scanUpToString:@"\"" intoString:&quoted]) {
            for (AudioDevice *dev in cachedOutputDevices) {
                NSString *cid = [self cardIDForCardIndex:dev.cardIndex];
                if ([cid isEqualToString:quoted]) {
                    dev.isDefault = YES;
                    defaultOutput = [dev retain];
                    currentOutputCard = dev.cardIndex;
                    return;
                }
            }
            continue;
        }

        // Numeric card index
        int cardNum = 0;
        if ([s scanInt:&cardNum]) {
            for (AudioDevice *dev in cachedOutputDevices) {
                if (dev.cardIndex == cardNum) {
                    dev.isDefault = YES;
                    defaultOutput = [dev retain];
                    currentOutputCard = dev.cardIndex;
                    return;
                }
            }
        }
    }
}

- (BOOL)saveDefaultDevice:(AudioDevice *)device isOutput:(BOOL)isOutput
{
    // Update .asoundrc for ALSA default device
    NSString *asoundrc = [self buildAsoundrcContent];
    NSError *error = nil;
    
    [asoundrc writeToFile:asoundrcPath 
               atomically:YES 
                 encoding:NSUTF8StringEncoding 
                    error:&error];
    
    if (error) {
        NSDebugLLog(@"gwcomp", @"Failed to write .asoundrc: %@", error);
    }
    
    // Save to our preferences file
    return [self savePreferences];
}

#pragma mark - Immediate Device Switching

- (BOOL)forceImmediateOutputDeviceSwitch:(AudioDevice *)device
{
    if (!device) {
        NSDebugLLog(@"gwcomp", @"ALSABackend: forceImmediateOutputDeviceSwitch: FAILED - device is nil");
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"ALSABackend: forceImmediateOutputDeviceSwitch: %@ (card %d, device %d)", 
          device.name, device.cardIndex, device.deviceIndex);
    
    // Step 1: Unmute the destination device if possible
    NSArray *volumeControls = @[kMasterControl, kPCMControl, kSpeakerControl, kHeadphoneControl];
    for (NSString *controlName in volumeControls) {
        if ([self setMixerControl:controlName 
                            value:@"unmute" 
                             card:device.cardIndex]) {
            NSDebugLLog(@"gwcomp", @"ALSABackend:   unmuted %@", controlName);
            break;
        }
    }
    
    // Step 2: Silence other output devices to force switching
    NSDebugLLog(@"gwcomp", @"ALSABackend:   silencing other output devices...");
    for (AudioDevice *otherDevice in cachedOutputDevices) {
        if (otherDevice.cardIndex != device.cardIndex) {
            NSDebugLLog(@"gwcomp", @"ALSABackend:   muting card %d", otherDevice.cardIndex);
            [self setMixerControl:kMasterControl 
                            value:@"mute" 
                             card:otherDevice.cardIndex];
            [self setMixerControl:kPCMControl 
                            value:@"mute" 
                             card:otherDevice.cardIndex];
        }
    }
    
    // Step 4: Update default device settings
    [self setDefaultOutputDevice:device];

    NSDebugLLog(@"gwcomp", @"ALSABackend: forceImmediateOutputDeviceSwitch: SUCCESS");
    return YES;
}

- (BOOL)forceImmediateInputDeviceSwitch:(AudioDevice *)device
{
    if (!device) {
        NSDebugLLog(@"gwcomp", @"ALSABackend: forceImmediateInputDeviceSwitch: FAILED - device is nil");
        return NO;
    }
    
    NSDebugLLog(@"gwcomp", @"ALSABackend: forceImmediateInputDeviceSwitch: %@ (card %d, device %d)", 
          device.name, device.cardIndex, device.deviceIndex);
    
    // Step 1: Enable the destination device input
    NSArray *inputControls = @[kCaptureControl, kMicControl];
    for (NSString *controlName in inputControls) {
        if ([self setMixerControl:controlName 
                            value:@"cap" 
                             card:device.cardIndex]) {
            NSDebugLLog(@"gwcomp", @"ALSABackend:   enabled capture on %@", controlName);
            break;
        }
    }
    
    // Step 2: Disable input capture on other devices
    NSDebugLLog(@"gwcomp", @"ALSABackend:   disabling capture on other input devices...");
    for (AudioDevice *otherDevice in cachedInputDevices) {
        if (otherDevice.cardIndex != device.cardIndex) {
            NSDebugLLog(@"gwcomp", @"ALSABackend:   disabling capture on card %d", otherDevice.cardIndex);
            [self setMixerControl:kCaptureControl 
                            value:@"nocap" 
                             card:otherDevice.cardIndex];
            [self setMixerControl:kMicControl 
                            value:@"nocap" 
                             card:otherDevice.cardIndex];
        }
    }
    
    // Step 3: Update default device settings
    [self setDefaultInputDevice:device];
    
    NSDebugLLog(@"gwcomp", @"ALSABackend: forceImmediateInputDeviceSwitch: SUCCESS");
    return YES;
}

- (void)deferSavePreferences
{
    // Cancel any previously scheduled save, then schedule a new one.
    // This coalesces rapid changes (e.g. clicking through sounds quickly)
    // into a single disk write after activity settles.
    //
    // Uses dispatch timer instead of performSelector:afterDelay: because
    // this method is called from a GCD queue (backendQueue) which does not
    // run an NSRunLoop, so performSelector:afterDelay: would never fire.
    if (deferredSaveTimer) {
        dispatch_source_cancel(deferredSaveTimer);
        dispatch_release(deferredSaveTimer);
        deferredSaveTimer = nil;
    }

    deferredSaveTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                               dispatch_get_main_queue());
    dispatch_source_set_timer(deferredSaveTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(deferredSaveTimer, ^{
        [self savePreferences];
        dispatch_source_cancel(deferredSaveTimer);
        dispatch_release(deferredSaveTimer);
        deferredSaveTimer = nil;
    });
    dispatch_resume(deferredSaveTimer);
}

- (BOOL)savePreferences
{
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];

    if (defaultOutput) {
        [prefs setObject:(defaultOutput.stableDeviceId ?: defaultOutput.identifier)
                  forKey:@"defaultOutput"];
    }
    if (defaultInput) {
        [prefs setObject:(defaultInput.stableDeviceId ?: defaultInput.identifier)
                  forKey:@"defaultInput"];
    }
    if (alertDevice) {
        [prefs setObject:(alertDevice.stableDeviceId ?: alertDevice.identifier)
                  forKey:@"alertDevice"];
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

#pragma mark - Device Capability Probing

- (NSDictionary *)parseStream0ForCard:(int)cardIndex
{
    NSString *path = [NSString stringWithFormat:@"/proc/asound/card%d/stream0", cardIndex];
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    if (!content) return nil;

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSString *currentSection = nil;

    for (NSString *line in [content componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];

        if ([trimmed hasPrefix:@"Playback:"]) {
            currentSection = @"playback";
            continue;
        } else if ([trimmed hasPrefix:@"Capture:"]) {
            currentSection = @"capture";
            continue;
        }

        if (!currentSection) continue;

        // Parse "Channels: N"
        if ([trimmed hasPrefix:@"Channels:"]) {
            NSScanner *scanner = [NSScanner scannerWithString:trimmed];
            [scanner scanString:@"Channels:" intoString:NULL];
            int ch = 0;
            [scanner scanInt:&ch];
            [result setObject:@(ch) forKey:[NSString stringWithFormat:@"%@_channels", currentSection]];
            continue;
        }

        // Parse "Rates: N - N"
        if ([trimmed hasPrefix:@"Rates:"]) {
            NSScanner *scanner = [NSScanner scannerWithString:trimmed];
            [scanner scanString:@"Rates:" intoString:NULL];
            int rateMin = 0, rateMax = 0;
            [scanner scanInt:&rateMin];
            [scanner scanString:@"-" intoString:NULL];
            [scanner scanInt:&rateMax];
            if (rateMax > 0) {
                [result setObject:@(rateMax) forKey:[NSString stringWithFormat:@"%@_rate", currentSection]];
            } else if (rateMin > 0) {
                [result setObject:@(rateMin) forKey:[NSString stringWithFormat:@"%@_rate", currentSection]];
            }
            continue;
        }

        // Parse "Format: FMT1 FMT2"
        if ([trimmed hasPrefix:@"Format:"]) {
            NSString *fmtStr = [trimmed substringFromIndex:7];
            fmtStr = [fmtStr stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceCharacterSet]];
            NSArray *formats = [fmtStr componentsSeparatedByCharactersInSet:
                                [NSCharacterSet whitespaceCharacterSet]];
            NSMutableArray *clean = [NSMutableArray array];
            for (NSString *f in formats) {
                if ([f length] > 0) [clean addObject:f];
            }
            if ([clean count] > 0) {
                [result setObject:clean forKey:[NSString stringWithFormat:@"%@_formats", currentSection]];
            }
        }
    }

    return result;
}

- (NSDictionary *)dumpHWParamsForCard:(int)cardIndex
                              device:(int)deviceIndex
                              stream:(NSString *)stream
{
    NSString *devStr = [NSString stringWithFormat:@"hw:%d,%d", cardIndex, deviceIndex];
    NSString *tool = [stream isEqualToString:@"capture"] ? arecordPath : aplayPath;
    if (!tool) return nil;

    // Use S16_LE and a moderate channel count to probe hardware constraints.
    // The channel count depends on direction:
    int probeChannels = [stream isEqualToString:@"capture"] ? 1 : 2;

    NSArray *args = @[@"--dump-hw-params", @"-D", devStr,
                      @"-f", @"S16_LE", @"-r", @"48000",
                      @"-c", [NSString stringWithFormat:@"%d", probeChannels],
                      @"/dev/null", @"-d", @"1"];
    NSString *output = [self runCommandCaptureError:tool withArguments:args];
    if (!output) return nil;

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *line in [output componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];

        // FORMAT:  S16_LE S24_3LE
        if ([trimmed hasPrefix:@"FORMAT:"]) {
            NSString *fmtStr = [trimmed substringFromIndex:7];
            fmtStr = [fmtStr stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceCharacterSet]];
            NSArray *formats = [fmtStr componentsSeparatedByCharactersInSet:
                                [NSCharacterSet whitespaceCharacterSet]];
            NSMutableArray *clean = [NSMutableArray array];
            for (NSString *f in formats) {
                if ([f length] > 0) [clean addObject:f];
            }
            if ([clean count] > 0) {
                [result setObject:clean forKey:@"formats"];
            }
            continue;
        }

        // CHANNELS: N
        if ([trimmed hasPrefix:@"CHANNELS:"]) {
            int ch = [[trimmed substringFromIndex:9] intValue];
            if (ch > 0) [result setObject:@(ch) forKey:@"channels"];
            continue;
        }

        // RATE: N
        if ([trimmed hasPrefix:@"RATE:"]) {
            int rate = [[trimmed substringFromIndex:5] intValue];
            if (rate > 0) [result setObject:@(rate) forKey:@"rate"];
            continue;
        }

        // PERIOD_SIZE: [min max]
        if ([trimmed hasPrefix:@"PERIOD_SIZE:"]) {
            NSString *range = [trimmed substringFromIndex:12];
            range = [range stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceCharacterSet]];
            // Strip brackets
            range = [range stringByReplacingOccurrencesOfString:@"[" withString:@""];
            range = [range stringByReplacingOccurrencesOfString:@"]" withString:@""];
            NSArray *parts = [range componentsSeparatedByString:@" "];
            if ([parts count] >= 2) {
                [result setObject:@([[parts objectAtIndex:0] intValue])
                          forKey:@"period_size_min"];
                [result setObject:@([[parts objectAtIndex:1] intValue])
                          forKey:@"period_size_max"];
            }
            continue;
        }

        // BUFFER_SIZE: [min max]
        if ([trimmed hasPrefix:@"BUFFER_SIZE:"]) {
            NSString *range = [trimmed substringFromIndex:12];
            range = [range stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceCharacterSet]];
            range = [range stringByReplacingOccurrencesOfString:@"[" withString:@""];
            range = [range stringByReplacingOccurrencesOfString:@"]" withString:@""];
            NSArray *parts = [range componentsSeparatedByString:@" "];
            if ([parts count] >= 2) {
                [result setObject:@([[parts objectAtIndex:0] intValue])
                          forKey:@"buffer_size_min"];
                [result setObject:@([[parts objectAtIndex:1] intValue])
                          forKey:@"buffer_size_max"];
            }
            continue;
        }

        // PERIODS: [min max]
        if ([trimmed hasPrefix:@"PERIODS:"]) {
            NSString *range = [trimmed substringFromIndex:8];
            range = [range stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceCharacterSet]];
            range = [range stringByReplacingOccurrencesOfString:@"[" withString:@""];
            range = [range stringByReplacingOccurrencesOfString:@"]" withString:@""];
            NSArray *parts = [range componentsSeparatedByString:@" "];
            if ([parts count] >= 2) {
                [result setObject:@([[parts objectAtIndex:0] intValue])
                          forKey:@"periods_min"];
                [result setObject:@([[parts objectAtIndex:1] intValue])
                          forKey:@"periods_max"];
            }
        }
    }

    return result;
}

- (NSString *)preferredFormatFromFormats:(NSArray *)formats
{
    // Priority: S24_3LE > S32_LE > S24_LE > S16_LE
    static NSArray *priority = nil;
    if (!priority) {
        priority = [[NSArray alloc] initWithObjects:
                    @"S24_3LE", @"S32_LE", @"S24_LE", @"S16_LE", nil];
    }
    for (NSString *fmt in priority) {
        if ([formats containsObject:fmt]) return fmt;
    }
    return @"S16_LE";
}

- (int)ipcKeyForCard:(int)cardIndex device:(int)deviceIndex
{
    // Deterministic unique key per card+device.
    // Range: 1024..~10000 (safe within dmix ipc_key range)
    return 1024 + cardIndex * 100 + deviceIndex * 10;
}

- (int)suggestedPeriodSizeFromMin:(int)min max:(int)max
{
    // Clamp 1024 to hardware limits, rounding to nearest power of 2 if needed.
    // Target: 1024 is a good balance of latency and throughput.
    if (1024 >= min && 1024 <= max) return 1024;
    if (1024 < min) {
        // Find next power of 2 >= min
        int v = 1;
        while (v < min) v <<= 1;
        return (v <= max) ? v : max;
    }
    // 1024 > max, use max
    return max;
}

- (int)suggestedBufferSizeFromMin:(int)min max:(int)max
{
    // Target: period_size * 4, clamped to hardware limits.
    // We don't know period_size here, so just return a sensible default
    // that's at least 4x the typical period. The caller adjusts.
    int target = 4096;
    if (target >= min && target <= max) return target;
    if (target < min) return min;
    return max;
}

- (NSString *)buildAsoundrcContent
{
    NSMutableString *content = [NSMutableString string];

    [content appendString:@"# ALSA configuration\n"];
    [content appendString:@"# Generated by Sound Preferences\n\n"];

    // Determine which devices to configure.
    // Use the same card for both if they match; otherwise separate.
    AudioDevice *outDev = defaultOutput;
    AudioDevice *inDev  = defaultInput;

    // Helper: get PCM suffix (stable CardID_DeviceIndex) for naming
    // our custom pcm blocks (dmix_<suffix>, <suffix>_cap, etc.)
    NSString *(^pcmSuffix)(AudioDevice *) = ^(AudioDevice *dev) {
        NSString *cid = [self cardIDForCardIndex:dev.cardIndex];
        if (!cid) cid = [NSString stringWithFormat:@"card%d", dev.cardIndex];
        // Replace spaces/hyphens with underscores for valid ALSA name
        cid = [cid stringByReplacingOccurrencesOfString:@" " withString:@"_"];
        cid = [cid stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
        return [NSString stringWithFormat:@"%@_%d", cid, dev.deviceIndex];
    };

    // Helper: probe capabilities for a device (playback or capture direction).
    // Tries /proc/asound/cardN/stream0 first (USB devices), falls back to
    // aplay/arecord --dump-hw-params which works for any device.
    NSDictionary *(^probeCaps)(AudioDevice *, NSString *) = ^NSDictionary *(AudioDevice *dev, NSString *direction) {
        // Try stream0 first (fast, no tool execution)
        NSDictionary *caps = [self parseStream0ForCard:dev.cardIndex];
        if (caps) {
            NSString *pfx = direction;
            NSNumber *ch = [caps objectForKey:[NSString stringWithFormat:@"%@_channels", pfx]];
            NSNumber *rate = [caps objectForKey:[NSString stringWithFormat:@"%@_rate", pfx]];
            NSArray *fmts = [caps objectForKey:[NSString stringWithFormat:@"%@_formats", pfx]];
            if (ch && rate) {
                NSMutableDictionary *result = [NSMutableDictionary dictionary];
                [result setObject:ch forKey:@"channels"];
                [result setObject:rate forKey:@"rate"];
                [result setObject:(fmts ?: @[@"S16_LE"]) forKey:@"formats"];
                return result;
            }
        }
        // Fallback: use dumpHWParams which works for all devices (non-USB HDA, HDMI)
        NSDictionary *dump = [self dumpHWParamsForCard:dev.cardIndex
                                               device:dev.deviceIndex
                                               stream:direction];
        if (dump) {
            NSNumber *ch = [dump objectForKey:@"channels"];
            NSNumber *rate = [dump objectForKey:@"rate"];
            NSArray *fmts = [dump objectForKey:@"formats"];
            if (ch && rate) {
                NSMutableDictionary *result = [NSMutableDictionary dictionary];
                [result setObject:ch forKey:@"channels"];
                [result setObject:rate forKey:@"rate"];
                [result setObject:(fmts ?: @[@"S16_LE"]) forKey:@"formats"];
                return result;
            }
        }
        return nil;
    };

    // Helper: get hardware constraints for a device direction
    NSDictionary *(^probeConstraints)(AudioDevice *, NSString *) = ^(AudioDevice *dev, NSString *direction) {
        return [self dumpHWParamsForCard:dev.cardIndex
                                 device:dev.deviceIndex
                                 stream:direction];
    };

    BOOL hasOutput = (outDev != nil);
    BOOL hasInput  = (inDev != nil);

    // ---- Default PCM (asym when both directions available) ----
    if (hasOutput && hasInput) {
        NSString *outSuffix = pcmSuffix(outDev);
        NSString *inSuffix  = pcmSuffix(inDev);
        NSString *outPcm    = [NSString stringWithFormat:@"plug:dmix_%@", outSuffix];
        NSString *inPcm     = [NSString stringWithFormat:@"plug:%@_cap", inSuffix];

        [content appendString:@"pcm.!default {\n"];
        [content appendString:@"    type asym\n"];
        [content appendFormat:@"    playback.pcm \"%@\"\n", outPcm];
        [content appendFormat:@"    capture.pcm \"%@\"\n", inPcm];
        [content appendString:@"}\n\n"];
    } else if (hasOutput) {
        NSString *outSuffix = pcmSuffix(outDev);
        [content appendString:@"pcm.!default {\n"];
        [content appendString:@"    type plug\n"];
        [content appendFormat:@"    slave.pcm \"plug:dmix_%@\"\n", outSuffix];
        [content appendString:@"}\n\n"];
    } else if (hasInput) {
        [content appendString:@"pcm.!default {\n"];
        [content appendString:@"    type plug\n"];
        [content appendString:@"    slave.pcm {\n"];
        [content appendFormat:@"        type hw\n"];
        [content appendFormat:@"        card %d\n", inDev.cardIndex];
        [content appendFormat:@"        device %d\n", inDev.deviceIndex];
        [content appendString:@"    }\n"];
        [content appendString:@"}\n\n"];
    }

    // ---- Control interface ----
    // Use the output device's card for the mixer, or input if no output.
    AudioDevice *ctlDev = outDev ?: inDev;
    if (ctlDev) {
        NSString *ctlCardId = [self cardIDForCardIndex:ctlDev.cardIndex];
        if (!ctlCardId) ctlCardId = [NSString stringWithFormat:@"%d", ctlDev.cardIndex];
        [content appendFormat:@"ctl.!default {\n"];
        [content appendFormat:@"    type hw\n"];
        [content appendFormat:@"    card %@\n", ctlCardId];
        [content appendFormat:@"}\n\n"];
    }

    // ---- Playback dmix block ----
    if (hasOutput) {
        NSDictionary *caps = probeCaps(outDev, @"playback");
        NSDictionary *constraints = probeConstraints(outDev, @"playback");

        int channels   = [[caps objectForKey:@"channels"] intValue];
        int rate       = [[caps objectForKey:@"rate"] intValue];
        NSArray *fmts  = [caps objectForKey:@"formats"];
        NSString *fmt  = [self preferredFormatFromFormats:fmts];
        int ipcKey     = [self ipcKeyForCard:outDev.cardIndex device:outDev.deviceIndex];

        // Clamp channels to reasonable range (2-8, default 2)
        if (channels < 2) channels = 2;
        if (channels > 8) channels = 8;

        // Default rate fallback
        if (rate <= 0) rate = 48000;

        // Period and buffer sizes from hardware constraints
        int psMin = [[constraints objectForKey:@"period_size_min"] intValue];
        int psMax = [[constraints objectForKey:@"period_size_max"] intValue];
        int bsMin = [[constraints objectForKey:@"buffer_size_min"] intValue];
        int bsMax = [[constraints objectForKey:@"buffer_size_max"] intValue];

        int periodSize = (psMin > 0 && psMax > 0)
            ? [self suggestedPeriodSizeFromMin:psMin max:psMax]
            : 1024;
        int bufferSize = (bsMin > 0 && bsMax > 0)
            ? [self suggestedBufferSizeFromMin:bsMin max:bsMax]
            : 4096;
        // Ensure buffer is at least 2x period
        if (bufferSize < periodSize * 2) bufferSize = periodSize * 2;
        if (bsMax > 0 && bufferSize > bsMax) bufferSize = bsMax;
        if (bsMin > 0 && bufferSize < bsMin) bufferSize = bsMin;

        NSString *outSuffix = pcmSuffix(outDev);

        [content appendFormat:@"# Playback dmix for %@\n", outDev.displayName ?: outDev.name];
        [content appendFormat:@"pcm.dmix_%@ {\n", outSuffix];
        [content appendFormat:@"    type dmix\n"];
        [content appendFormat:@"    ipc_key %d\n", ipcKey];
        [content appendFormat:@"    ipc_perm 0666\n"];
        [content appendFormat:@"    slave {\n"];
        [content appendFormat:@"        pcm {\n"];
        [content appendFormat:@"            type hw\n"];
        [content appendFormat:@"            card %d\n", outDev.cardIndex];
        [content appendFormat:@"            device %d\n", outDev.deviceIndex];
        [content appendFormat:@"        }\n"];
        [content appendFormat:@"        rate %d\n", rate];
        [content appendFormat:@"        format %@\n", fmt];
        [content appendFormat:@"        channels %d\n", channels];
        [content appendFormat:@"        period_size %d\n", periodSize];
        [content appendFormat:@"        buffer_size %d\n", bufferSize];
        [content appendFormat:@"    }\n"];
        [content appendFormat:@"}\n\n"];
    }

    // ---- Capture plug+hw block ----
    if (hasInput) {
        NSString *inSuffix = pcmSuffix(inDev);
        [content appendFormat:@"# Capture for %@\n", inDev.displayName ?: inDev.name];
        [content appendFormat:@"pcm.%@_cap {\n", inSuffix];
        [content appendFormat:@"    type plug\n"];
        [content appendFormat:@"    slave.pcm {\n"];
        [content appendFormat:@"        type hw\n"];
        [content appendFormat:@"        card %d\n", inDev.cardIndex];
        [content appendFormat:@"        device %d\n", inDev.deviceIndex];
        [content appendFormat:@"    }\n"];
        [content appendFormat:@"}\n"];
    }

    return content;
}

// Resolve a numeric card index to its stable ALSA card ID (string name)
// by reading /proc/asound/cards.  Returns nil on failure, in which case
// the caller should fall back to the numeric index.
- (NSString *)cardIDForCardIndex:(int)cardIndex
{
    NSString *cards = [NSString stringWithContentsOfFile:@"/proc/asound/cards"
                                                encoding:NSUTF8StringEncoding
                                                   error:NULL];
    if (!cards) return nil;

    // Format: " 0 [Audio          ]: USB-Audio - Bose USB Audio"
    NSString *pattern = [NSString stringWithFormat:@" %d [", cardIndex];
    NSRange r = [cards rangeOfString:pattern];
    if (r.location == NSNotFound) return nil;

    NSUInteger start = r.location + r.length;
    NSRange close = [cards rangeOfString:@"]"
                                 options:0
                                   range:NSMakeRange(start, [cards length] - start)];
    if (close.location == NSNotFound) return nil;

    NSString *cardId = [cards substringWithRange:NSMakeRange(start, close.location - start)];
    cardId = [cardId stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
    return [cardId length] > 0 ? cardId : nil;
}

// Build a stable, cross-reboot device identifier from the ALSA card ID
// (a short device name like "Audio", "vc4hdmi0") and the subdevice index.
// Format: "<cardID>.<deviceIndex>"  e.g., "Audio.0", "vc4hdmi1.0"
//
// Unlike the numeric "hw:N,M" identifier, the card ID is a string name
// that the kernel assigns per physical device, so it survives hardware
// reordering.  For USB devices the kernel appends _1, _2 for duplicates.
- (NSString *)stableDeviceIdForCardIndex:(int)cardIndex
                             deviceIndex:(int)deviceIndex
{
    NSString *cardId = [self cardIDForCardIndex:cardIndex];
    if (!cardId) {
        // Fallback to numeric index if we can't read the card ID
        return [NSString stringWithFormat:@"hw:%d,%d", cardIndex, deviceIndex];
    }
    return [NSString stringWithFormat:@"%@.%d", cardId, deviceIndex];
}

// Reverse lookup: find an output device by its stable device ID.
- (AudioDevice *)outputDeviceWithStableId:(NSString *)stableId
{
    NSDebugLLog(@"gwcomp", @"ALSABackend: outputDeviceWithStableId: looking for '%@'", stableId);
    for (AudioDevice *dev in cachedOutputDevices) {
        NSDebugLLog(@"gwcomp", @"   cached device: stableDeviceId='%@' identifier='%@' name='%@'",
              dev.stableDeviceId, dev.identifier, dev.displayName);
        if ([dev.stableDeviceId isEqualToString:stableId]) {
            return dev;
        }
    }
    NSDebugLLog(@"gwcomp", @"   NOT FOUND");
    return nil;
}

// Reverse lookup: find an input device by its stable device ID.
- (AudioDevice *)inputDeviceWithStableId:(NSString *)stableId
{
    NSDebugLLog(@"gwcomp", @"ALSABackend: inputDeviceWithStableId: looking for '%@'", stableId);
    for (AudioDevice *dev in cachedInputDevices) {
        NSDebugLLog(@"gwcomp", @"   cached device: stableDeviceId='%@' identifier='%@' name='%@'",
              dev.stableDeviceId, dev.identifier, dev.displayName);
        if ([dev.stableDeviceId isEqualToString:stableId]) {
            return dev;
        }
    }
    NSDebugLLog(@"gwcomp", @"   NOT FOUND");
    return nil;
}

#pragma mark - Refresh

- (void)refresh
{
    // Remember stable IDs so we can re-resolve after re-enumeration
    NSString *savedOutputId = [defaultOutput.stableDeviceId copy];
    NSString *savedInputId = [defaultInput.stableDeviceId copy];
    NSString *savedAlertId = [alertDevice.stableDeviceId copy];
    int oldOutputCard = currentOutputCard;
    int oldInputCard = currentInputCard;

    [self enumerateDevices];

    // Re-resolve defaults against the new device list so that
    // defaultOutput/defaultInput still point to live objects in
    // cachedOutputDevices (the old ones were released by removeAllObjects).
    if (savedOutputId) {
        AudioDevice *dev = [self outputDeviceWithStableId:savedOutputId];
        if (dev) {
            [defaultOutput release];
            defaultOutput = [dev retain];
            currentOutputCard = dev.cardIndex;
        } else {
            // Fallback: try old card index (device might have been removed)
            for (AudioDevice *d in cachedOutputDevices) {
                if (d.cardIndex == oldOutputCard) {
                    [defaultOutput release];
                    defaultOutput = [d retain];
                    currentOutputCard = d.cardIndex;
                    break;
                }
            }
        }
    }
    if (savedInputId) {
        AudioDevice *dev = [self inputDeviceWithStableId:savedInputId];
        if (dev) {
            [defaultInput release];
            defaultInput = [dev retain];
            currentInputCard = dev.cardIndex;
        } else {
            for (AudioDevice *d in cachedInputDevices) {
                if (d.cardIndex == oldInputCard) {
                    [defaultInput release];
                    defaultInput = [d retain];
                    currentInputCard = d.cardIndex;
                    break;
                }
            }
        }
    }
    if (savedAlertId) {
        AudioDevice *dev = [self outputDeviceWithStableId:savedAlertId];
        if (dev) {
            [alertDevice release];
            alertDevice = [dev retain];
        }
    }
    [savedOutputId release];
    [savedInputId release];
    [savedAlertId release];

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

    // Wrap in @autoreleasepool to ensure NSPipe file handles and other
    // temporary objects are released promptly.  Without this, objects
    // created on GCD queue threads (which lack an automatic autorelease
    // pool drain) accumulate and leak file descriptors, eventually
    // hitting the "Too many open files" limit.
    NSString *result = nil;
    @autoreleasepool {
        NSTask *task = [[NSTask alloc] init];
        NSPipe *pipe = [NSPipe pipe];
        NSPipe *errorPipe = [NSPipe pipe];

        [task setLaunchPath:command];
        [task setArguments:args];
        [task setStandardOutput:pipe];
        [task setStandardError:errorPipe];

        // Force C locale so parsing of aplay -l / arecord -l / amixer output
        // does not break on non-English systems.
        NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
        [env setObject:@"C" forKey:@"LC_ALL"];
        [task setEnvironment:env];
        [env release];

        @try {
            [task launch];
        } @catch (NSException *e) {
            NSDebugLLog(@"gwcomp", @"Failed to run command %@: %@", command, e);
            [task release];
            return nil;
        }

        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSData *errorData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];

        if ([task terminationStatus] != 0) {
            NSString *errorOutput = [[NSString alloc] initWithData:errorData 
                                                           encoding:NSUTF8StringEncoding];
            NSDebugLLog(@"gwcomp", @"Command %@ exited with status %d, stderr: %@", 
                  command, [task terminationStatus], errorOutput);
            [errorOutput release];
            [task release];
            return nil;
        }

        result = [[NSString alloc] initWithData:data
                                       encoding:NSUTF8StringEncoding];
        [task release];
    }
    return [result autorelease];
}

- (NSString *)runCommandWithPipe:(NSString *)command arguments:(NSArray *)args
{
    return [self runCommand:command withArguments:args];
}

- (void)reportErrorWithMessage:(NSString *)message
{
    NSDebugLLog(@"gwcomp", @"ALSABackend error: %@", message);
    
    if ([delegate respondsToSelector:@selector(soundBackend:didEncounterError:)]) {
        NSError *error = [NSError errorWithDomain:@"ALSABackend" 
                                             code:1 
                                         userInfo:@{NSLocalizedDescriptionKey: message}];
        [delegate soundBackend:self didEncounterError:error];
    }
}

@end

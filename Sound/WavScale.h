/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

/*
 * Shared alert-sound attenuation. The alert volume slider scales the PCM
 * samples of the sound file itself instead of touching the mixer, so only
 * the alert plays quieter while all other audio keeps its normal volume.
 * This mirrors the scaler in gershwin-eau-theme's NSBeep+Eau.m so that the
 * prefPane preview and theme alerts play at identical loudness.
 */

/* Returns a WAV blob identical to the input except with all samples
 * scaled by gain. Returns nil for containers or sample formats we do not
 * understand; callers then play the original file unscaled rather than
 * risk emitting garbage from an alert. */
NSData *SoundScaleWavData(NSData *wavData, float gain);

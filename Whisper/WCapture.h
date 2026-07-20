/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef WCAPTURE_H
#define WCAPTURE_H

#include <stdbool.h>

typedef struct {
    float *samples;
    int    n_samples;
    int    sample_rate;
} WCaptureData;

void   *wcapture_start(int sample_rate, const char *alsa_device);
WCaptureData *wcapture_stop(void *capture);
void    wcapture_cancel(void *capture);
void    wcapture_free_data(WCaptureData *data);
bool    wcapture_is_active(void *capture);

// Thread-safe: returns a copy of audio accumulated so far.
// Caller must free the returned samples with free().
// Returns number of samples, or 0 if no data.
int     wcapture_snapshot(void *capture, float **out_samples);

#endif

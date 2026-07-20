/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "WAudioLoader.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

WAudioData *waudio_load(const char *path)
{
    if (!path) return NULL;

    // Use ffmpeg to decode any audio file to 16 kHz mono float PCM
    char cmd[4096];
    int n = snprintf(cmd, sizeof(cmd),
        "ffmpeg -i '%s' -f f32le -acodec pcm_f32le -ar 16000 -ac 1 pipe:1 2>/dev/null",
        path);
    if (n < 0 || (size_t)n >= sizeof(cmd)) return NULL;

    FILE *fp = popen(cmd, "r");
    if (!fp) return NULL;

    // Read raw float samples (grow as needed)
    size_t cap = 65536;
    float *samples = (float *)malloc(cap * sizeof(float));
    size_t len = 0;

    if (!samples) { pclose(fp); return NULL; }

    while (1) {
        size_t space = cap - len;
        if (space < 4096) {
            cap *= 2;
            float *tmp = (float *)realloc(samples, cap * sizeof(float));
            if (!tmp) { free(samples); pclose(fp); return NULL; }
            samples = tmp;
            space = cap - len;
        }
        size_t got = fread(samples + len, sizeof(float), space, fp);
        if (got == 0) break;
        len += got;
    }

    int status = pclose(fp);
    if (status != 0 || len == 0) {
        free(samples);
        return NULL;
    }

    WAudioData *audio = (WAudioData *)calloc(1, sizeof(WAudioData));
    if (!audio) { free(samples); return NULL; }

    audio->samples     = samples;
    audio->n_samples   = (int)len;
    audio->sample_rate = 16000;

    return audio;
}

void waudio_free(WAudioData *audio)
{
    if (audio) {
        free(audio->samples);
        free(audio);
    }
}

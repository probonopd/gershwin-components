/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#ifndef WAUDIO_LOADER_H
#define WAUDIO_LOADER_H

#include <stdbool.h>

typedef struct {
    float *samples;
    int    n_samples;
    int    sample_rate;
} WAudioData;

WAudioData *waudio_load(const char *path);
void        waudio_free(WAudioData *audio);

#endif

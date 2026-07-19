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

#include "miniaudio.h"

WAudioData *waudio_load(const char *path)
{
    if (!path) return NULL;

    ma_decoder decoder;
    ma_result result;

    result = ma_decoder_init_file(path, NULL, &decoder);
    if (result != MA_SUCCESS) {
        fprintf(stderr, "waudio_load: failed to open %s (%s)\n",
                path, ma_result_description(result));
        return NULL;
    }

    ma_uint64 frame_count;
    result = ma_decoder_get_length_in_pcm_frames(&decoder, &frame_count);
    if (result != MA_SUCCESS) {
        fprintf(stderr, "waudio_load: failed to get length (%s)\n",
                ma_result_description(result));
        ma_decoder_uninit(&decoder);
        return NULL;
    }

    ma_uint32 channels = decoder.outputChannels;
    ma_uint32 sample_rate = decoder.outputSampleRate;

    float *pcm = (float *)calloc(frame_count * channels, sizeof(float));
    if (!pcm) {
        ma_decoder_uninit(&decoder);
        return NULL;
    }

    ma_uint64 frames_read;
    result = ma_decoder_read_pcm_frames(&decoder, pcm, frame_count, &frames_read);
    if (result != MA_SUCCESS) {
        fprintf(stderr, "waudio_load: failed to read PCM (%s)\n",
                ma_result_description(result));
        free(pcm);
        ma_decoder_uninit(&decoder);
        return NULL;
    }

    ma_decoder_uninit(&decoder);

    // Downmix to mono if needed
    float *mono;
    int n_samples;

    if (channels == 1) {
        mono = pcm;
        n_samples = (int)frames_read;
    } else {
        n_samples = (int)frames_read;
        mono = (float *)calloc(n_samples, sizeof(float));
        if (!mono) {
            free(pcm);
            return NULL;
        }
        for (int i = 0; i < n_samples; i++) {
            double sum = 0.0;
            for (ma_uint64 c = 0; c < channels; c++) {
                sum += pcm[i * channels + c];
            }
            mono[i] = (float)(sum / channels);
        }
        free(pcm);
    }

    WAudioData *audio = (WAudioData *)calloc(1, sizeof(WAudioData));
    if (!audio) {
        free(mono);
        return NULL;
    }

    audio->samples = mono;
    audio->n_samples = n_samples;
    audio->sample_rate = (int)sample_rate;

    return audio;
}

void waudio_free(WAudioData *audio)
{
    if (audio) {
        free(audio->samples);
        free(audio);
    }
}

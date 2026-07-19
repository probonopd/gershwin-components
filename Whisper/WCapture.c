/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "WCapture.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <pthread.h>
#include <math.h>

#include "miniaudio.h"

#define INITIAL_CAPACITY (16000 * 10) // 10 seconds at 16kHz
#define CAPACITY_GROWTH  16000        // grow by 1-second chunks

typedef struct {
    ma_device   device;
    float      *buffer;
    int         capacity;
    int         n_samples;
    int         sample_rate;
    int         running;
    pthread_mutex_t mutex;
} WCapture;

static int callback_count = 0;

static void capture_callback(ma_device *pDevice, void *pOutput,
                             const void *pInput, ma_uint32 frameCount)
{
    WCapture *cap = (WCapture *)pDevice->pUserData;
    if (!cap || !cap->running) return;

    if (pInput == NULL) {
        fprintf(stderr, "[WCapture] capture_callback: pInput is NULL!\n");
        return;
    }

    callback_count++;

    pthread_mutex_lock(&cap->mutex);

    int new_n = cap->n_samples + (int)frameCount;

    if (new_n > cap->capacity) {
        int new_cap = cap->capacity + CAPACITY_GROWTH;
        while (new_cap < new_n) new_cap += CAPACITY_GROWTH;
        float *nb = (float *)realloc(cap->buffer, new_cap * sizeof(float));
        if (!nb) { pthread_mutex_unlock(&cap->mutex); return; }
        cap->buffer = nb;
        cap->capacity = new_cap;
    }

    const float *in = (const float *)pInput;
    if (pDevice->capture.channels == 1) {
        memcpy(cap->buffer + cap->n_samples, in,
               frameCount * sizeof(float));
    } else {
        for (ma_uint32 i = 0; i < frameCount; i++) {
            double sum = 0.0;
            for (ma_uint32 c = 0; c < pDevice->capture.channels; c++) {
                sum += in[i * pDevice->capture.channels + c];
            }
            cap->buffer[cap->n_samples + i] = (float)(sum / pDevice->capture.channels);
        }
    }

    cap->n_samples = new_n;
    pthread_mutex_unlock(&cap->mutex);

    // Log periodically (every 100th callback ≈ every 3s at 512 frames/16kHz)
    if (callback_count % 100 == 1) {
        // Check peak amplitude in this chunk
        float peak = 0.0f;
        for (ma_uint32 i = 0; i < frameCount; i++) {
            float absv = fabsf(in[i]);
            if (absv > peak) peak = absv;
        }
        fprintf(stderr, "[WCapture] callback #%d: %u frames, "
                "channels=%u, peak=%.6f, total_samples=%d\n",
                callback_count, frameCount,
                pDevice->capture.channels, peak, cap->n_samples);
    }
}

void *wcapture_start(int sample_rate)
{
    // Suppress ALSA error spew when no capture device is available
    void *alsah = dlopen("libasound.so", RTLD_LAZY | RTLD_NOLOAD);
    if (alsah) {
        void (*set_handler)(void *) = dlsym(alsah, "snd_lib_error_set_handler");
        if (set_handler) set_handler(NULL);
        dlclose(alsah);
    }

    WCapture *cap = (WCapture *)calloc(1, sizeof(WCapture));
    if (!cap) return NULL;

    cap->sample_rate = sample_rate;
    cap->buffer = (float *)malloc(INITIAL_CAPACITY * sizeof(float));
    if (!cap->buffer) { free(cap); return NULL; }
    cap->capacity = INITIAL_CAPACITY;
    cap->n_samples = 0;
    cap->running = 1;
    pthread_mutex_init(&cap->mutex, NULL);

    ma_device_config config = ma_device_config_init(ma_device_type_capture);
    config.capture.format   = ma_format_f32;
    config.capture.channels = 1;
    config.sampleRate       = (ma_uint32)sample_rate;
    config.dataCallback     = capture_callback;
    config.pUserData        = cap;

    ma_result result = ma_device_init(NULL, &config, &cap->device);
    if (result != MA_SUCCESS) {
        fprintf(stderr, "[WCapture] ma_device_init failed (%s)\n",
                ma_result_description(result));
        free(cap->buffer);
        free(cap);
        return NULL;
    }

    fprintf(stderr, "[WCapture] device initialized: capture format=%d, "
            "channels=%d, sample_rate=%d\n",
            cap->device.capture.internalFormat,
            cap->device.capture.internalChannels,
            cap->device.sampleRate);

    result = ma_device_start(&cap->device);
    if (result != MA_SUCCESS) {
        fprintf(stderr, "[WCapture] ma_device_start failed (%s)\n",
                ma_result_description(result));
        ma_device_uninit(&cap->device);
        free(cap->buffer);
        free(cap);
        return NULL;
    }

    fprintf(stderr, "[WCapture] capture started successfully\n");
    callback_count = 0;
    return cap;
}

WCaptureData *wcapture_stop(void *capture)
{
    if (!capture) return NULL;
    WCapture *cap = (WCapture *)capture;

    cap->running = 0;
    ma_device_stop(&cap->device);
    ma_device_uninit(&cap->device);

    pthread_mutex_lock(&cap->mutex);

    if (cap->n_samples == 0) {
        fprintf(stderr, "[WCapture] stop: no samples captured\n");
        pthread_mutex_unlock(&cap->mutex);
        pthread_mutex_destroy(&cap->mutex);
        free(cap->buffer);
        free(cap);
        return NULL;
    }

    // Compute peak amplitude across entire buffer
    float peak = 0.0f;
    for (int i = 0; i < cap->n_samples; i++) {
        float absv = fabsf(cap->buffer[i]);
        if (absv > peak) peak = absv;
    }

    fprintf(stderr, "[WCapture] stop: %d samples at %d Hz, "
            "peak=%.6f, callback_count=%d\n",
            cap->n_samples, cap->sample_rate, peak, callback_count);

    WCaptureData *data = (WCaptureData *)calloc(1, sizeof(WCaptureData));
    if (!data) {
        pthread_mutex_unlock(&cap->mutex);
        pthread_mutex_destroy(&cap->mutex);
        free(cap->buffer);
        free(cap);
        return NULL;
    }

    data->samples     = cap->buffer;
    data->n_samples   = cap->n_samples;
    data->sample_rate = cap->sample_rate;

    pthread_mutex_unlock(&cap->mutex);
    pthread_mutex_destroy(&cap->mutex);
    free(cap);
    return data;
}

void wcapture_cancel(void *capture)
{
    if (!capture) return;
    WCapture *cap = (WCapture *)capture;

    cap->running = 0;
    ma_device_stop(&cap->device);
    ma_device_uninit(&cap->device);
    pthread_mutex_destroy(&cap->mutex);
    free(cap->buffer);
    free(cap);
}

void wcapture_free_data(WCaptureData *data)
{
    if (data) {
        free(data->samples);
        free(data);
    }
}

bool wcapture_is_active(void *capture)
{
    if (!capture) return false;
    return ((WCapture *)capture)->running != 0;
}

int wcapture_snapshot(void *capture, float **out_samples)
{
    if (!capture || !out_samples) return 0;
    WCapture *cap = (WCapture *)capture;

    pthread_mutex_lock(&cap->mutex);
    int n = cap->n_samples;
    if (n == 0) {
        fprintf(stderr, "[WCapture] snapshot: no samples yet\n");
        pthread_mutex_unlock(&cap->mutex);
        *out_samples = NULL;
        return 0;
    }

    // Check peak
    float peak = 0.0f;
    for (int i = 0; i < n; i++) {
        float absv = fabsf(cap->buffer[i]);
        if (absv > peak) peak = absv;
    }

    fprintf(stderr, "[WCapture] snapshot: %d samples, peak=%.6f\n",
            n, peak);

    float *copy = (float *)malloc(n * sizeof(float));
    if (!copy) {
        pthread_mutex_unlock(&cap->mutex);
        *out_samples = NULL;
        return 0;
    }
    memcpy(copy, cap->buffer, n * sizeof(float));
    pthread_mutex_unlock(&cap->mutex);

    *out_samples = copy;
    return n;
}

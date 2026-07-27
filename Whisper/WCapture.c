/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Audio capture using ffmpeg via pipe (cross-platform ALSA/OSS/Pulse).
 */

#include "WCapture.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#include <sys/wait.h>
#include <errno.h>
#include <math.h>

#define INITIAL_CAPACITY (16000 * 10)
#define CAPACITY_GROWTH  16000
#define READ_BUF_SIZE    4096

typedef struct {
    pid_t       pid;
    int         fd;
    float      *buffer;
    int         capacity;
    int         n_samples;
    int         sample_rate;
    int         running;
    pthread_t   thread;
    pthread_mutex_t mutex;
} WCapture;

static int log_counter = 0;

static void *reader_thread(void *arg)
{
    WCapture *cap = (WCapture *)arg;
    float fbuf[READ_BUF_SIZE];

    while (cap->running) {
        ssize_t n = read(cap->fd, fbuf, sizeof(fbuf));
        if (n <= 0) {
            if (n == 0) break;
            if (errno == EINTR || errno == EAGAIN) continue;
            break;
        }

        int n_frames = (int)(n / sizeof(float));

        pthread_mutex_lock(&cap->mutex);
        int new_n = cap->n_samples + n_frames;
        if (new_n > cap->capacity) {
            int new_cap = cap->capacity + CAPACITY_GROWTH;
            while (new_cap < new_n) new_cap += CAPACITY_GROWTH;
            float *nb = realloc(cap->buffer, new_cap * sizeof(float));
            if (!nb) { pthread_mutex_unlock(&cap->mutex); break; }
            cap->buffer = nb;
            cap->capacity = new_cap;
        }
        memcpy(cap->buffer + cap->n_samples, fbuf, n_frames * sizeof(float));
        cap->n_samples = new_n;
        pthread_mutex_unlock(&cap->mutex);

        log_counter++;
        if (log_counter % 100 == 1) {
            float peak = 0.0f;
            for (int i = 0; i < n_frames; i++) {
                float a = fbuf[i] < 0 ? -fbuf[i] : fbuf[i];
                if (a > peak) peak = a;
            }
            fprintf(stderr, "[WCapture] read %d frames, peak=%.6f, total=%d\n",
                    n_frames, peak, cap->n_samples);
        }
    }
    return NULL;
}

void *wcapture_start(int sample_rate, const char *device)
{
    WCapture *cap = calloc(1, sizeof(WCapture));
    if (!cap) return NULL;

    cap->sample_rate = sample_rate;
    cap->buffer = malloc(INITIAL_CAPACITY * sizeof(float));
    if (!cap->buffer) { free(cap); return NULL; }
    cap->capacity = INITIAL_CAPACITY;
    cap->n_samples = 0;
    cap->running = 1;
    pthread_mutex_init(&cap->mutex, NULL);

    // Use ffmpeg to capture audio (cross-platform: ALSA, OSS, Pulse, etc.)
    int pfd[2];
    if (pipe(pfd) != 0) {
        free(cap->buffer); free(cap); return NULL;
    }

    cap->pid = fork();
    if (cap->pid == -1) {
        close(pfd[0]); close(pfd[1]);
        free(cap->buffer); free(cap); return NULL;
    }

    if (cap->pid == 0) {
        close(pfd[0]);
        dup2(pfd[1], STDOUT_FILENO);
        close(pfd[1]);

        char rate_str[16];
        snprintf(rate_str, sizeof(rate_str), "%d", sample_rate);

        // Build ffmpeg command
        // ffmpeg -f alsa -i <device> -ar <rate> -ac 1 -f f32le - 2>/dev/null
        char *argv[16];
        int ai = 0;
        argv[ai++] = "ffmpeg";
        argv[ai++] = "-hide_banner";
        argv[ai++] = "-loglevel";
        argv[ai++] = "error";

        // Determine audio input format
#if defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__)
        argv[ai++] = "-f"; argv[ai++] = "oss";
#else
        argv[ai++] = "-f"; argv[ai++] = "alsa";
#endif

        argv[ai++] = "-i";
        argv[ai++] = (char *)(device ? device : "default");
        argv[ai++] = "-ar";  argv[ai++] = rate_str;
        argv[ai++] = "-ac";  argv[ai++] = "1";
        argv[ai++] = "-f";   argv[ai++] = "f32le";
        argv[ai++] = "-";
        argv[ai] = NULL;

        execvp("ffmpeg", argv);
        _exit(1);
    }

    close(pfd[1]);
    cap->fd = pfd[0];
    pthread_create(&cap->thread, NULL, reader_thread, cap);
    fprintf(stderr, "[WCapture] started ffmpeg (pid=%d, rate=%d, device=%s)\n",
            cap->pid, sample_rate, device ? device : "default");
    log_counter = 0;
    return cap;
}

static void kill_capture(WCapture *cap)
{
    if (cap->pid > 0) {
        kill(cap->pid, SIGTERM);
        waitpid(cap->pid, NULL, WNOHANG);
        cap->pid = 0;
    }
}

WCaptureData *wcapture_stop(void *capture)
{
    if (!capture) return NULL;
    WCapture *cap = (WCapture *)capture;

    cap->running = 0;
    pthread_join(cap->thread, NULL);
    kill_capture(cap);
    if (cap->fd >= 0) close(cap->fd);

    pthread_mutex_lock(&cap->mutex);

    if (cap->n_samples == 0) {
        pthread_mutex_unlock(&cap->mutex);
        pthread_mutex_destroy(&cap->mutex);
        free(cap->buffer); free(cap);
        return NULL;
    }

    float peak = 0.0f;
    for (int i = 0; i < cap->n_samples; i++) {
        float a = cap->buffer[i] < 0 ? -cap->buffer[i] : cap->buffer[i];
        if (a > peak) peak = a;
    }
    fprintf(stderr, "[WCapture] stop: %d samples at %d Hz, peak=%.6f\n",
            cap->n_samples, cap->sample_rate, peak);

    WCaptureData *data = calloc(1, sizeof(WCaptureData));
    if (data) {
        data->samples     = cap->buffer;
        data->n_samples   = cap->n_samples;
        data->sample_rate = cap->sample_rate;
    }

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
    pthread_join(cap->thread, NULL);
    kill_capture(cap);
    if (cap->fd >= 0) close(cap->fd);
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

int wcapture_snapshot(void *capture, float **out_samples)
{
    if (!capture || !out_samples) return 0;
    WCapture *cap = (WCapture *)capture;
    pthread_mutex_lock(&cap->mutex);
    int n = cap->n_samples;
    if (n == 0) { pthread_mutex_unlock(&cap->mutex); return 0; }

    float *copy = malloc(n * sizeof(float));
    if (!copy) { pthread_mutex_unlock(&cap->mutex); return 0; }
    memcpy(copy, cap->buffer, n * sizeof(float));
    pthread_mutex_unlock(&cap->mutex);
    *out_samples = copy;
    return n;
}

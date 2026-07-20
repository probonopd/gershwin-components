/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Audio capture using arecord via pipe (no miniaudio dependency).
 * Launches arecord as a child process and reads raw PCM data.
 */

#include "WCapture.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <errno.h>
#include <math.h>
#include <sys/ioctl.h>
#include <sys/soundcard.h>

#define INITIAL_CAPACITY (16000 * 10) // 10 seconds at 16kHz
#define CAPACITY_GROWTH  16000        // grow by 1-second chunks
#define READ_BUF_SIZE    4096         // pipe read buffer (in samples)

typedef struct {
    pid_t       pid;
    int         fd;
    int         is_oss;        // 1 = OSS /dev/dsp, 0 = arecord pipe
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
    short ibuf[READ_BUF_SIZE];

    while (cap->running) {
        ssize_t n = read(cap->fd, ibuf, sizeof(ibuf));
        if (n <= 0) {
            if (n == 0) break; // EOF
            if (errno == EINTR || errno == EAGAIN) continue;
            break;
        }

        int n_frames = (int)(n / sizeof(short));

        pthread_mutex_lock(&cap->mutex);

        int new_n = cap->n_samples + n_frames;
        if (new_n > cap->capacity) {
            int new_cap = cap->capacity + CAPACITY_GROWTH;
            while (new_cap < new_n) new_cap += CAPACITY_GROWTH;
            float *nb = (float *)realloc(cap->buffer, new_cap * sizeof(float));
            if (!nb) { pthread_mutex_unlock(&cap->mutex); break; }
            cap->buffer = nb;
            cap->capacity = new_cap;
        }

        for (int i = 0; i < n_frames; i++) {
            cap->buffer[cap->n_samples + i] = ibuf[i] / 32768.0f;
        }
        cap->n_samples = new_n;

        pthread_mutex_unlock(&cap->mutex);

        log_counter++;
        if (log_counter % 100 == 1) {
            float peak = 0.0f;
            for (int i = 0; i < n_frames; i++) {
                float absv = fabsf(ibuf[i] / 32768.0f);
                if (absv > peak) peak = absv;
            }
            fprintf(stderr, "[WCapture] read %d frames, peak=%.6f, total=%d\n",
                    n_frames, peak, cap->n_samples);
        }
    }

    return NULL;
}

void *wcapture_start(int sample_rate, const char *device)
{
    WCapture *cap = (WCapture *)calloc(1, sizeof(WCapture));
    if (!cap) return NULL;

    cap->sample_rate = sample_rate;
    cap->buffer = (float *)malloc(INITIAL_CAPACITY * sizeof(float));
    if (!cap->buffer) { free(cap); return NULL; }
    cap->capacity = INITIAL_CAPACITY;
    cap->n_samples = 0;
    cap->running = 1;
    cap->is_oss = 0;
    pthread_mutex_init(&cap->mutex, NULL);

    // OSS: open /dev/dspN directly
    if (device && strncmp(device, "/dev/", 5) == 0) {
        cap->fd = open(device, O_RDONLY);
        if (cap->fd < 0) {
            fprintf(stderr, "[WCapture] failed to open %s\n", device);
            free(cap->buffer); free(cap); return NULL;
        }
        int fmt = AFMT_S16_LE;
        int ch  = 1;
        int sr  = sample_rate;
        ioctl(cap->fd, SNDCTL_DSP_SETFMT, &fmt);
        ioctl(cap->fd, SNDCTL_DSP_CHANNELS, &ch);
        ioctl(cap->fd, SNDCTL_DSP_SPEED, &sr);
        cap->is_oss = 1;
        pthread_create(&cap->thread, NULL, reader_thread, cap);
        fprintf(stderr, "[WCapture] OSS capture started (%s, rate=%d)\n",
                device, sample_rate);
        log_counter = 0;
        return cap;
    }

    // ALSA: fork arecord and read from pipe
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

        char *argv[12];
        int ai = 0;
        argv[ai++] = "arecord";
        if (device && device[0]) {
            argv[ai++] = "-D";
            argv[ai++] = (char *)device;
        }
        argv[ai++] = "-r";
        argv[ai++] = rate_str;
        argv[ai++] = "-c";
        argv[ai++] = "1";
        argv[ai++] = "-f";
        argv[ai++] = "S16_LE";
        argv[ai++] = "-t";
        argv[ai++] = "raw";
        argv[ai] = NULL;

        execvp("arecord", argv);
        if (device && device[0]) {
            fprintf(stderr, "[WCapture] arecord failed with device %s, "
                    "retrying without -D\n", device);
            argv[1] = argv[3];
            argv[2] = argv[4];
            argv[3] = argv[5];
            argv[4] = argv[6];
            argv[5] = argv[7];
            argv[6] = argv[8];
            argv[7] = argv[9];
            argv[8] = NULL;
            execvp("arecord", argv);
        }
        _exit(1);
    }

    close(pfd[1]);
    cap->fd = pfd[0];
    pthread_create(&cap->thread, NULL, reader_thread, cap);
    fprintf(stderr, "[WCapture] started arecord (pid=%d, rate=%d, device=%s)\n",
            cap->pid, sample_rate, device ? device : "default");
    log_counter = 0;
    return cap;
}

static void kill_arecord(WCapture *cap)
{
    if (cap->pid > 0) {
        kill(cap->pid, SIGTERM);
        int status;
        waitpid(cap->pid, &status, WNOHANG);
        cap->pid = 0;
    }
}

WCaptureData *wcapture_stop(void *capture)
{
    if (!capture) return NULL;
    WCapture *cap = (WCapture *)capture;

    cap->running = 0;
    pthread_join(cap->thread, NULL);
    kill_arecord(cap);
    if (cap->fd >= 0) close(cap->fd);

    pthread_mutex_lock(&cap->mutex);

    if (cap->n_samples == 0) {
        fprintf(stderr, "[WCapture] stop: no samples captured\n");
        pthread_mutex_unlock(&cap->mutex);
        pthread_mutex_destroy(&cap->mutex);
        free(cap->buffer);
        free(cap);
        return NULL;
    }

    float peak = 0.0f;
    for (int i = 0; i < cap->n_samples; i++) {
        float absv = fabsf(cap->buffer[i]);
        if (absv > peak) peak = absv;
    }

    fprintf(stderr, "[WCapture] stop: %d samples at %d Hz, peak=%.6f\n",
            cap->n_samples, cap->sample_rate, peak);

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
    pthread_join(cap->thread, NULL);
    kill_arecord(cap);
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
        pthread_mutex_unlock(&cap->mutex);
        *out_samples = NULL;
        return 0;
    }

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

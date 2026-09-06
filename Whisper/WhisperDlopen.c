/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include "WhisperDlopen.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>

static void *lib = NULL;

/* Function pointers — file scope so all wrappers can see them */
static __typeof__(&whisper_init_from_file_with_params) p_whisper_init_from_file;
static __typeof__(&whisper_free)                       p_whisper_free;
static __typeof__(&whisper_full_default_params)         p_whisper_full_default_params;
static __typeof__(&whisper_context_default_params)      p_whisper_context_default_params;
static __typeof__(&whisper_full)                        p_whisper_full;
static __typeof__(&whisper_full_n_segments)             p_whisper_full_n_segments;
static __typeof__(&whisper_full_get_segment_text)       p_whisper_full_get_segment_text;
static __typeof__(&whisper_full_get_segment_t0)         p_whisper_full_get_segment_t0;
static __typeof__(&whisper_full_get_segment_t1)         p_whisper_full_get_segment_t1;
static __typeof__(&whisper_lang_auto_detect)            p_whisper_lang_auto_detect;
static __typeof__(&whisper_lang_str)                    p_whisper_lang_str;
static __typeof__(&whisper_pcm_to_mel)                  p_whisper_pcm_to_mel;

void wdlopen_close(void)
{
  if (lib) { dlclose(lib); lib = NULL; }
}

bool wdlopen_init(void)
{
  if (lib) return true;
  lib = dlopen("libwhisper.so", RTLD_LAZY | RTLD_GLOBAL);
  if (!lib) lib = dlopen("/usr/local/lib/libwhisper.so", RTLD_LAZY | RTLD_GLOBAL);
  if (!lib) {
    fprintf(stderr, "wdlopen: cannot load libwhisper.so: %s\n", dlerror());
    return false;
  }

  p_whisper_init_from_file        = dlsym(lib, "whisper_init_from_file_with_params");
  p_whisper_free                  = dlsym(lib, "whisper_free");
  p_whisper_full_default_params   = dlsym(lib, "whisper_full_default_params");
  p_whisper_context_default_params= dlsym(lib, "whisper_context_default_params");
  p_whisper_full                  = dlsym(lib, "whisper_full");
  p_whisper_full_n_segments       = dlsym(lib, "whisper_full_n_segments");
  p_whisper_full_get_segment_text = dlsym(lib, "whisper_full_get_segment_text");
  p_whisper_full_get_segment_t0   = dlsym(lib, "whisper_full_get_segment_t0");
  p_whisper_full_get_segment_t1   = dlsym(lib, "whisper_full_get_segment_t1");
  p_whisper_lang_auto_detect      = dlsym(lib, "whisper_lang_auto_detect");
  p_whisper_lang_str              = dlsym(lib, "whisper_lang_str");
  p_whisper_pcm_to_mel            = dlsym(lib, "whisper_pcm_to_mel");

  if (!p_whisper_init_from_file || !p_whisper_free || !p_whisper_full) {
    fprintf(stderr, "wdlopen: missing core symbols\n");
    dlclose(lib); lib = NULL; return false;
  }
  return true;
}

void wdlopen_free(struct whisper_context *ctx) { p_whisper_free(ctx); }

struct whisper_context *wdlopen_init_from_file(const char *path,
    struct whisper_context_params params) {
  return p_whisper_init_from_file(path, params);
}

struct whisper_full_params wdlopen_full_default_params(
    enum whisper_sampling_strategy strategy) {
  return p_whisper_full_default_params(strategy);
}

struct whisper_context_params wdlopen_context_default_params(void) {
  return p_whisper_context_default_params();
}

int wdlopen_full(struct whisper_context *ctx,
    struct whisper_full_params params,
    const float *samples, int n_samples) {
  return p_whisper_full(ctx, params, samples, n_samples);
}

int wdlopen_full_n_segments(struct whisper_context *ctx) {
  return p_whisper_full_n_segments(ctx);
}

const char *wdlopen_full_get_segment_text(struct whisper_context *ctx, int i) {
  return p_whisper_full_get_segment_text(ctx, i);
}

int64_t wdlopen_full_get_segment_t0(struct whisper_context *ctx, int i) {
  return p_whisper_full_get_segment_t0(ctx, i);
}

int64_t wdlopen_full_get_segment_t1(struct whisper_context *ctx, int i) {
  return p_whisper_full_get_segment_t1(ctx, i);
}

int wdlopen_lang_auto_detect(struct whisper_context *ctx,
    int offset_ms, int n_threads, float *langprobs) {
  return p_whisper_lang_auto_detect(ctx, offset_ms, n_threads, langprobs);
}

const char *wdlopen_lang_str(int id) {
  return p_whisper_lang_str(id);
}

void wdlopen_pcm_to_mel(struct whisper_context *ctx,
    const float *samples, int n_samples, int n_threads) {
  p_whisper_pcm_to_mel(ctx, samples, n_samples, n_threads);
}

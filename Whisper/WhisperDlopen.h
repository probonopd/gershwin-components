/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Thin wrapper around whisper.cpp loaded at runtime via dlopen.
 * No link-time dependency on libwhisper — only the header is needed.
 */

#ifndef WHISPER_DLOPEN_H
#define WHISPER_DLOPEN_H

#include <whisper.h>

bool          wdlopen_init(void);
void          wdlopen_free(struct whisper_context *ctx);
int           wdlopen_lang_auto_detect(struct whisper_context *ctx,
                  int offset_ms, int n_threads, float *langprobs);
const char   *wdlopen_lang_str(int id);
void          wdlopen_pcm_to_mel(struct whisper_context *ctx,
                  const float *samples, int n_samples, int n_threads);
struct whisper_context *wdlopen_init_from_file(const char *path,
                  struct whisper_context_params params);
struct whisper_full_params wdlopen_full_default_params(
                  enum whisper_sampling_strategy strategy);
int           wdlopen_full(struct whisper_context *ctx,
                  struct whisper_full_params params,
                  const float *samples, int n_samples);
int           wdlopen_full_n_segments(struct whisper_context *ctx);
const char   *wdlopen_full_get_segment_text(struct whisper_context *ctx, int i);
int64_t       wdlopen_full_get_segment_t0(struct whisper_context *ctx, int i);
int64_t       wdlopen_full_get_segment_t1(struct whisper_context *ctx, int i);
struct whisper_context_params wdlopen_context_default_params(void);
const char   *wdlopen_print_system_info(void);

#endif

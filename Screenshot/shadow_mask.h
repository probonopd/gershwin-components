/*
 * Copyright (c) 2026 Simon Peter
 *
 * Portions derived from gershwin-windowmanager URSCompositingManager.m
 * (MIT License, Copyright (c) 2020 Alessandro Sangiuliano).
 *
 * SPDX-License-Identifier: MIT
 */
#ifndef shadow_mask_h
#define shadow_mask_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Generate the drop-shadow alpha mask (A8) for a window of the given size,
 * using the exact same Gaussian parameters (radius, offsets, opacity) as the
 * window manager compositor.  The caller can therefore predict which captured
 * pixels belong to the shadow and assign them matching alpha values.
 *
 * Returns a calloc'd buffer of *mask_width x *mask_height bytes, or NULL.
 */
uint8_t *shadow_make_mask(int body_width, int body_height,
                          int *mask_width, int *mask_height);

/* Padding added around a window body by the compositor shadow:
 * the shadow picture is drawn at (x + SHADOW_OFFSET_X, y + SHADOW_OFFSET_Y)
 * with size (w + gaussianSize, h + gaussianSize). */
void shadow_padding(int *left, int *top, int *right, int *bottom);

#ifdef __cplusplus
}
#endif

#endif /* shadow_mask_h */

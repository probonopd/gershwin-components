/*
 * Copyright (c) 2026 Simon Peter
 *
 * Portions derived from gershwin-windowmanager URSCompositingManager.m
 * (MIT License, Copyright (c) 2020 Alessandro Sangiuliano).
 *
 * SPDX-License-Identifier: MIT
 */

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "shadow_mask.h"

/* Must match URSCompositingManager.m so the mask lines up with what the
 * compositor actually painted on screen. */
#define SHADOW_RADIUS 12
#define SHADOW_OFFSET_X -18
#define SHADOW_OFFSET_Y -10
#define SHADOW_OPACITY 0.40

/* Extra margin around the compositor shadow picture.  The Gaussian tail is
 * still a few alpha levels above zero at the compositor's own canvas edge;
 * without this band the shadow visibly touches the screenshot bounding box.
 * The mask fades linearly to zero across this band. */
#define SHADOW_EXTRA_MARGIN 16

static double *g_gaussian_map = NULL;
static int g_gaussian_size = 0;

static double gaussian(double r, double x, double y)
{
    return ((1.0 / (sqrt(2.0 * 3.14159265358979323846 * r)))
            * exp(-(x * x + y * y) / (2.0 * r * r)));
}

static double *make_gaussian_map(double r, int *size_out)
{
    int size = ((int)ceil(r * 3.0) + 1) & ~1;
    int center = size / 2;
    double *map = calloc(size * size, sizeof(double));
    if (!map)
        return NULL;

    double t = 0.0;
    for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
            double g = gaussian(r, (double)(x - center), (double)(y - center));
            t += g;
            map[y * size + x] = g;
        }
    }
    for (int i = 0; i < size * size; i++)
        map[i] /= t;

    *size_out = size;
    return map;
}

static double *get_gaussian_map(void)
{
    if (!g_gaussian_map)
        g_gaussian_map = make_gaussian_map((double)SHADOW_RADIUS, &g_gaussian_size);
    return g_gaussian_map;
}

/* Sum Gaussian values over the region where the kernel overlaps the window */
static uint8_t sum_gaussian(double *map, int map_size, double opacity,
                            int cx, int cy, int width, int height)
{
    int center = map_size / 2;

    int fx_start = center - cx;
    if (fx_start < 0)
        fx_start = 0;
    int fx_end = width + center - cx;
    if (fx_end > map_size)
        fx_end = map_size;

    int fy_start = center - cy;
    if (fy_start < 0)
        fy_start = 0;
    int fy_end = height + center - cy;
    if (fy_end > map_size)
        fy_end = map_size;

    double v = 0.0;
    for (int fy = fy_start; fy < fy_end; fy++) {
        for (int fx = fx_start; fx < fx_end; fx++)
            v += map[fy * map_size + fx];
    }

    if (v > 1.0)
        v = 1.0;

    return (uint8_t)(v * opacity * 255.0);
}

void shadow_padding(int *left, int *top, int *right, int *bottom)
{
    if (!get_gaussian_map()) {
        *left = *top = *right = *bottom = 0;
        return;
    }
    /* The shadow picture is drawn at (x + OFFSET_X, y + OFFSET_Y) with size
     * (w + gaussianSize, h + gaussianSize), plus the extra fade-out band. */
    *left = (SHADOW_OFFSET_X < 0 ? -SHADOW_OFFSET_X : 0) + SHADOW_EXTRA_MARGIN;
    *top = (SHADOW_OFFSET_Y < 0 ? -SHADOW_OFFSET_Y : 0) + SHADOW_EXTRA_MARGIN;
    *right = g_gaussian_size - (*left - SHADOW_EXTRA_MARGIN) + SHADOW_EXTRA_MARGIN;
    *bottom = g_gaussian_size - (*top - SHADOW_EXTRA_MARGIN) + SHADOW_EXTRA_MARGIN;
}

uint8_t *shadow_make_mask(int body_width, int body_height,
                          int *mask_width, int *mask_height)
{
    double *map = get_gaussian_map();
    if (!map || body_width <= 0 || body_height <= 0)
        return NULL;

    int gs = g_gaussian_size;
    int center = gs / 2;
    int swidth = body_width + gs;
    int sheight = body_height + gs;

    if (swidth < 1 || sheight < 1)
        return NULL;

    uint8_t *data = calloc(swidth * sheight, sizeof(uint8_t));
    if (!data)
        return NULL;

    uint8_t base_val = sum_gaussian(map, gs, SHADOW_OPACITY,
                                    center, center, body_width, body_height);
    memset(data, base_val, swidth * sheight);

    int ylimit = (gs < sheight / 2) ? gs : (sheight + 1) / 2;
    int xlimit = (gs < swidth / 2) ? gs : (swidth + 1) / 2;

    /* Corners */
    for (int y = 0; y < ylimit; y++) {
        for (int x = 0; x < xlimit; x++) {
            uint8_t d = sum_gaussian(map, gs, SHADOW_OPACITY,
                                     x - center, y - center,
                                     body_width, body_height);
            data[y * swidth + x] = d;
            data[(sheight - y - 1) * swidth + x] = d;
            data[(sheight - y - 1) * swidth + (swidth - x - 1)] = d;
            data[y * swidth + (swidth - x - 1)] = d;
        }
    }

    /* Top and bottom edges */
    int x_diff = swidth - gs * 2;
    if (x_diff > 0 && ylimit > 0) {
        for (int y = 0; y < ylimit; y++) {
            uint8_t d = sum_gaussian(map, gs, SHADOW_OPACITY,
                                     center, y - center, body_width, body_height);
            memset(&data[y * swidth + gs], d, x_diff);
            memset(&data[(sheight - y - 1) * swidth + gs], d, x_diff);
        }
    }

    /* Left and right edges */
    for (int x = 0; x < xlimit; x++) {
        uint8_t d = sum_gaussian(map, gs, SHADOW_OPACITY,
                                 x - center, center, body_width, body_height);
        for (int y = gs; y < sheight - gs; y++) {
            data[y * swidth + x] = d;
            data[y * swidth + (swidth - x - 1)] = d;
        }
    }

    /* Embed the core mask into a larger canvas with an extra fade-out band,
     * so alpha reaches zero before the bounding box edge. */
    int e = SHADOW_EXTRA_MARGIN;
    int cwidth = swidth + 2 * e;
    int cheight = sheight + 2 * e;
    uint8_t *canvas = calloc(cwidth * cheight, sizeof(uint8_t));
    if (!canvas) {
        free(data);
        return NULL;
    }

    for (int y = 0; y < cheight; y++) {
        for (int x = 0; x < cwidth; x++) {
            /* Chebyshev distance beyond the core edge (0 = inside core) */
            int dx = 0, dy = 0;
            if (x < e) dx = e - x;
            else if (x >= e + swidth) dx = x - (e + swidth - 1);
            if (y < e) dy = e - y;
            else if (y >= e + sheight) dy = y - (e + sheight - 1);
            int k = dx > dy ? dx : dy;

            int cx = x - e, cy = y - e;
            if (cx < 0) cx = 0;
            if (cy < 0) cy = 0;
            if (cx >= swidth) cx = swidth - 1;
            if (cy >= sheight) cy = sheight - 1;

            uint8_t v = data[cy * swidth + cx];
            if (k > 0)
                v = (uint8_t)(v * (e - k) / e);
            canvas[y * cwidth + x] = v;
        }
    }
    free(data);

    *mask_width = cwidth;
    *mask_height = cheight;
    return canvas;
}

/*
 * Decode a pkg-provides "provides.db" bigram database.
 *
 * pkg-provides (https://github.com/rosorio/pkg-provides) publishes, per
 * FreeBSD release/architecture, a database listing every file installed
 * by every package in the official repositories.  The database uses the
 * classic FreeBSD "locate" bigram encoding (see locate(1) / updatedb).
 *
 * Input:  provides.db on stdin (already xz-decompressed).
 * Output: one "package*path" line per installed file, in the same
 *         order as the source database.
 *
 * The bigram code below is taken verbatim from pkg-provides' bigram.c,
 * which in turn derives from FreeBSD's usr.bin/locate (BSD-4-Clause).
 */

/*
 * SPDX-License-Identifier: BSD-4-Clause
 *
 * Copyright (c) 1995 Wolfram Schneider <wosch@FreeBSD.org>. Berlin.
 * Copyright (c) 1989, 1993
 *  The Regents of the University of California.  All rights reserved.
 *
 * This code is derived from software contributed to Berkeley by
 * James A. Woods.
 */

#include <ctype.h>
#include <err.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <arpa/inet.h>
#include <sys/types.h>
#include <sys/param.h>

#define NBG		128		/* number of bigrams considered */
#define OFFSET		14		/* abs value of max likely diff */
#define PARITY		0200		/* parity bit */
#define SWITCH		30		/* switch code */
#define UMLAUT		31		/* an 8 bit char followed */

#define TO7BIT(x)	(x = x & SCHAR_MAX)

#define INTSIZE		(sizeof(int))

char separator = '\n';

int
check_bigram_char(int ch)
{
    if (ch == 0 ||
        (ch >= 32 && ch <= 127))
        return (ch);

    fprintf(stderr, "Provides database corrupted\n");
    exit(1);
}

int
getwf(FILE *fp)
{
    register int word, hword;

    word = getw(fp);

    if (word > MAXPATHLEN || word < -(MAXPATHLEN)) {
        hword = ntohl(word);
        if (hword > MAXPATHLEN || hword < -(MAXPATHLEN))
            errx(1, "integer out of +-MAXPATHLEN (%d): %u",
                MAXPATHLEN, abs(word) < abs(hword) ? word : hword);
        return (hword);
    }
    return (word);
}

int
bigram_expand(FILE *fp, int (*match_cb)(char *, void *), void *extra)
{
    register u_char *p, *s;
    register int c;
    int count;
    u_char bigram1[NBG], bigram2[NBG], path[MAXPATHLEN];

    for (c = 0, p = bigram1, s = bigram2; c < NBG; c++) {
        p[c] = check_bigram_char(getc(fp));
        s[c] = check_bigram_char(getc(fp));
    }

    count = 0;

    c = getc(fp);
    for (; c != EOF; ) {

        if (c == SWITCH) {
            count += getwf(fp) - OFFSET;
        } else {
            count += c - OFFSET;
        }

        if (count < 0 || count > MAXPATHLEN)
            return (-1);

        p = path + count;

        for (;;) {
            c = getc(fp);

            if (c < PARITY) {
                if (c <= UMLAUT) {
                    if (c == UMLAUT) {
                        c = getc(fp);
                    } else
                        break;
                }
                *p++ = c;
            } else {
                TO7BIT(c);

                *p++ = bigram1[c];
                *p++ = bigram2[c];
            }
        }
        *p-- = '\0';
        match_cb((char *)path, extra);
    }

    return (0);
}

static int
emit(char *path, void *extra)
{
    (void)extra;
    fwrite(path, 1, strlen(path), stdout);
    fputc('\n', stdout);
    return 0;
}

int
main(void)
{
    if (bigram_expand(stdin, emit, NULL) == -1) {
        fprintf(stderr, "corrupted database\n");
        return 1;
    }
    return 0;
}
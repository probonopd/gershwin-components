/*
 * AppRun.c — Compiled into a static binary, this is the entry point for
 * every AppImage produced by make_appimage.  It reads AppRun.plist from
 * the AppDir root for app-specific settings (main executable, theme),
 * sets up the environment, and execv's the main binary.
 *
 * Precompiled at make_appimage build time — no compiler needed when
 * packaging an app.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <libgen.h>
#include <stdio.h>
#include <limits.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <elf.h>

static void unsetenv_all(const char *vars[])
{
    for (int i = 0; vars[i]; i++)
        unsetenv(vars[i]);
}

static void *map_file(const char *path, size_t *len)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) < 0) { close(fd); return NULL; }
    *len = st.st_size;
    void *p = mmap(NULL, *len, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    return (p == MAP_FAILED) ? NULL : p;
}

/* Minimal plist reader — extracts <key>KEY</key><string>VAL</string> */
static int plist_get_string(const char *xml, size_t xmllen,
                            const char *key, char *out, size_t outsz)
{
    if (!xml || !key || !out || outsz < 1) return -1;
    out[0] = '\0';
    char ktag[1024];
    snprintf(ktag, sizeof(ktag), "<key>%s</key>", key);
    const char *kp = strstr(xml, ktag);
    if (!kp) return -1;
    kp += strlen(ktag);
    while (kp < xml + xmllen && (*kp == ' ' || *kp == '\n' || *kp == '\t'))
        kp++;
    if (kp + 8 >= xml + xmllen || strncmp(kp, "<string>", 8) != 0)
        return -1;
    kp += 8;
    const char *end = strstr(kp, "</string>");
    if (!end) return -1;
    size_t vlen = end - kp;
    if (vlen >= outsz) vlen = outsz - 1;
    memcpy(out, kp, vlen);
    out[vlen] = '\0';
    return 0;
}

int main(int argc, char *argv[])
{
    const char *interfering[] = {
        "LD_LIBRARY_PATH", "GNUSTEP_CONFIG_FILE",
        "GNUSTEP_USER_CONFIG_FILE", "GNUSTEP_USER_DIR",
        "GNUSTEP_USER_DEFAULTS_DIR", "GNUSTEP_SYSTEM_ROOT",
        "GNUSTEP_LOCAL_ROOT", "GNUSTEP_NETWORK_ROOT",
        "GNUSTEP_FLATTENED", "LD_PRELOAD", "LD_AUDIT",
        "LD_DEBUG", "LD_ORIGIN_PATH", NULL
    };
    unsetenv_all(interfering);

    char here[PATH_MAX];
    char self[PATH_MAX];
    ssize_t slen = readlink("/proc/self/exe", self, sizeof(self) - 1);
    if (slen > 0) {
        self[slen] = '\0';
        strncpy(here, dirname(self), sizeof(here) - 1);
    } else {
        strncpy(here, dirname(argv[0]), sizeof(here) - 1);
    }
    chdir(here);

    char plist_path[PATH_MAX];
    snprintf(plist_path, sizeof(plist_path), "%s/AppRun.plist", here);
    size_t plist_len;
    char *plist_xml = map_file(plist_path, &plist_len);
    if (!plist_xml) {
        fprintf(stderr, "AppRun: FATAL: missing %s\n", plist_path);
        return 1;
    }

    char mainExec[PATH_MAX];
    if (plist_get_string(plist_xml, plist_len, "mainExecutable",
                         mainExec, sizeof(mainExec)) != 0) {
        fprintf(stderr, "AppRun: FATAL: 'mainExecutable' not found\n");
        munmap(plist_xml, plist_len);
        return 1;
    }

    char theme[64] = "";
    plist_get_string(plist_xml, plist_len, "theme", theme, sizeof(theme));

    {
        // Only set GNUSTEP_CONFIG_FILE if the backend bundle is NOT
        // findable via the system's default GNUstep paths.  Setting
        // it unconditionally can cause "Tried to init dictionary with
        // nil value" in some apps (like Clock), because GNUstep's path
        // resolution with the config file differs from its compiled-in
        // defaults.
        // Check if any standard compile-time GNUSTEP_SYSTEM_ROOT
        // location has our backend.
        int backend_found = 0;
        const char *check_roots[] = {
            "/System/Library/Bundles/libgnustep-back-032.bundle",
            "/usr/lib/GNUstep/Library/Bundles/libgnustep-back-032.bundle",
            "/usr/local/lib/GNUstep/Library/Bundles/libgnustep-back-032.bundle",
            NULL
        };
        for (int i = 0; check_roots[i]; i++) {
            if (access(check_roots[i], F_OK) == 0) {
                backend_found = 1;
                break;
            }
        }
        if (!backend_found) {
            char cfg[PATH_MAX];
            snprintf(cfg, sizeof(cfg), "%s/usr/lib/GNUstep/GNUstep.conf", here);
            setenv("GNUSTEP_CONFIG_FILE", cfg, 1);
        }
    }

    if (theme[0])
        setenv("GNUSTEP_THEME", theme, 1);

    setenv("GNUSTEP_ROOT", here, 1);
    char sys[PATH_MAX]; snprintf(sys, sizeof(sys), "%s/System", here);
    setenv("GNUSTEP_SYSTEM_ROOT", sys, 1);
    char loc[PATH_MAX]; snprintf(loc, sizeof(loc), "%s/Local", here);
    setenv("GNUSTEP_LOCAL_ROOT", loc, 1);
    // X11 auth: bundled libX11 reads ~/.Xauthority.  Ensure XAUTHORITY
    // is set explicitly since HOME may not match the user's home dir.
    {
        const char *xa = getenv("XAUTHORITY");
        if (!xa) {
            char xa_path[PATH_MAX];
            snprintf(xa_path, sizeof(xa_path), "%s/.Xauthority",
                     getenv("HOME") ?: "/tmp");
            setenv("XAUTHORITY", xa_path, 0);
        }
    }

    // GNUSTEP_USER_DIR is intentionally NOT set.  Letting it default to
    // the user's home directory avoids "Tried to init dictionary with nil
    // value" errors in apps (like Clock) that read persisted defaults at
    // startup.  The home directory is writable and outside the squashfs.

    // LD_LIBRARY_PATH is NOT set in the environment — it would leak to child
    // processes (system commands, etc.) that are not part of the AppImage.
    // Instead we pass the library path as an argument to the bundled ld-linux
    // via --library-path, which scopes it to this process tree only.

    char p[PATH_MAX];
    snprintf(p, sizeof(p), "%s/usr/local/bin:%s/usr/bin:"
             "%s/System/Library/Tools:%s/Local/Library/Tools",
             here, here, here, here);
    setenv("PATH", p, 1);

    munmap(plist_xml, plist_len);

    char bin[PATH_MAX];
    snprintf(bin, sizeof(bin), "%s/%s", here, mainExec);

    /* Find the bundled ld-linux */
    char interp[PATH_MAX] = "";
    const char *candidates[] = {
        "/lib64/ld-linux-x86-64.so.2",
        "/lib/ld-linux-x86-64.so.2",
        "/lib/ld-linux.so.2",
        "/lib/ld-musl-x86_64.so.1",
        NULL
    };
    for (int i = 0; candidates[i]; i++) {
        snprintf(interp, sizeof(interp), "%s%s", here, candidates[i]);
        if (access(interp, F_OK) == 0) break;
        interp[0] = '\0';
    }
    if (interp[0] == '\0') {
        fprintf(stderr, "AppRun: FATAL: no ld-linux found in AppDir\n");
        return 1;
    }

    /* Build argv: ld-linux --library-path <dirs> --argv0 <name> <binary> [args] */
    char *new_argv[argc + 7];
    int ai = 0;
    new_argv[ai++] = interp;
    new_argv[ai++] = "--library-path";
    /* Compute library path: usr/lib + usr/local/lib + Resources dir */
    char libpath[PATH_MAX * 3];
    snprintf(libpath, sizeof(libpath), "%s/usr/lib:%s/usr/local/lib",
             here, here);
    char bin_dir[PATH_MAX];
    strncpy(bin_dir, bin, sizeof(bin_dir) - 1);
    char *last_slash = strrchr(bin_dir, '/');
    if (last_slash) {
        *last_slash = '\0';
        size_t llen = strlen(libpath);
        snprintf(libpath + llen, sizeof(libpath) - llen, ":%s/Resources", bin_dir);
    }
    new_argv[ai++] = libpath;
    new_argv[ai++] = "--argv0";
    new_argv[ai++] = bin;
    new_argv[ai++] = bin;
    for (int i = 1; i < argc; i++) new_argv[ai++] = argv[i];
    new_argv[ai] = NULL;

    execv(interp, new_argv);
    return 1;
}

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

    char cfg[PATH_MAX];
    snprintf(cfg, sizeof(cfg), "%s/usr/lib/GNUstep/GNUstep.conf", here);
    setenv("GNUSTEP_CONFIG_FILE", cfg, 1);

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

    // GNUSTEP_USER_DIR must point to a writable location.  The AppDir
    // is inside a read-only squashfs mount when run as an AppImage, so
    // use /tmp/<appname>-<pid> instead.
    {
        const char *base = getenv("HOME") ?: "/tmp";
        char ud[PATH_MAX];
        snprintf(ud, sizeof(ud), "%s/.cache/Gershwin/AppImage/%d",
                 base, (int)getpid());
        setenv("GNUSTEP_USER_DIR", ud, 1);
    }

    char ld[PATH_MAX];
    snprintf(ld, sizeof(ld), "%s/usr/lib:%s/usr/local/lib", here, here);
    setenv("LD_LIBRARY_PATH", ld, 1);

    char p[PATH_MAX];
    snprintf(p, sizeof(p), "%s/usr/local/bin:%s/usr/bin:"
             "%s/System/Library/Tools:%s/Local/Library/Tools",
             here, here, here, here);
    setenv("PATH", p, 1);

    munmap(plist_xml, plist_len);

    char bin[PATH_MAX];
    snprintf(bin, sizeof(bin), "%s/%s", here, mainExec);

    /* Also set LD_LIBRARY_PATH to include the app's Resources directory */
    {
        char ld_full[PATH_MAX * 2];
        strncpy(ld_full, ld, sizeof(ld_full) - 1);
        char bin_dir[PATH_MAX];
        strncpy(bin_dir, bin, sizeof(bin_dir) - 1);
        char *last_slash = strrchr(bin_dir, '/');
        if (last_slash) {
            *last_slash = '\0';
            size_t llen = strlen(ld_full);
            snprintf(ld_full + llen, sizeof(ld_full) - llen,
                     ":%s/Resources", bin_dir);
            setenv("LD_LIBRARY_PATH", ld_full, 1);
        }
    }

    /* Set argv[0] to the actual binary path so GNUstep can find Resources */
    char *new_argv[argc + 1];
    new_argv[0] = bin;
    for (int i = 1; i < argc; i++) new_argv[i] = argv[i];
    if (argc > 0) new_argv[argc] = NULL;

    /* The binary already has a relative interpreter set by patchelf --set-interpreter
       at build time.  Running execv directly lets the kernel load the bundled ld-linux
       via PT_INTERP.  cd to the AppDir first so the relative interpreter path resolves. */
    chdir(here);
    execv(bin, new_argv);
    return 1;
}

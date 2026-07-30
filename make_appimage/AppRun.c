/*
 * AppRun.c — Compiled into a static binary, this is the entry point for
 * every AppImage produced by make_appimage.  It reads AppRun.plist from
 * the AppDir root for app-specific settings (main executable, theme),
 * sets up the environment (LD_LIBRARY_PATH, GNUstep paths, X11 auth),
 * and execv's the main binary.
 *
 * Libraries are resolved via LD_LIBRARY_PATH + RPATH.  The bundled
 * ld-linux (interpreter) is set via patchelf --set-interpreter on
 * every ELF at build time — no need to invoke it explicitly here.
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
    snprintf(plist_path, sizeof(plist_path), "%s/Resources/AppRun.plist", here);
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

    setenv("GNUSTEP_ROOT", here, 1);
    char gs_root[PATH_MAX];
    snprintf(gs_root, sizeof(gs_root), "%s/Resources/GNUstep", here);
    setenv("GNUSTEP_SYSTEM_ROOT", gs_root, 1);
    setenv("GNUSTEP_LOCAL_ROOT", gs_root, 1);
    if (theme[0])
        setenv("GNUSTEP_THEME", theme, 1);

    // Always point to the bundled GNUstep.conf (inside Resources/GNUstep/)
    char cfg[PATH_MAX];
    snprintf(cfg, sizeof(cfg), "%s/Resources/GNUstep/GNUstep.conf", here);
    setenv("GNUSTEP_CONFIG_FILE", cfg, 1);

    {
        const char *xa = getenv("XAUTHORITY");
        if (!xa) {
            char xa_path[PATH_MAX];
            snprintf(xa_path, sizeof(xa_path), "%s/.Xauthority",
                     getenv("HOME") ?: "/tmp");
            setenv("XAUTHORITY", xa_path, 0);
        }
    }

    char p[PATH_MAX];
    snprintf(p, sizeof(p), "%s/Resources/GNUstep/Library/Tools",
             here);
    setenv("PATH", p, 1);

    char libpath[PATH_MAX * 3];
    snprintf(libpath, sizeof(libpath), "%s/Resources/GNUstep/Library/Libraries",
             here);
    char bin[PATH_MAX];
    snprintf(bin, sizeof(bin), "%s/%s", here, mainExec);
    char bin_dir[PATH_MAX];
    strncpy(bin_dir, bin, sizeof(bin_dir) - 1);
    char *last_slash = strrchr(bin_dir, '/');
    if (last_slash) {
        *last_slash = '\0';
        size_t llen = strlen(libpath);
        snprintf(libpath + llen, sizeof(libpath) - llen, ":%s/Resources", bin_dir);
    }
    setenv("LD_LIBRARY_PATH", libpath, 1);

    munmap(plist_xml, plist_len);

    /* Build argv: <binary> [-GSTheme <theme>] [args] */
    int extra = (theme[0]) ? 2 : 0;
    char *new_argv[argc + 1 + extra];
    int ai = 0;
    new_argv[ai++] = bin;
    if (theme[0]) {
        new_argv[ai++] = "-GSTheme";
        new_argv[ai++] = theme;
    }
    for (int i = 1; i < argc; i++) new_argv[ai++] = argv[i];
    new_argv[ai] = NULL;

    execv(bin, new_argv);
    return 1;
}

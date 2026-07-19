/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */
#import "KeyboardManager.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#if defined(__linux__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
#include <dirent.h>
#endif
#if !defined(__linux__)
#include <login_cap.h>
#if defined(__OpenBSD__)
#define GW_LOGIN_GETPWCLASS(p) login_getclass((p)->pw_class)
#else
#define GW_LOGIN_GETPWCLASS(p) login_getpwclass(p)
#endif
#endif
static NSMutableString *s_log = nil;

static void KbdLog(NSString *fmt, ...)
{
    if (!s_log) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [s_log appendString:msg];
    [msg release];
}

static const char *rpiKeyboardLanguage(int idx)
{
    static const char *langs[15] = {
        "en_GB.UTF-8", "en_GB.UTF-8", "fr_FR.UTF-8", "es_ES.UTF-8",
        "en_US.UTF-8", "de_DE.UTF-8", "it_IT.UTF-8", "ja_JP.UTF-8",
        "pt_PT.UTF-8", "nb_NO.UTF-8", "sv_SE.UTF-8", "fi_FI.UTF-8",
        "ru_RU.UTF-8", "tr_TR.UTF-8", "he_IL.UTF-8"
    };
    if (idx < 0 || idx > 14) return NULL;
    return langs[idx];
}
static const char *rpiKeyboardLayout(int idx)
{
    static const char *table[15] = {
        "gb", "gb", "fr", "es", "us", "de", "it",
        "jp", "pt", "no", "se", "dk", "ru", "tr", "il"
    };
    if (idx < 0 || idx > 14) return "gb";
    return table[idx];
}
static const char *rpiKeyboardVIDs[] = { "04d9", "2e8a", NULL };
static const char *rpiKeyboardPIDs[] = { "0006", "0010", NULL };
static BOOL detectKeyboardFromUSB(const char **layout,
                                  const char **variant,
                                  const char **options,
                                  const char **language)
{
#if defined(__linux__)
    KbdLog(@"    Scanning /sys/bus/usb/devices...\n");
    DIR *usb_dir = opendir("/sys/bus/usb/devices");
    if (!usb_dir) {
        KbdLog(@"    ✗ cannot open /sys/bus/usb/devices\n");
        return NO;
    }
    struct dirent *entry;
    int dev_count = 0;
    while ((entry = readdir(usb_dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;
        dev_count++;
        char path[512];
        char vendor[16] = "", id_product[16] = "", prod_str[256] = "";
        snprintf(path, sizeof(path), "/sys/bus/usb/devices/%s/idVendor",
                 entry->d_name);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        if (!fgets(vendor, sizeof(vendor), f)) { fclose(f); continue; }
        fclose(f);
        vendor[strcspn(vendor, "\n")] = '\0';
        snprintf(path, sizeof(path), "/sys/bus/usb/devices/%s/idProduct",
                 entry->d_name);
        f = fopen(path, "r");
        if (!f) continue;
        if (!fgets(id_product, sizeof(id_product), f)) { fclose(f); continue; }
        fclose(f);
        id_product[strcspn(id_product, "\n")] = '\0';
        BOOL known = NO;
        for (int i = 0; rpiKeyboardVIDs[i] && rpiKeyboardPIDs[i]; i++) {
            if (strcmp(vendor, rpiKeyboardVIDs[i]) == 0
                && strcmp(id_product, rpiKeyboardPIDs[i]) == 0) {
                known = YES;
                break;
            }
        }
        if (!known) continue;
        snprintf(path, sizeof(path), "/sys/bus/usb/devices/%s/product",
                 entry->d_name);
        f = fopen(path, "r");
        if (!f) continue;
        if (!fgets(prod_str, sizeof(prod_str), f)) { fclose(f); continue; }
        fclose(f);
        prod_str[strcspn(prod_str, "\n")] = '\0';
        KbdLog(@"    USB device: %s:%s product=\"%s\"\n", vendor, id_product, prod_str);
        BOOL is_rpi = (strstr(prod_str, "RPI") != NULL
                       || strstr(prod_str, "Raspberry") != NULL
                       || strstr(prod_str, "raspberry") != NULL
                       || strstr(prod_str, "Pi ") != NULL);
        if (!is_rpi) {
            KbdLog(@"      not an RPI keyboard, skipping\n");
            continue;
        }
        const char *last_space = strrchr(prod_str, ' ');
        int idx = 0;
        if (last_space) {
            const char *tok = last_space + 1;
            if (*tok < '0' || *tok > '9') {
                KbdLog(@"      no trailing index, deferring\n");
                continue;
            }
            idx = atoi(tok);
        }
        if (idx < 0 || idx > 14) idx = 0;
        *layout = rpiKeyboardLayout(idx);
        *variant = "";
        *options = "";
        if (language) *language = rpiKeyboardLanguage(idx);
        if (language && *language)
            KbdLog(@"      RPI keyboard index %d → layout=\"%s\" language=\"%s\"\n", idx, *layout, *language);
        else
            KbdLog(@"      RPI keyboard index %d → layout=\"%s\"\n", idx, *layout);
        closedir(usb_dir);
        return YES;
    }
    KbdLog(@"    %d USB device(s) scanned, no RPI keyboard found\n", dev_count);
    closedir(usb_dir);
#elif defined(__FreeBSD__)
    KbdLog(@"    Scanning USB devices via usbconfig...\n");
    FILE *usb_fp = popen("usbconfig list", "r");
    if (!usb_fp) {
        KbdLog(@"    ✗ cannot run 'usbconfig list'\n");
        (void)layout; (void)variant; (void)options; (void)language;
        return NO;
    }
    char line[512];
    BOOL found = NO;
    while (fgets(line, sizeof(line), usb_fp)) {
        char *nl = strchr(line, '\n');
        if (nl) *nl = '\0';
        char *colon = strchr(line, ':');
        if (!colon) continue;
        size_t ugen_len = colon - line;
        if (ugen_len < 3 || ugen_len >= 32) continue;
        char ugen[32];
        memcpy(ugen, line, ugen_len);
        ugen[ugen_len] = '\0';
        char desc_cmd[128];
        snprintf(desc_cmd, sizeof(desc_cmd),
                 "usbconfig -d %s dump_device_desc 2>/dev/null", ugen);
        FILE *desc_fp = popen(desc_cmd, "r");
        if (!desc_fp) continue;
        char vendor[16] = "", id_product[16] = "", prod_str[256] = "";
        char dl[256];
        while (fgets(dl, sizeof(dl), desc_fp)) {
            char *v;
            if ((v = strstr(dl, "idVendor = "))) {
                char *p = v + 11;
                while (*p == ' ') p++;
                if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
                    unsigned long val = strtoul(p + 2, NULL, 16);
                    snprintf(vendor, sizeof(vendor), "%04lx", val);
                }
            } else if ((v = strstr(dl, "idProduct = "))) {
                char *p = v + 12;
                while (*p == ' ') p++;
                if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
                    unsigned long val = strtoul(p + 2, NULL, 16);
                    snprintf(id_product, sizeof(id_product), "%04lx", val);
                }
            } else if ((v = strstr(dl, "iProduct"))) {
                char *start = strchr(dl, '<');
                char *end = strchr(dl, '>');
                if (start && end && end > start + 1) {
                    size_t len = end - start - 1;
                    if (len < sizeof(prod_str)) {
                        memcpy(prod_str, start + 1, len);
                        prod_str[len] = '\0';
                    }
                }
            }
        }
        pclose(desc_fp);
        if (!vendor[0] && !prod_str[0]) continue;
        BOOL known = NO;
        for (int i = 0; rpiKeyboardVIDs[i] && rpiKeyboardPIDs[i]; i++) {
            if (strcmp(vendor, rpiKeyboardVIDs[i]) == 0
                && strcmp(id_product, rpiKeyboardPIDs[i]) == 0) {
                known = YES;
                break;
            }
        }
        if (!known && prod_str[0]) {
            known = (strstr(prod_str, "RPI") != NULL
                     || strstr(prod_str, "Raspberry") != NULL
                     || strstr(prod_str, "raspberry") != NULL
                     || strstr(prod_str, "Pi ") != NULL);
        }
        if (!known) continue;
        KbdLog(@"    USB device: %s:%s product=\"%s\"\n", vendor, id_product, prod_str);
        const char *last_space = strrchr(prod_str, ' ');
        int idx = 0;
        if (last_space) {
            const char *tok = last_space + 1;
            if (*tok >= '0' && *tok <= '9') {
                idx = atoi(tok);
            } else {
                KbdLog(@"      no trailing index, deferring\n");
                continue;
            }
        }
        if (idx < 0 || idx > 14) idx = 0;
        *layout = rpiKeyboardLayout(idx);
        *variant = "";
        *options = "";
        if (language) *language = rpiKeyboardLanguage(idx);
        if (language && *language)
            KbdLog(@"      RPI keyboard index %d → layout=\"%s\" language=\"%s\"\n", idx, *layout, *language);
        else
            KbdLog(@"      RPI keyboard index %d → layout=\"%s\"\n", idx, *layout);
        found = YES;
        break;
    }
    pclose(usb_fp);
    if (!found) KbdLog(@"    No RPI keyboard found\n");
    if (!found) { (void)layout; (void)variant; (void)options; (void)language; }
    return found;
#elif defined(__OpenBSD__) || defined(__NetBSD__)
    KbdLog(@"    Scanning USB devices via usbdevs...\n");
    FILE *usb_fp = popen("usbdevs -v", "r");
    if (!usb_fp) {
        KbdLog(@"    ✗ cannot run 'usbdevs -v'\n");
        (void)layout; (void)variant; (void)options; (void)language;
        return NO;
    }
    char line[512];
    BOOL found = NO;
    while (fgets(line, sizeof(line), usb_fp)) {
        char *nl = strchr(line, '\n');
        if (nl) *nl = '\0';
        BOOL known_vid = NO;
        for (int i = 0; rpiKeyboardVIDs[i] && rpiKeyboardPIDs[i]; i++) {
            if (strstr(line, rpiKeyboardVIDs[i]) && strstr(line, rpiKeyboardPIDs[i])) {
                known_vid = YES;
                break;
            }
        }
        if (!known_vid) continue;
        BOOL is_rpi = (strstr(line, "RPI") != NULL
                       || strstr(line, "Raspberry") != NULL
                       || strstr(line, "raspberry") != NULL
                       || strstr(line, "Pi ") != NULL);
        KbdLog(@"    USB device: %s\n", line);
        if (!is_rpi) {
            KbdLog(@"      not an RPI keyboard, skipping\n");
            continue;
        }
        const char *last_space = strrchr(line, ' ');
        int idx = 0;
        if (last_space) {
            const char *tok = last_space + 1;
            if (*tok >= '0' && *tok <= '9') {
                idx = atoi(tok);
            } else {
                KbdLog(@"      no trailing index, deferring\n");
                continue;
            }
        }
        if (idx < 0 || idx > 14) idx = 0;
        *layout = rpiKeyboardLayout(idx);
        *variant = "";
        *options = "";
        if (language) *language = rpiKeyboardLanguage(idx);
        if (language && *language)
            KbdLog(@"      RPI keyboard index %d → layout=\"%s\" language=\"%s\"\n", idx, *layout, *language);
        else
            KbdLog(@"      RPI keyboard index %d → layout=\"%s\"\n", idx, *layout);
        found = YES;
        break;
    }
    pclose(usb_fp);
    if (!found) KbdLog(@"    No RPI keyboard found\n");
    if (!found) { (void)layout; (void)variant; (void)options; (void)language; }
    return found;
#else
    (void)layout;
    (void)variant;
    (void)options;
    (void)language;
    KbdLog(@"    ✗ only available on Linux and BSD\n");
#endif
    return NO;
}
static BOOL detectKeyboardFromDeviceTree(const char **layout,
                                         const char **variant,
                                         const char **options,
                                         const char **language)
{
#if defined(__linux__)
    KbdLog(@"    Path: /proc/device-tree/chosen/rpi-country-code\n");
    FILE *f = fopen("/proc/device-tree/chosen/rpi-country-code", "rb");
    if (!f) {
        KbdLog(@"    ✗ file does not exist\n");
        return NO;
    }
    unsigned char buf[4];
    size_t n = fread(buf, 1, sizeof(buf), f);
    fclose(f);
    if (n != 4) {
        KbdLog(@"    ✗ read %zu bytes (expected 4)\n", n);
        return NO;
    }
    int idx = (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3];
    if (idx < 0 || idx > 14) idx = 0;
    *layout = rpiKeyboardLayout(idx);
    *variant = "";
    *options = "";
    KbdLog(@"    Country code: %d → layout=\"%s\"\n", idx, *layout);
    return YES;
#elif defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    static const char *dt_paths[] = {
        "/sys/firmware/devicetree/chosen/rpi-country-code",
        "/boot/dtb/chosen/rpi-country-code",
        NULL
    };
    for (int i = 0; dt_paths[i]; i++) {
        KbdLog(@"    Path: %s\n", dt_paths[i]);
        FILE *f = fopen(dt_paths[i], "rb");
        if (!f) {
            KbdLog(@"    ✗ file does not exist\n");
            continue;
        }
        unsigned char buf[4];
        size_t n = fread(buf, 1, sizeof(buf), f);
        fclose(f);
        if (n != 4) {
            KbdLog(@"    ✗ read %zu bytes (expected 4)\n", n);
            continue;
        }
        int idx = (buf[0] << 24) | (buf[1] << 16) | (buf[2] << 8) | buf[3];
        if (idx < 0 || idx > 14) idx = 0;
        *layout = rpiKeyboardLayout(idx);
        *variant = "";
        *options = "";
        if (language) *language = rpiKeyboardLanguage(idx);
        if (language && *language)
            KbdLog(@"    Country code: %d → layout=\"%s\" language=\"%s\"\n", idx, *layout, *language);
        else
            KbdLog(@"    Country code: %d → layout=\"%s\"\n", idx, *layout);
        return YES;
    }
    (void)layout; (void)variant; (void)options; (void)language;
    return NO;
#else
    (void)layout;
    (void)variant;
    (void)options;
    (void)language;
    KbdLog(@"    ✗ only available on Linux\n");
    return NO;
#endif
}
static void writeFileIfAbsent(const char *path, const char *content)
{
    if (access(path, F_OK) == 0) {
        KbdLog(@"  ✗ %s exists, not overwriting\n", path);
        return;
    }
    FILE *fp = fopen(path, "w");
    if (fp) {
        fputs(content, fp);
        fclose(fp);
        KbdLog(@"  ✓ %s created\n", path);
    } else {
        KbdLog(@"  ✗ %s: %s\n", path, strerror(errno));
    }
}
static void writeKeyboardConfigFile(const char *layout,
                                    const char *variant,
                                    const char *options)
{
    const char *kb = layout ? layout : "us";
    const char *vr = variant ? variant : "";
    const char *op = options ? options : "";
#if defined(__linux__)
    char buf[4096];
    int n;
    n = snprintf(buf, sizeof(buf),
        "XKBMODEL=\"pc105\"\n"
        "XKBLAYOUT=\"%s\"\n"
        "XKBVARIANT=\"%s\"\n"
        "XKBOPTIONS=\"%s\"\n",
        kb, vr, op);
    if (n > 0 && n < (int)sizeof(buf))
        writeFileIfAbsent("/etc/default/keyboard", buf);
    if (vr[0])
        n = snprintf(buf, sizeof(buf),
            "KEYMAP=\"%s\"\n"
            "XKBLAYOUT=\"%s\"\n"
            "XKBVARIANT=\"%s\"\n",
            kb, kb, vr);
    else
        n = snprintf(buf, sizeof(buf),
            "KEYMAP=\"%s\"\n",
            kb);
    if (n > 0 && n < (int)sizeof(buf))
        writeFileIfAbsent("/etc/vconsole.conf", buf);
#elif defined(__FreeBSD__)
    if (mkdir("/etc/rc.conf.d", 0755) != 0 && errno != EEXIST)
        NSLog(@"KeyboardManager: WARNING: cannot create /etc/rc.conf.d: %s", strerror(errno));
    char buf[1024];
    int n = snprintf(buf, sizeof(buf),
        "keymap=\"%s.kbd\"\n",
        kb);
    if (n > 0 && n < (int)sizeof(buf))
        writeFileIfAbsent("/etc/rc.conf.d/keyboard", buf);
#elif defined(__OpenBSD__)
    char buf[256];
    int n = snprintf(buf, sizeof(buf), "%s\n", kb);
    if (n > 0 && n < (int)sizeof(buf))
        writeFileIfAbsent("/etc/kbdtype", buf);
#elif defined(__NetBSD__)
    if (access("/etc/wscons.conf", F_OK) != 0) {
        char buf[512];
        int n = snprintf(buf, sizeof(buf),
            "encoding %s\n",
            kb);
        if (n > 0 && n < (int)sizeof(buf))
            writeFileIfAbsent("/etc/wscons.conf", buf);
    } else {
        NSLog(@"KeyboardManager: /etc/wscons.conf already exists, not overwriting");
    }
#endif
    (void)vr;
    (void)op;
}
static const char *findSetxkbmap(void)
{
    static const char *paths[] = {
        "/usr/local/bin/setxkbmap",
        "/usr/bin/setxkbmap",
        "/bin/setxkbmap",
        "/usr/X11R6/bin/setxkbmap",
        "/usr/X11R7/bin/setxkbmap",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        if (access(paths[i], X_OK) == 0)
            return paths[i];
    }
    return NULL;
}
static const char *findXkbcomp(void)
{
    static const char *paths[] = {
        "/usr/local/bin/xkbcomp",
        "/usr/bin/xkbcomp",
        "/bin/xkbcomp",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        if (access(paths[i], X_OK) == 0)
            return paths[i];
    }
    return NULL;
}
static BOOL isConfigFileNewerThanParent(const char *path)
{
    struct stat fs, ds;
    if (stat(path, &fs) != 0) return NO;
    char parent[4096];
    snprintf(parent, sizeof(parent), "%s", path);
    char *slash = strrchr(parent, '/');
    if (!slash || slash == parent) return NO;
    *slash = '\0';
    if (stat(parent, &ds) != 0) return NO;
    time_t dir_time;
#if defined(__FreeBSD__) || defined(__NetBSD__)
    dir_time = ds.st_birthtime;
#else
    dir_time = ds.st_ctime;
#endif
    if (dir_time == 0) return YES;
    time_t cutoff = dir_time + 3600;
    if (fs.st_mtime >= cutoff || fs.st_ctime >= cutoff) {
        return YES;
    }
    KbdLog(@"    ⚠ file mtime (%ld) ctime (%ld) both < dir+1h (%ld) — disregarding as default/stale\n",
           (long)fs.st_mtime, (long)fs.st_ctime, (long)cutoff);
    return NO;
}

static BOOL applyKeyboardToXServer(const char *layout,
                                   const char *variant,
                                   const char *options)
{
    const char *setxkbmap = findSetxkbmap();
    if (setxkbmap) {
        char xkb_cmd[512];
        int n = snprintf(xkb_cmd, sizeof(xkb_cmd),
                         "%s -option '' 2>/dev/null;"
                         "%s %s%s%s%s%s%s 2>/dev/null",
                         setxkbmap, setxkbmap,
                         layout ? layout : "us",
                         (variant && variant[0]) ? " -variant " : "",
                         (variant && variant[0]) ? variant : "",
                         (options && options[0]) ? " -option " : "",
                         (options && options[0]) ? options : "",
                         "");
        if (n <= 0 || n >= (int)sizeof(xkb_cmd)) return NO;
        int rc = system(xkb_cmd);
        if (rc != 0)
            NSLog(@"KeyboardManager: WARNING: setxkbmap exited with status %d", rc);
        return (rc == 0);
    }
    const char *xkbcomp = findXkbcomp();
    if (!xkbcomp) {
        NSLog(@"KeyboardManager: ERROR: no keyboard layout tool (setxkbmap/xkbcomp) found");
        return NO;
    }
    char xkb_cmd[1024];
    int n;
    if (variant && variant[0]) {
        n = snprintf(xkb_cmd, sizeof(xkb_cmd),
            "echo 'xkb_keymap {"
            "xkb_keycodes { include \"evdev+aliases(qwerty)\" };"
            "xkb_types { include \"complete\" };"
            "xkb_compat { include \"complete\" };"
            "xkb_symbols { include \"pc+%s(%s)+inet(evdev)\" };"
            "xkb_geometry { include \"pc(pc105)\" };"
            "};' | %s -w 0 - $DISPLAY 2>/dev/null",
            layout ? layout : "us", variant, xkbcomp);
    } else {
        n = snprintf(xkb_cmd, sizeof(xkb_cmd),
            "echo 'xkb_keymap {"
            "xkb_keycodes { include \"evdev+aliases(qwerty)\" };"
            "xkb_types { include \"complete\" };"
            "xkb_compat { include \"complete\" };"
            "xkb_symbols { include \"pc+%s+inet(evdev)\" };"
            "xkb_geometry { include \"pc(pc105)\" };"
            "};' | %s -w 0 - $DISPLAY 2>/dev/null",
            layout ? layout : "us", xkbcomp);
    }
    if (n <= 0 || n >= (int)sizeof(xkb_cmd)) return NO;
    int rc = system(xkb_cmd);
    if (rc != 0)
        NSLog(@"KeyboardManager: WARNING: xkbcomp exited with status %d", rc);
    return (rc == 0);
}
static BOOL parseRcConfKeymap(const char **layout, const char **variant)
{
    KbdLog(@"    Path: /etc/rc.conf\n");
    if (!isConfigFileNewerThanParent("/etc/rc.conf")) {
        KbdLog(@"    ✗ file appears to be a package default (not user-configured)\n");
        return NO;
    }
    FILE *rc_conf = fopen("/etc/rc.conf", "r");
    if (!rc_conf) {
        KbdLog(@"    ✗ file does not exist or cannot be read\n");
        return NO;
    }
    char line[256];
    BOOL found = NO;
    while (fgets(line, sizeof(line), rc_conf)) {
        if (strncmp(line, "keymap=", 7) != 0) continue;
        char *keymap = strchr(line, '=') + 1;
        char *nl = strchr(keymap, '\n');
        if (nl) *nl = '\0';
        if (keymap[0] == '"') {
            keymap++;
            char *eq = strchr(keymap, '"');
            if (eq) *eq = '\0';
        }
        KbdLog(@"    keymap=\"%s\"\n", keymap);
        if (strstr(keymap, "us"))       *layout = "us";
        else if (strstr(keymap, "de"))  *layout = "de";
        else if (strstr(keymap, "fr"))  *layout = "fr";
        else if (strstr(keymap, "es"))  *layout = "es";
        else if (strstr(keymap, "it"))  *layout = "it";
        else if (strstr(keymap, "pt"))  *layout = "pt";
        else if (strstr(keymap, "ru"))  *layout = "ru";
        else if (strstr(keymap, "uk") || strstr(keymap, "gb")) *layout = "gb";
        else if (strstr(keymap, "dvorak")) {
            *layout = "us";
            *variant = "dvorak";
        } else {
            *layout = "us";
            KbdLog(@"    (unknown keymap, defaulting to \"us\")\n");
        }
        KbdLog(@"    → layout=\"%s\"", *layout);
        if (*variant && (*variant)[0]) KbdLog(@" variant=\"%s\"", *variant);
        KbdLog(@"\n");
        found = YES;
        break;
    }
    fclose(rc_conf);
    if (!found) KbdLog(@"    ✗ no keymap= line found\n");
    return found;
}
static BOOL parseEtcDefaultKeyboard(const char **layout,
                                    const char **variant,
                                    const char **options)
{
#if defined(__linux__)
    KbdLog(@"    Path: /etc/default/keyboard\n");
    if (!isConfigFileNewerThanParent("/etc/default/keyboard")) {
        KbdLog(@"    ✗ file appears to be a package default (not user-configured)\n");
        return NO;
    }
    static char buf_layout[64], buf_variant[64], buf_options[256];
    FILE *fp = fopen("/etc/default/keyboard", "r");
    if (!fp) {
        KbdLog(@"    ✗ file does not exist or cannot be read\n");
        return NO;
    }
    char line[256];
    BOOL found = NO;
    while (fgets(line, sizeof(line), fp)) {
        char *nl = strchr(line, '\n');
        if (nl) *nl = '\0';
        if (strncmp(line, "XKBLAYOUT=", 10) == 0) {
            char *val = line + 10;
            if (*val == '"') { val++; char *eq = strchr(val, '"'); if (eq) *eq = '\0'; }
            if (val[0]) { strncpy(buf_layout, val, sizeof(buf_layout) - 1); buf_layout[sizeof(buf_layout) - 1] = '\0'; *layout = buf_layout; found = YES; }
        } else if (strncmp(line, "XKBVARIANT=", 11) == 0) {
            char *val = line + 11;
            if (*val == '"') { val++; char *eq = strchr(val, '"'); if (eq) *eq = '\0'; }
            if (val[0]) { strncpy(buf_variant, val, sizeof(buf_variant) - 1); buf_variant[sizeof(buf_variant) - 1] = '\0'; *variant = buf_variant; }
        } else if (strncmp(line, "XKBOPTIONS=", 11) == 0) {
            char *val = line + 11;
            if (*val == '"') { val++; char *eq = strchr(val, '"'); if (eq) *eq = '\0'; }
            if (val[0]) { strncpy(buf_options, val, sizeof(buf_options) - 1); buf_options[sizeof(buf_options) - 1] = '\0'; *options = buf_options; }
        }
    }
    fclose(fp);
    if (found) {
        KbdLog(@"    XKBLAYOUT=\"%s\"\n",   *layout  ? *layout  : "");
        KbdLog(@"    XKBVARIANT=\"%s\"\n",  *variant ? *variant : "");
        KbdLog(@"    XKBOPTIONS=\"%s\"\n",  *options ? *options : "");
    } else {
        KbdLog(@"    ✗ no XKB variables found in file\n");
    }
    return found;
#else
    (void)layout; (void)variant; (void)options;
    KbdLog(@"    ✗ only available on Linux\n");
    return NO;
#endif
}
static const char *efiLocaleToLayout(const char *locale)
{
    if (strcmp(locale, "de") == 0) return "de";
    if (strcmp(locale, "fr") == 0) return "fr";
    if (strcmp(locale, "es") == 0) return "es";
    if (strcmp(locale, "it") == 0) return "it";
    if (strcmp(locale, "pt") == 0) return "pt";
    if (strcmp(locale, "ru") == 0) return "ru";
    if (strcmp(locale, "tr") == 0) return "tr";
    if (strcmp(locale, "he") == 0) return "il";
    if (strcmp(locale, "da") == 0) return "dk";
    if (strcmp(locale, "sv") == 0) return "se";
    if (strcmp(locale, "nb") == 0 || strcmp(locale, "no") == 0) return "no";
    if (strcmp(locale, "fi") == 0) return "fi";
    if (strcmp(locale, "ja") == 0) return "jp";
    if (strcmp(locale, "ko") == 0) return "kr";
    if (strcmp(locale, "zh") == 0) return "cn";
    if (strcmp(locale, "cs") == 0) return "cz";
    if (strcmp(locale, "hu") == 0) return "hu";
    if (strcmp(locale, "pl") == 0) return "pl";
    if (strcmp(locale, "sk") == 0) return "sk";
    if (strcmp(locale, "bg") == 0) return "bg";
    if (strcmp(locale, "uk") == 0) return "ua";
    if (strcmp(locale, "hr") == 0) return "hr";
    if (strcmp(locale, "ro") == 0) return "ro";
    if (strcmp(locale, "sl") == 0) return "si";
    if (strcmp(locale, "et") == 0) return "ee";
    if (strcmp(locale, "lv") == 0) return "lv";
    if (strcmp(locale, "lt") == 0) return "lt";
    if (strcmp(locale, "is") == 0) return "is";
    if (strcmp(locale, "el") == 0) return "gr";
    if (strcmp(locale, "vi") == 0) return "vn";
    if (strcmp(locale, "th") == 0) return "th";
    if (strcmp(locale, "nl") == 0) return "nl";
    if (strcmp(locale, "be") == 0) return "by";
    if (strcmp(locale, "mk") == 0) return "mk";
    if (strcmp(locale, "mt") == 0) return "mt";
    if (strcmp(locale, "en_GB") == 0 || strcmp(locale, "en_IE") == 0) return "gb";
    if (strcmp(locale, "en_CA") == 0) return "ca";
    if (strcmp(locale, "pt_BR") == 0) return "br";
    if (strncmp(locale, "en", 2) == 0) return "us";
    return NULL;
}
static const char *efiLocaleToLang(const char *locale)
{
    if (strcmp(locale, "de") == 0) return "de_DE.UTF-8";
    if (strcmp(locale, "fr") == 0) return "fr_FR.UTF-8";
    if (strcmp(locale, "es") == 0) return "es_ES.UTF-8";
    if (strcmp(locale, "it") == 0) return "it_IT.UTF-8";
    if (strcmp(locale, "pt") == 0) return "pt_PT.UTF-8";
    if (strcmp(locale, "ru") == 0) return "ru_RU.UTF-8";
    if (strcmp(locale, "tr") == 0) return "tr_TR.UTF-8";
    if (strcmp(locale, "he") == 0) return "he_IL.UTF-8";
    if (strcmp(locale, "da") == 0) return "da_DK.UTF-8";
    if (strcmp(locale, "sv") == 0) return "sv_SE.UTF-8";
    if (strcmp(locale, "nb") == 0 || strcmp(locale, "no") == 0) return "nb_NO.UTF-8";
    if (strcmp(locale, "fi") == 0) return "fi_FI.UTF-8";
    if (strcmp(locale, "ja") == 0) return "ja_JP.UTF-8";
    if (strcmp(locale, "ko") == 0) return "ko_KR.UTF-8";
    if (strcmp(locale, "zh") == 0) return "zh_CN.UTF-8";
    if (strcmp(locale, "cs") == 0) return "cs_CZ.UTF-8";
    if (strcmp(locale, "hu") == 0) return "hu_HU.UTF-8";
    if (strcmp(locale, "pl") == 0) return "pl_PL.UTF-8";
    if (strcmp(locale, "sk") == 0) return "sk_SK.UTF-8";
    if (strcmp(locale, "bg") == 0) return "bg_BG.UTF-8";
    if (strcmp(locale, "uk") == 0) return "uk_UA.UTF-8";
    if (strcmp(locale, "hr") == 0) return "hr_HR.UTF-8";
    if (strcmp(locale, "ro") == 0) return "ro_RO.UTF-8";
    if (strcmp(locale, "sl") == 0) return "sl_SI.UTF-8";
    if (strcmp(locale, "et") == 0) return "et_EE.UTF-8";
    if (strcmp(locale, "lv") == 0) return "lv_LV.UTF-8";
    if (strcmp(locale, "lt") == 0) return "lt_LT.UTF-8";
    if (strcmp(locale, "is") == 0) return "is_IS.UTF-8";
    if (strcmp(locale, "el") == 0) return "el_GR.UTF-8";
    if (strcmp(locale, "vi") == 0) return "vi_VN.UTF-8";
    if (strcmp(locale, "th") == 0) return "th_TH.UTF-8";
    if (strcmp(locale, "nl") == 0) return "nl_NL.UTF-8";
    if (strcmp(locale, "be") == 0) return "be_BY.UTF-8";
    if (strcmp(locale, "mk") == 0) return "mk_MK.UTF-8";
    if (strcmp(locale, "mt") == 0) return "mt_MT.UTF-8";
    if (strcmp(locale, "en") == 0 || strcmp(locale, "en_US") == 0) return "en_US.UTF-8";
    if (strcmp(locale, "en_AU") == 0) return "en_AU.UTF-8";
    if (strcmp(locale, "en_CA") == 0) return "en_CA.UTF-8";
    if (strcmp(locale, "en_GB") == 0) return "en_GB.UTF-8";
    if (strcmp(locale, "en_IE") == 0) return "en_IE.UTF-8";
    if (strcmp(locale, "fr_CA") == 0) return "fr_CA.UTF-8";
    if (strcmp(locale, "fr_CH") == 0) return "fr_CH.UTF-8";
    if (strcmp(locale, "de_CH") == 0) return "de_CH.UTF-8";
    if (strcmp(locale, "pt_BR") == 0) return "pt_BR.UTF-8";
    if (strcmp(locale, "nl_BE") == 0) return "nl_BE.UTF-8";
    return NULL;
}
static BOOL parseEFIVariable(const unsigned char *data, size_t len,
                             const char **layout, const char **variant,
                             const char **options, const char **language)
{
    if (len <= 4) {
        KbdLog(@"    EFI data too short (%zu bytes)\n", len);
        return NO;
    }
    size_t dlen = len - 4;
    const unsigned char *d = data + 4;
    if (dlen > 0 && d[dlen - 1] == '\0') dlen--;
    static char str[256];
    size_t slen = 0;
    if (dlen > 0 && d[0] == '\0') {
        for (size_t i = 0; i < dlen && slen < sizeof(str) - 1; i += 2)
            if (i + 1 < dlen)
                str[slen++] = d[i + 1];
            else
                str[slen++] = d[i];
    } else {
        for (size_t i = 0; i < dlen && slen < sizeof(str) - 1; i++)
            str[slen++] = d[i];
    }
    str[slen] = '\0';
    KbdLog(@"    Raw EFI value: '%s' (len=%zu)\n", str, slen);
    char *colon = strchr(str, ':');
    if (!colon) {
        KbdLog(@"    ✗ no colon separator found in '%s'\n", str);
        return NO;
    }
    *colon = '\0';
    KbdLog(@"    Locale: \"%s\"", str);
    *layout = efiLocaleToLayout(str);
    if (!*layout) {
        KbdLog(@" (not in locale→layout map, fallback to \"us\")\n");
        *layout = "us";
    } else {
        KbdLog(@" → \"%s\"\n", *layout);
    }
    *language = efiLocaleToLang(str);
    if (*language) {
        KbdLog(@"    Language: \"%s\"\n", *language);
    } else if (strchr(str, '_')) {
        static char lang_buf[64];
        snprintf(lang_buf, sizeof(lang_buf), "%s.UTF-8", str);
        *language = lang_buf;
        KbdLog(@"    Language: \"%s\" (from locale)\n", *language);
    } else {
        KbdLog(@"    Language: (none, only supported via EFI NVRAM)\n");
    }
    *variant = "";
    *options = "";
    return YES;
}
static const char *findEfivar(void)
{
    static const char *paths[] = {
        "/usr/local/bin/efivar",
        "/usr/bin/efivar",
        "/bin/efivar",
        "/usr/sbin/efivar",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        if (access(paths[i], X_OK) == 0)
            return paths[i];
    }
    return "efivar";
}
static void ensureEfivarfsMounted(void)
{
#if defined(__linux__)
    struct stat st;
    if (stat("/sys/firmware/efi/efivars", &st) != 0 || !S_ISDIR(st.st_mode))
        return;
    // Check if already mounted by looking for at least one entry
    DIR *d = opendir("/sys/firmware/efi/efivars");
    if (!d) return;
    int count = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] != '.') { count++; break; }
    }
    closedir(d);
    if (count > 0) return;
    KbdLog(@"    efivarfs directory empty, attempting mount...\n");
    if (system("mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null") == 0) {
        KbdLog(@"    efivarfs mounted successfully\n");
    } else {
        KbdLog(@"    efivarfs mount failed (not UEFI or no kernel support)\n");
    }
#elif defined(__FreeBSD__)
    // FreeBSD uses /dev/efi + efivar(8) — no efivarfs
    (void)0;
#endif
}

static BOOL detectKeyboardFromEFI(const char **layout,
                                  const char **variant,
                                  const char **options,
                                  const char **language)
{
    unsigned char buf[512];
    size_t n;
    ensureEfivarfsMounted();
    KbdLog(@"    Trying efivarfs...\n");
    FILE *f = fopen("/sys/firmware/efi/efivars/prev-lang:kbd-7c436110-ab2a-4bbb-a880-fe41995c9f82", "rb");
    if (f) {
        n = fread(buf, 1, sizeof(buf), f);
        fclose(f);
        KbdLog(@"    efivarfs: read %zu bytes\n", n);
        if (parseEFIVariable(buf, n, layout, variant, options, language))
            return YES;
    } else {
        KbdLog(@"    efivarfs: not available\n");
    }
    KbdLog(@"    Trying efivar command...\n");
    const char *efivar = findEfivar();
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "%s -p -n 7c436110-ab2a-4bbb-a880-fe41995c9f82-prev-lang:kbd 2>/dev/null", efivar);
    f = popen(cmd, "r");
    if (!f) {
        KbdLog(@"    efivar command: not available\n");
    } else {
        n = fread(buf, 1, sizeof(buf), f);
        int rc = pclose(f);
        if (rc == 0 && n > 0) {
            KbdLog(@"    efivar command: read %zu bytes\n", n);
            if (parseEFIVariable(buf, n, layout, variant, options, language))
                return YES;
        } else {
            KbdLog(@"    efivar command: returned %d (%zu bytes)\n", rc, n);
        }
    }
    return NO;
}
static void writeLocaleFileIfAbsentOrDefault(const char *path, const char *content)
{
    if (access(path, F_OK) == 0) {
        if (isConfigFileNewerThanParent(path)) {
            KbdLog(@"  ✗ %s exists and is user-configured, not overwriting\n", path);
            return;
        }
        KbdLog(@"  ⚠ %s is a package default, overwriting\n", path);
    }
    FILE *fp = fopen(path, "w");
    if (fp) {
        fputs(content, fp);
        fclose(fp);
        KbdLog(@"  ✓ %s created\n", path);
    } else {
        KbdLog(@"  ✗ %s: %s\n", path, strerror(errno));
    }
}
static void writeLocaleConfigFile(const char *lang)
{
    if (!lang || !lang[0]) return;
#if defined(__linux__)
    char buf[4096];
    int n;
    n = snprintf(buf, sizeof(buf), "LANG=%s\n", lang);
    if (n > 0 && n < (int)sizeof(buf))
        writeLocaleFileIfAbsentOrDefault("/etc/locale.conf", buf);
    n = snprintf(buf, sizeof(buf), "LANG=%s\nLANGUAGE=%s\n", lang, lang);
    if (n > 0 && n < (int)sizeof(buf))
        writeLocaleFileIfAbsentOrDefault("/etc/default/locale", buf);
    n = snprintf(buf, sizeof(buf), "LANG=%s\n", lang);
    if (n > 0 && n < (int)sizeof(buf))
        writeLocaleFileIfAbsentOrDefault("/etc/environment", buf);
#elif defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
    char buf[1024];
    int n = snprintf(buf, sizeof(buf),
        "default:\\\n"
        "\t:lang=%s:\\\n"
        "\t:setenv=LANG=%s:\n",
        lang, lang);
    if (n > 0 && n < (int)sizeof(buf))
        writeLocaleFileIfAbsentOrDefault("/etc/login.conf.d/locale", buf);
#endif
    (void)lang;
}
@implementation KeyboardManager
@synthesize layout = _layout;
@synthesize variant = _variant;
@synthesize options = _options;
@synthesize model = _model;
@synthesize lastError = _lastError;
@synthesize detectionLog = _detectionLog;
@synthesize language = _language;
- (id)init
{
    self = [super init];
    if (self) {
        _layout = nil;
        _variant = nil;
        _options = nil;
        _model = [@"pc105" copy];
        _lastError = nil;
    }
    return self;
}
- (void)dealloc
{
    [_layout release];
    [_variant release];
    [_options release];
    [_model release];
    [_lastError release];
    [_language release];
    [_detectionLog release];
    [super dealloc];
}
- (BOOL)detectKeyboardWithPasswd:(const struct passwd *)pwd
{
    [_layout release];   _layout = nil;
    [_variant release];  _variant = nil;
    [_options release];  _options = nil;
    [_lastError release]; _lastError = nil;
    [_language release]; _language = nil;
    [_detectionLog release]; _detectionLog = nil;

    [s_log release];
    s_log = [[NSMutableString alloc] init];
    KbdLog(@"Keyboard Layout Detection Log\n");
    KbdLog(@"==============================\n\n");

    const char *c_layout = NULL;
    const char *c_variant = NULL;
    const char *c_options = NULL;
    const char *c_language = NULL;
    BOOL found = NO;
    int step = 0, successStep = 0;

    step++;
    KbdLog(@"[%d] /etc/default/keyboard\n", step);
    if (parseEtcDefaultKeyboard(&c_layout, &c_variant, &c_options)) {
        found = YES; successStep = step;
        KbdLog(@"    → ACCEPTED (highest priority)\n\n");
    } else {
        KbdLog(@"    ✗ not found\n\n");
    }

    step++;
    KbdLog(@"[%d] EFI NVRAM (prev-lang:kbd)\n", step);
    if (found) {
        KbdLog(@"    - skipped (resolved at step %d)\n\n", successStep);
    } else if (detectKeyboardFromEFI(&c_layout, &c_variant, &c_options, &c_language)) {
        found = YES; successStep = step;
        KbdLog(@"    → ACCEPTED\n\n");
    } else {
        KbdLog(@"    ✗ not available\n\n");
    }

    step++;
    KbdLog(@"[%d] USB RPI keyboard detection\n", step);
    if (found) {
        KbdLog(@"    - skipped (resolved at step %d)\n\n", successStep);
    } else if (detectKeyboardFromUSB(&c_layout, &c_variant, &c_options, &c_language)) {
        found = YES; successStep = step;
        KbdLog(@"    → ACCEPTED\n\n");
    } else {
        KbdLog(@"    ✗ no RPI keyboard found\n\n");
    }

    step++;
    KbdLog(@"[%d] RPI device-tree country-code\n", step);
    if (found) {
        KbdLog(@"    - skipped (resolved at step %d)\n\n", successStep);
    } else if (!c_layout && detectKeyboardFromDeviceTree(&c_layout, &c_variant, &c_options, &c_language)) {
        found = YES; successStep = step;
        KbdLog(@"    → ACCEPTED\n\n");
    } else {
        KbdLog(@"    ✗ not available\n\n");
    }

    step++;
    KbdLog(@"[%d] login.conf (BSD only)\n", step);
    if (found) {
        KbdLog(@"    - skipped (resolved at step %d)\n\n", successStep);
    } else if (!c_layout && pwd) {
#if !defined(__linux__)
        login_cap_t *lc = GW_LOGIN_GETPWCLASS((struct passwd *)pwd);
        if (lc) {
            c_layout  = login_getcapstr(lc, "keyboard.layout", NULL, NULL);
            c_variant = login_getcapstr(lc, "keyboard.variant", NULL, NULL);
            c_options = login_getcapstr(lc, "keyboard.options", NULL, NULL);
            login_close(lc);
            if (c_layout) {
                KbdLog(@"    keyboard.layout=\"%s\"\n", c_layout);
                KbdLog(@"    → ACCEPTED\n\n");
                found = YES; successStep = step;
            } else {
                KbdLog(@"    ✗ keyboard.* capabilities not set\n\n");
            }
        } else {
            KbdLog(@"    ✗ login_getpwclass failed\n\n");
        }
#else
        (void)pwd;
        KbdLog(@"    ✗ not on BSD\n\n");
#endif
    } else if (!c_layout) {
        KbdLog(@"    ✗ no passwd entry provided (pwd==NULL)\n\n");
    } else {
        KbdLog(@"    - skipped (resolved at step %d)\n\n", successStep);
    }

    step++;
    KbdLog(@"[%d] Environment variables\n", step);
    if (found) {
        KbdLog(@"    - skipped (resolved at step %d)\n\n", successStep);
    } else {
        const char *env_layout = getenv("XKB_DEFAULT_LAYOUT");
        const char *env_variant = getenv("XKB_DEFAULT_VARIANT");
        const char *env_options = getenv("XKB_DEFAULT_OPTIONS");
        KbdLog(@"    XKB_DEFAULT_LAYOUT=%s\n", env_layout ? env_layout : "(unset)");
        KbdLog(@"    XKB_DEFAULT_VARIANT=%s\n", env_variant ? env_variant : "(unset)");
        KbdLog(@"    XKB_DEFAULT_OPTIONS=%s\n", env_options ? env_options : "(unset)");
        if (!c_layout) { c_layout = env_layout; }
        if (!c_variant) { c_variant = env_variant; }
        if (!c_options) { c_options = env_options; }
        if (c_layout) {
            KbdLog(@"    → ACCEPTED\n\n");
            found = YES; successStep = step;
        } else {
            KbdLog(@"    ✗ no layout set\n\n");
        }
    }

    step++;
    KbdLog(@"[%d] /etc/rc.conf keymap (BSD fallback)\n", step);
    if (found) {
        KbdLog(@"    - skipped (resolved at step %d)\n\n", successStep);
    } else {
        if (!c_layout && parseRcConfKeymap(&c_layout, &c_variant)) {
            KbdLog(@"    → ACCEPTED\n\n");
            found = YES; successStep = step;
        } else {
            KbdLog(@"    ✗ not found\n\n");
        }
    }

    if (!c_layout) {
        c_layout = "us";
        step++;
        KbdLog(@"[%d] Default fallback\n", step);
        KbdLog(@"    → layout=\"us\" (no source provided a layout)\n\n");
    }

    KbdLog(@"==============================\n");
    KbdLog(@"Final Result:\n");
    KbdLog(@"  Layout:  %s\n", c_layout ? c_layout : "us");
    KbdLog(@"  Variant: %s\n", (c_variant && c_variant[0]) ? c_variant : "(none)");
    KbdLog(@"  Options: %s\n", (c_options && c_options[0]) ? c_options : "(none)");
    if (!c_language && c_layout) {
        static const char *layoutToLang[][2] = {
            {"de", "de_DE.UTF-8"}, {"fr", "fr_FR.UTF-8"}, {"es", "es_ES.UTF-8"},
            {"it", "it_IT.UTF-8"}, {"pt", "pt_PT.UTF-8"}, {"ru", "ru_RU.UTF-8"},
            {"tr", "tr_TR.UTF-8"}, {"il", "he_IL.UTF-8"}, {"dk", "da_DK.UTF-8"},
            {"se", "sv_SE.UTF-8"}, {"no", "nb_NO.UTF-8"}, {"fi", "fi_FI.UTF-8"},
            {"jp", "ja_JP.UTF-8"}, {"kr", "ko_KR.UTF-8"}, {"cn", "zh_CN.UTF-8"},
            {"cz", "cs_CZ.UTF-8"}, {"hu", "hu_HU.UTF-8"}, {"pl", "pl_PL.UTF-8"},
            {"sk", "sk_SK.UTF-8"}, {"bg", "bg_BG.UTF-8"}, {"ua", "uk_UA.UTF-8"},
            {"hr", "hr_HR.UTF-8"}, {"ro", "ro_RO.UTF-8"}, {"si", "sl_SI.UTF-8"},
            {"ee", "et_EE.UTF-8"}, {"lv", "lv_LV.UTF-8"}, {"lt", "lt_LT.UTF-8"},
            {"is", "is_IS.UTF-8"}, {"gr", "el_GR.UTF-8"}, {"vn", "vi_VN.UTF-8"},
            {"th", "th_TH.UTF-8"}, {"nl", "nl_NL.UTF-8"}, {"by", "be_BY.UTF-8"},
            {"mk", "mk_MK.UTF-8"}, {"mt", "mt_MT.UTF-8"}, {"ca", "fr_CA.UTF-8"},
            {"gb", "en_GB.UTF-8"}, {"us", "en_US.UTF-8"}, {"br", "pt_BR.UTF-8"},
            {NULL, NULL}
        };
        for (int i = 0; layoutToLang[i][0]; i++) {
            if (strcmp(c_layout, layoutToLang[i][0]) == 0) {
                c_language = layoutToLang[i][1];
                KbdLog(@"  Inferred language from layout \"%s\": %s\n", c_layout, c_language);
                break;
            }
        }
    }
    KbdLog(@"  Model:   %@\n", _model);
    KbdLog(@"  Language: %s\n", (c_language && c_language[0]) ? c_language : "(not set)");

    _layout    = [[NSString stringWithUTF8String:c_layout] copy];
    _variant   = (c_variant && c_variant[0])
                    ? [[NSString stringWithUTF8String:c_variant] copy]
                    : [@"" copy];
    _options   = (c_options && c_options[0])
                    ? [[NSString stringWithUTF8String:c_options] copy]
                    : [@"" copy];
    _language  = (c_language && c_language[0])
                    ? [[NSString stringWithUTF8String:c_language] copy]
                    : nil;

    _detectionLog = [s_log copy];
    [s_log release];
    s_log = nil;

    NSLog(@"KeyboardManager: Keyboard: %@ variant=%@ options=%@ model=%@",
          _layout, _variant, _options, _model);
    return YES;
}
- (BOOL)persistConfiguration
{
    if (!_layout) {
        [_lastError release];
        _lastError = [@"No layout detected, cannot persist" copy];
        return NO;
    }
    writeKeyboardConfigFile([_layout UTF8String],
                            [_variant UTF8String],
                            [_options UTF8String]);
    return YES;
}
- (BOOL)persistLanguage
{
    if (!_language) {
        NSLog(@"KeyboardManager: No language to persist (not available from any source)");
        return NO;
    }
    KbdLog(@"  Persisting language: \"%@\"\n", _language);
    writeLocaleConfigFile([_language UTF8String]);
    NSLog(@"KeyboardManager: Language file(s) written for %@", _language);
    return YES;
}
- (BOOL)applyLanguage
{
    if (!_language) {
        NSLog(@"KeyboardManager: No language to apply");
        return NO;
    }
    setenv("LANG", [_language UTF8String], 1);
    NSString *langNoEncoding = [[_language componentsSeparatedByString:@"."] firstObject];
    if (langNoEncoding) {
        setenv("LANGUAGE", [langNoEncoding UTF8String], 1);
        setenv("LC_ALL", [_language UTF8String], 1);
    }
    NSLog(@"KeyboardManager: Exported LANG=%@ LANGUAGE=%@", _language, langNoEncoding ? langNoEncoding : @"(none)");
    return YES;
}
- (BOOL)applyToXServer
{
    if (!_layout) {
        [_lastError release];
        _lastError = [@"No layout detected, cannot apply" copy];
        return NO;
    }
    return applyKeyboardToXServer([_layout UTF8String],
                                  [_variant UTF8String],
                                  [_options UTF8String]);
}
- (BOOL)setupWithPasswd:(const struct passwd *)pwd
{
    if (![self detectKeyboardWithPasswd:pwd]) return NO;
    [self persistConfiguration];
    [self persistLanguage];
    [self applyLanguage];
    [self applyToXServer];
    return YES;
}
@end

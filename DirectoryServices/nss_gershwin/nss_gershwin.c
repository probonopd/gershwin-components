/*
 * nss_gershwin - NSS module for Gershwin Directory Services
 *
 * Queries dshelper daemon via Unix socket to resolve users and groups.
 * Install to: /System/Library/Libraries/nss_gershwin.so.1
 */

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <errno.h>
#include <pwd.h>
#include <grp.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <nss.h>

#define DS_SOCKET_PATH "/var/run/dshelper.sock"
#define BUFFER_SIZE 4096

/*
 * Query dshelper daemon via Unix socket
 * Returns 0 on success, -1 on failure
 */
static int
query_dshelper(const char *request, char *response, size_t response_len)
{
    int fd;
    struct sockaddr_un addr;
    ssize_t n;

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, DS_SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }

    /* Send request */
    if (write(fd, request, strlen(request)) < 0) {
        close(fd);
        return -1;
    }

    /* Read response */
    n = read(fd, response, response_len - 1);
    close(fd);

    if (n <= 0) {
        return -1;
    }

    response[n] = '\0';

    /* Check for NOTFOUND response */
    if (strcmp(response, "NOTFOUND") == 0) {
        return -1;
    }

    return 0;
}

/*
 * Parse passwd line: name:x:uid:gid:gecos:home:shell
 */
static int
parse_passwd(const char *line, struct passwd *pwd, char *buffer, size_t buflen)
{
    char *p, *saveptr;
    char *buf = buffer;
    size_t remaining = buflen;

    /* Make a copy we can tokenize */
    char *linecopy = strdup(line);
    if (!linecopy) {
        return -1;
    }

    /* name */
    p = strtok_r(linecopy, ":", &saveptr);
    if (!p) goto fail;
    size_t len = strlen(p) + 1;
    if (len > remaining) goto fail;
    strcpy(buf, p);
    pwd->pw_name = buf;
    buf += len;
    remaining -= len;

    /* password (x) */
    p = strtok_r(NULL, ":", &saveptr);
    if (!p) goto fail;
    len = strlen(p) + 1;
    if (len > remaining) goto fail;
    strcpy(buf, p);
    pwd->pw_passwd = buf;
    buf += len;
    remaining -= len;

    /* uid */
    p = strtok_r(NULL, ":", &saveptr);
    if (!p) goto fail;
    pwd->pw_uid = (uid_t)strtoul(p, NULL, 10);

    /* gid */
    p = strtok_r(NULL, ":", &saveptr);
    if (!p) goto fail;
    pwd->pw_gid = (gid_t)strtoul(p, NULL, 10);

    /* gecos */
    p = strtok_r(NULL, ":", &saveptr);
    if (!p) goto fail;
    len = strlen(p) + 1;
    if (len > remaining) goto fail;
    strcpy(buf, p);
    pwd->pw_gecos = buf;
    buf += len;
    remaining -= len;

    /* home */
    p = strtok_r(NULL, ":", &saveptr);
    if (!p) goto fail;
    len = strlen(p) + 1;
    if (len > remaining) goto fail;
    strcpy(buf, p);
    pwd->pw_dir = buf;
    buf += len;
    remaining -= len;

    /* shell */
    p = strtok_r(NULL, ":", &saveptr);
    if (!p) goto fail;
    len = strlen(p) + 1;
    if (len > remaining) goto fail;
    strcpy(buf, p);
    pwd->pw_shell = buf;

    /* FreeBSD-specific fields */
    pwd->pw_class = "";
    pwd->pw_change = 0;
    pwd->pw_expire = 0;
    pwd->pw_fields = 0;

    free(linecopy);
    return 0;

fail:
    free(linecopy);
    return -1;
}

/*
 * Parse group line: name:x:gid:member1,member2,...
 */
static int
parse_group(const char *line, struct group *grp, char *buffer, size_t buflen)
{
    char *p, *saveptr, *memsave;
    char *buf = buffer;
    size_t remaining = buflen;
    int member_count = 0;
    char **members;

    char *linecopy = strdup(line);
    if (!linecopy) {
        return -1;
    }

    /* name */
    p = strtok_r(linecopy, ":", &saveptr);
    if (!p) goto fail;
    size_t len = strlen(p) + 1;
    if (len > remaining) goto fail;
    strcpy(buf, p);
    grp->gr_name = buf;
    buf += len;
    remaining -= len;

    /* password (x) */
    p = strtok_r(NULL, ":", &saveptr);
    if (!p) goto fail;
    len = strlen(p) + 1;
    if (len > remaining) goto fail;
    strcpy(buf, p);
    grp->gr_passwd = buf;
    buf += len;
    remaining -= len;

    /* gid */
    p = strtok_r(NULL, ":", &saveptr);
    if (!p) goto fail;
    grp->gr_gid = (gid_t)strtoul(p, NULL, 10);

    /* members */
    p = strtok_r(NULL, ":", &saveptr);

    /* Count members first */
    if (p && strlen(p) > 0) {
        char *memcopy = strdup(p);
        char *m = strtok_r(memcopy, ",", &memsave);
        while (m) {
            member_count++;
            m = strtok_r(NULL, ",", &memsave);
        }
        free(memcopy);
    }

    /* Allocate member array in buffer */
    size_t array_size = (member_count + 1) * sizeof(char *);
    if (array_size > remaining) goto fail;

    /* Align buffer for pointer array */
    uintptr_t align = (uintptr_t)buf % sizeof(char *);
    if (align) {
        buf += sizeof(char *) - align;
        remaining -= sizeof(char *) - align;
    }

    members = (char **)buf;
    buf += array_size;
    remaining -= array_size;
    grp->gr_mem = members;

    /* Parse members again and store */
    if (p && strlen(p) > 0) {
        int i = 0;
        char *m = strtok_r(p, ",", &memsave);
        while (m && i < member_count) {
            len = strlen(m) + 1;
            if (len > remaining) goto fail;
            strcpy(buf, m);
            members[i++] = buf;
            buf += len;
            remaining -= len;
            m = strtok_r(NULL, ",", &memsave);
        }
        members[i] = NULL;
    } else {
        members[0] = NULL;
    }

    free(linecopy);
    return 0;

fail:
    free(linecopy);
    return -1;
}

/*
 * NSS entry points
 */

enum nss_status
_nss_gershwin_getpwnam_r(const char *name, struct passwd *pwd,
                          char *buffer, size_t buflen, int *errnop)
{
    char request[256];
    char response[BUFFER_SIZE];

    snprintf(request, sizeof(request), "getpwnam:%s", name);

    if (query_dshelper(request, response, sizeof(response)) != 0) {
        *errnop = ENOENT;
        return NSS_STATUS_NOTFOUND;
    }

    if (parse_passwd(response, pwd, buffer, buflen) != 0) {
        *errnop = ERANGE;
        return NSS_STATUS_TRYAGAIN;
    }

    return NSS_STATUS_SUCCESS;
}

enum nss_status
_nss_gershwin_getpwuid_r(uid_t uid, struct passwd *pwd,
                          char *buffer, size_t buflen, int *errnop)
{
    char request[256];
    char response[BUFFER_SIZE];

    snprintf(request, sizeof(request), "getpwuid:%u", (unsigned)uid);

    if (query_dshelper(request, response, sizeof(response)) != 0) {
        *errnop = ENOENT;
        return NSS_STATUS_NOTFOUND;
    }

    if (parse_passwd(response, pwd, buffer, buflen) != 0) {
        *errnop = ERANGE;
        return NSS_STATUS_TRYAGAIN;
    }

    return NSS_STATUS_SUCCESS;
}

enum nss_status
_nss_gershwin_getgrnam_r(const char *name, struct group *grp,
                          char *buffer, size_t buflen, int *errnop)
{
    char request[256];
    char response[BUFFER_SIZE];

    snprintf(request, sizeof(request), "getgrnam:%s", name);

    if (query_dshelper(request, response, sizeof(response)) != 0) {
        *errnop = ENOENT;
        return NSS_STATUS_NOTFOUND;
    }

    if (parse_group(response, grp, buffer, buflen) != 0) {
        *errnop = ERANGE;
        return NSS_STATUS_TRYAGAIN;
    }

    return NSS_STATUS_SUCCESS;
}

enum nss_status
_nss_gershwin_getgrgid_r(gid_t gid, struct group *grp,
                          char *buffer, size_t buflen, int *errnop)
{
    char request[256];
    char response[BUFFER_SIZE];

    snprintf(request, sizeof(request), "getgrgid:%u", (unsigned)gid);

    if (query_dshelper(request, response, sizeof(response)) != 0) {
        *errnop = ENOENT;
        return NSS_STATUS_NOTFOUND;
    }

    if (parse_group(response, grp, buffer, buflen) != 0) {
        *errnop = ERANGE;
        return NSS_STATUS_TRYAGAIN;
    }

    return NSS_STATUS_SUCCESS;
}

/*
 * FreeBSD NSS wrapper functions
 * These have the signature: int (*nss_method)(void *retval, void *mdata, va_list ap)
 */
#include <nsswitch.h>
#include <stdarg.h>

static int
nss_getpwnam_r(void *retval, void *mdata __unused, va_list ap)
{
    const char *name = va_arg(ap, const char *);
    struct passwd *pwd = va_arg(ap, struct passwd *);
    char *buffer = va_arg(ap, char *);
    size_t buflen = va_arg(ap, size_t);
    int *errnop = va_arg(ap, int *);

    enum nss_status status = _nss_gershwin_getpwnam_r(name, pwd, buffer, buflen, errnop);

    if (status == NSS_STATUS_SUCCESS) {
        *(struct passwd **)retval = pwd;
        return NS_SUCCESS;
    } else if (status == NSS_STATUS_TRYAGAIN) {
        return NS_TRYAGAIN;
    }
    return NS_NOTFOUND;
}

static int
nss_getpwuid_r(void *retval, void *mdata __unused, va_list ap)
{
    uid_t uid = va_arg(ap, uid_t);
    struct passwd *pwd = va_arg(ap, struct passwd *);
    char *buffer = va_arg(ap, char *);
    size_t buflen = va_arg(ap, size_t);
    int *errnop = va_arg(ap, int *);

    enum nss_status status = _nss_gershwin_getpwuid_r(uid, pwd, buffer, buflen, errnop);

    if (status == NSS_STATUS_SUCCESS) {
        *(struct passwd **)retval = pwd;
        return NS_SUCCESS;
    } else if (status == NSS_STATUS_TRYAGAIN) {
        return NS_TRYAGAIN;
    }
    return NS_NOTFOUND;
}

static int
nss_getgrnam_r(void *retval, void *mdata __unused, va_list ap)
{
    const char *name = va_arg(ap, const char *);
    struct group *grp = va_arg(ap, struct group *);
    char *buffer = va_arg(ap, char *);
    size_t buflen = va_arg(ap, size_t);
    int *errnop = va_arg(ap, int *);

    enum nss_status status = _nss_gershwin_getgrnam_r(name, grp, buffer, buflen, errnop);

    if (status == NSS_STATUS_SUCCESS) {
        *(struct group **)retval = grp;
        return NS_SUCCESS;
    } else if (status == NSS_STATUS_TRYAGAIN) {
        return NS_TRYAGAIN;
    }
    return NS_NOTFOUND;
}

static int
nss_getgrgid_r(void *retval, void *mdata __unused, va_list ap)
{
    gid_t gid = va_arg(ap, gid_t);
    struct group *grp = va_arg(ap, struct group *);
    char *buffer = va_arg(ap, char *);
    size_t buflen = va_arg(ap, size_t);
    int *errnop = va_arg(ap, int *);

    enum nss_status status = _nss_gershwin_getgrgid_r(gid, grp, buffer, buflen, errnop);

    if (status == NSS_STATUS_SUCCESS) {
        *(struct group **)retval = grp;
        return NS_SUCCESS;
    } else if (status == NSS_STATUS_TRYAGAIN) {
        return NS_TRYAGAIN;
    }
    return NS_NOTFOUND;
}

/*
 * Check if a group exists in /etc/group
 */
static int
group_exists_in_etc(const char *groupname)
{
    FILE *f = fopen("/etc/group", "r");
    if (!f) return 0;

    char line[512];
    size_t namelen = strlen(groupname);

    while (fgets(line, sizeof(line), f)) {
        /* Check if line starts with "groupname:" */
        if (strncmp(line, groupname, namelen) == 0 && line[namelen] == ':') {
            fclose(f);
            return 1;
        }
    }

    fclose(f);
    return 0;
}

/*
 * getgroupmembership - return all groups for a user
 * This is where we add wheel (0) for admin users
 * sudo (27) is only added on Linux where it exists
 */
#define ADMIN_GID 5000
#define WHEEL_GID 0
#define SUDO_GID 27

static int
nss_getgroupmembership(void *retval __unused, void *mdata __unused, va_list ap)
{
    const char *username = va_arg(ap, const char *);
    gid_t basegid __unused = va_arg(ap, gid_t);
    gid_t *groups = va_arg(ap, gid_t *);
    int maxgrp = va_arg(ap, int);
    int *grpcnt = va_arg(ap, int *);

    char request[256];
    char response[BUFFER_SIZE];
    int count = *grpcnt;
    int is_admin = 0;
    int user_found = 0;

    /* Query gsdh for user's group memberships */
    snprintf(request, sizeof(request), "getgrouplist:%s", username);

    if (query_dshelper(request, response, sizeof(response)) == 0) {
        user_found = 1;
        /* Response format: gid1,gid2,gid3,... */
        char *saveptr;
        char *gidstr = strtok_r(response, ",", &saveptr);

        while (gidstr && count < maxgrp) {
            gid_t gid = (gid_t)strtoul(gidstr, NULL, 10);

            /* Check if already in list */
            int found = 0;
            for (int i = 0; i < count; i++) {
                if (groups[i] == gid) {
                    found = 1;
                    break;
                }
            }

            if (!found) {
                groups[count++] = gid;
                if (gid == ADMIN_GID) {
                    is_admin = 1;
                }
            }

            gidstr = strtok_r(NULL, ",", &saveptr);
        }
    }

    /* If user not found in gsdh, let next NSS module handle it */
    if (!user_found) {
        return NS_NOTFOUND;
    }

    /* If user is in admin group, add wheel (and sudo on Linux) */
    if (is_admin) {
        int has_wheel = 0;

        for (int i = 0; i < count; i++) {
            if (groups[i] == WHEEL_GID) has_wheel = 1;
        }

        if (!has_wheel && count < maxgrp) {
            groups[count++] = WHEEL_GID;
        }

        /* Only add sudo group if it exists (Linux) */
        if (group_exists_in_etc("sudo")) {
            int has_sudo = 0;
            for (int i = 0; i < count; i++) {
                if (groups[i] == SUDO_GID) has_sudo = 1;
            }
            if (!has_sudo && count < maxgrp) {
                groups[count++] = SUDO_GID;
            }
        }
    }

    *grpcnt = count;
    return NS_SUCCESS;
}

/*
 * Module registration for FreeBSD NSS
 */
static ns_mtab methods[] = {
    { NSDB_PASSWD, "getpwnam_r", nss_getpwnam_r, NULL },
    { NSDB_PASSWD, "getpwuid_r", nss_getpwuid_r, NULL },
    { NSDB_GROUP,  "getgrnam_r", nss_getgrnam_r, NULL },
    { NSDB_GROUP,  "getgrgid_r", nss_getgrgid_r, NULL },
    { NSDB_GROUP,  "getgroupmembership", nss_getgroupmembership, NULL },
};

ns_mtab *
nss_module_register(const char *name __unused, unsigned int *size,
                    nss_module_unregister_fn *unregister)
{
    *size = sizeof(methods) / sizeof(methods[0]);
    *unregister = NULL;
    return methods;
}

/*
 * pam_gershwin - PAM module for Gershwin Directory Services
 *
 * Queries gsdh daemon via Unix socket for authentication.
 * Install to: /System/Library/Libraries/pam_gershwin.so
 */

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <security/pam_modules.h>
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

#define GSDH_SOCKET_PATH "/var/run/gershwin-directory.sock"
#define BUFFER_SIZE 4096

/*
 * Query gsdh daemon for authentication
 * Returns 1 on success, 0 on failure
 */
static int
authenticate_via_gsdh(const char *username, const char *password)
{
    int fd;
    struct sockaddr_un addr;
    char request[BUFFER_SIZE];
    char response[16];
    ssize_t n;

    if (!username || !password) {
        return 0;
    }

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return 0;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, GSDH_SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return 0;
    }

    /* Send auth request: "auth:username:password" */
    snprintf(request, sizeof(request), "auth:%s:%s", username, password);

    if (write(fd, request, strlen(request)) < 0) {
        close(fd);
        return 0;
    }

    /* Read response: "1" for success, "0" for failure */
    n = read(fd, response, sizeof(response) - 1);
    close(fd);

    if (n <= 0) {
        return 0;
    }

    response[n] = '\0';

    return (response[0] == '1') ? 1 : 0;
}

/*
 * Check if user exists in gsdh
 */
static int
user_exists_in_gsdh(const char *username)
{
    int fd;
    struct sockaddr_un addr;
    char request[256];
    char response[BUFFER_SIZE];
    ssize_t n;

    if (!username) {
        return 0;
    }

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return 0;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, GSDH_SOCKET_PATH, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return 0;
    }

    snprintf(request, sizeof(request), "getpwnam:%s", username);

    if (write(fd, request, strlen(request)) < 0) {
        close(fd);
        return 0;
    }

    n = read(fd, response, sizeof(response) - 1);
    close(fd);

    if (n <= 0) {
        return 0;
    }

    response[n] = '\0';

    /* NOTFOUND means user doesn't exist */
    if (strcmp(response, "NOTFOUND") == 0) {
        return 0;
    }

    return 1;
}

/*
 * PAM authentication
 */
PAM_EXTERN int
pam_sm_authenticate(pam_handle_t *pamh, int flags __unused,
                    int argc __unused, const char *argv[] __unused)
{
    const char *username;
    const char *password;
    int ret;

    /* Get username */
    ret = pam_get_user(pamh, &username, NULL);
    if (ret != PAM_SUCCESS || !username) {
        return PAM_USER_UNKNOWN;
    }

    /* Check if this user is managed by gsdh */
    if (!user_exists_in_gsdh(username)) {
        /* Not our user, let next module handle it */
        return PAM_IGNORE;
    }

    /* Get password */
    ret = pam_get_authtok(pamh, PAM_AUTHTOK, &password, NULL);
    if (ret != PAM_SUCCESS || !password) {
        return PAM_AUTH_ERR;
    }

    /* Authenticate */
    if (authenticate_via_gsdh(username, password)) {
        return PAM_SUCCESS;
    }

    return PAM_AUTH_ERR;
}

/*
 * PAM set credentials - not used but required
 */
PAM_EXTERN int
pam_sm_setcred(pam_handle_t *pamh __unused, int flags __unused,
               int argc __unused, const char *argv[] __unused)
{
    return PAM_SUCCESS;
}

/*
 * PAM account management - check if account is valid
 */
PAM_EXTERN int
pam_sm_acct_mgmt(pam_handle_t *pamh, int flags __unused,
                 int argc __unused, const char *argv[] __unused)
{
    const char *username;
    int ret;

    ret = pam_get_user(pamh, &username, NULL);
    if (ret != PAM_SUCCESS || !username) {
        return PAM_USER_UNKNOWN;
    }

    /* Check if user exists */
    if (!user_exists_in_gsdh(username)) {
        return PAM_IGNORE;
    }

    /* TODO: Check account expiration, locked status, etc. */

    return PAM_SUCCESS;
}

/*
 * PAM session management
 */
PAM_EXTERN int
pam_sm_open_session(pam_handle_t *pamh __unused, int flags __unused,
                    int argc __unused, const char *argv[] __unused)
{
    /* TODO: Mount network home directory for /Network users */
    return PAM_SUCCESS;
}

PAM_EXTERN int
pam_sm_close_session(pam_handle_t *pamh __unused, int flags __unused,
                     int argc __unused, const char *argv[] __unused)
{
    /* TODO: Unmount network home directory */
    return PAM_SUCCESS;
}

/*
 * PAM password management
 */
PAM_EXTERN int
pam_sm_chauthtok(pam_handle_t *pamh __unused, int flags __unused,
                 int argc __unused, const char *argv[] __unused)
{
    /* TODO: Implement password change via gsdh */
    return PAM_AUTHTOK_ERR;
}

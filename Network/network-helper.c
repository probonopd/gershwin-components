/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Network Helper Tool
 *
 * A helper CLI tool for privileged network operations.
 * This tool is meant to be called via sudo -A -E from the Network preference pane.
 * The SUDO_ASKPASS environment variable should point to a graphical password dialog.
 *
 * This is a pure C program without GNUstep dependencies so it works reliably
 * when invoked via sudo without requiring LD_LIBRARY_PATH setup.
 *
 * Usage:
 *   network-helper <command> [arguments...]
 *
 * Commands:
 *   wlan-enable           Enable WLAN radio
 *   wlan-disable          Disable WLAN radio
 *   wlan-connect <ssid> [password]   Connect to WLAN network
 *   wlan-disconnect       Disconnect from current WLAN network
 *   wlan-direct-connect <interface> <ssid> [password]  Direct wpa_supplicant connect
 *   dhcp-renew <interface>  Renew DHCP lease on interface
 *   dhcp-release <interface>  Release DHCP lease on interface
 *   connection-add <type> <name> [device]   Add a new connection
 *   connection-delete <name>   Delete a connection
 *   connection-up <name>       Activate a connection
 *   connection-down <name>     Deactivate a connection
 *   interface-enable <device>  Enable a network interface
 *   interface-disable <device> Disable a network interface
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/utsname.h>
#if defined(__FreeBSD__) || defined(__DragonFly__)
#include <sys/sysctl.h>
#endif
#include <fcntl.h>
#include <errno.h>

#define MAX_ARGS 32
#define MAX_OUTPUT 4096

static char nmcli_path[256] = {0};
static char wpa_cli_path[256] = {0};
static char dhcpcd_path[256] = {0};
static char ifconfig_path[256] = {0};
static char sysrc_path[256] = {0};
static char dhclient_path[256] = {0};
static char wpa_supplicant_path[256] = {0};
static char sysctl_path[256] = {0};
static int is_freebsd = 0;

/* Forward declarations */
static int run_command(char *const args[], char *error_buf, size_t error_buf_size);
static int run_command_with_output(char *const args[], char *output_buf, size_t output_buf_size,
                                    char *error_buf, size_t error_buf_size);
static int dhcp_renew(const char *interface);
static int dhcp_release(const char *interface);

/* Find executable in common paths */
static int find_executable(const char *name, char *buffer, size_t buffer_size) {
    char test_path[512];
    const char *paths[] = {
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        NULL
    };
    
    for (int i = 0; paths[i] != NULL; i++) {
        snprintf(test_path, sizeof(test_path), "%s/%s", paths[i], name);
        if (access(test_path, X_OK) == 0) {
            strncpy(buffer, test_path, buffer_size - 1);
            buffer[buffer_size - 1] = '\0';
            return 1;
        }
    }
    
    return 0;
}

/* Find nmcli executable */
static int find_nmcli(void) {
    return find_executable("nmcli", nmcli_path, sizeof(nmcli_path));
}

/* Find wpa_cli executable */
static int find_wpa_cli(void) {
    return find_executable("wpa_cli", wpa_cli_path, sizeof(wpa_cli_path));
}

/* Find dhcpcd executable */
static int find_dhcpcd(void) {
    return find_executable("dhcpcd", dhcpcd_path, sizeof(dhcpcd_path));
}

/* Find BSD-specific tools */
static int find_ifconfig(void) {
    return find_executable("ifconfig", ifconfig_path, sizeof(ifconfig_path));
}

static int find_dhclient(void) {
    return find_executable("dhclient", dhclient_path, sizeof(dhclient_path));
}

static int find_sysrc(void) {
    return find_executable("sysrc", sysrc_path, sizeof(sysrc_path));
}

static int find_wpa_supplicant(void) {
    return find_executable("wpa_supplicant", wpa_supplicant_path, sizeof(wpa_supplicant_path));
}

static int find_sysctl(void) {
    return find_executable("sysctl", sysctl_path, sizeof(sysctl_path));
}

/* Detect whether we are running on FreeBSD */
static void detect_os(void) {
    is_freebsd = 0;

#if defined(__FreeBSD__) || defined(__DragonFly__)
    /*
     * Use sysctlbyname which is NOT affected by FreeBSD's Linux ABI
     * compatibility layer. When linux_enable="YES" in rc.conf,
     * uname() returns "Linux" instead of "FreeBSD".
     */
    {
        char ostype[64] = {0};
        size_t len = sizeof(ostype) - 1;
        if (sysctlbyname("kern.ostype", ostype, &len, NULL, 0) == 0) {
            if (strcmp(ostype, "FreeBSD") == 0 ||
                strcmp(ostype, "DragonFly") == 0) {
                is_freebsd = 1;
                fprintf(stderr,
                        "network-helper: detected FreeBSD via sysctl\n");
                return;
            }
        }
    }
#endif

    /* File-based fallback: sysrc(8) is FreeBSD-specific */
    if (access("/usr/sbin/sysrc", X_OK) == 0) {
        is_freebsd = 1;
        fprintf(stderr,
                "network-helper: detected FreeBSD via sysrc presence\n");
        return;
    }

    /* Last resort: uname (unreliable with Linux ABI compat) */
    struct utsname uts;
    if (uname(&uts) == 0 && strcmp(uts.sysname, "FreeBSD") == 0) {
        is_freebsd = 1;
        fprintf(stderr, "network-helper: detected FreeBSD via uname\n");
    }
}

/* Run nmcli command with given arguments
 * Returns exit code, captures stderr for error reporting */
static int run_nmcli(char *const args[], char *error_buf, size_t error_buf_size) {
    if (nmcli_path[0] == '\0') {
        if (error_buf && error_buf_size > 0) {
            snprintf(error_buf, error_buf_size, "nmcli not found");
        }
        return 1;
    }
    
    int pipefd[2];  /* For capturing stderr */
    if (pipe(pipefd) < 0) {
        if (error_buf && error_buf_size > 0) {
            snprintf(error_buf, error_buf_size, "Failed to create pipe: %s", strerror(errno));
        }
        return 1;
    }
    
    pid_t pid = fork();
    
    if (pid < 0) {
        if (error_buf && error_buf_size > 0) {
            snprintf(error_buf, error_buf_size, "Failed to fork: %s", strerror(errno));
        }
        close(pipefd[0]);
        close(pipefd[1]);
        return 1;
    }
    
    if (pid == 0) {
        /* Child process */
        close(pipefd[0]);  /* Close read end */
        
        /* Redirect stderr to pipe */
        dup2(pipefd[1], STDERR_FILENO);
        close(pipefd[1]);
        
        /* Execute nmcli */
        execv(nmcli_path, args);
        
        /* If exec fails */
        fprintf(stderr, "Failed to execute nmcli: %s", strerror(errno));
        _exit(127);
    }
    
    /* Parent process */
    close(pipefd[1]);  /* Close write end */
    
    /* Read stderr output */
    if (error_buf && error_buf_size > 0) {
        ssize_t n = read(pipefd[0], error_buf, error_buf_size - 1);
        if (n > 0) {
            error_buf[n] = '\0';
            /* Remove trailing newline */
            while (n > 0 && (error_buf[n-1] == '\n' || error_buf[n-1] == '\r')) {
                error_buf[--n] = '\0';
            }
        } else {
            error_buf[0] = '\0';
        }
    }
    close(pipefd[0]);
    
    /* Wait for child */
    int status;
    waitpid(pid, &status, 0);
    
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    
    return 1;
}

/* Run nmcli with output capture (for commands that need to parse output) */
static int run_nmcli_with_output(char *const args[], char *output_buf, size_t output_buf_size,
                                  char *error_buf, size_t error_buf_size) {
    if (nmcli_path[0] == '\0') {
        if (error_buf && error_buf_size > 0) {
            snprintf(error_buf, error_buf_size, "nmcli not found");
        }
        return 1;
    }
    
    int stdout_pipe[2];
    int stderr_pipe[2];
    
    if (pipe(stdout_pipe) < 0 || pipe(stderr_pipe) < 0) {
        if (error_buf && error_buf_size > 0) {
            snprintf(error_buf, error_buf_size, "Failed to create pipes: %s", strerror(errno));
        }
        return 1;
    }
    
    pid_t pid = fork();
    
    if (pid < 0) {
        if (error_buf && error_buf_size > 0) {
            snprintf(error_buf, error_buf_size, "Failed to fork: %s", strerror(errno));
        }
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        close(stderr_pipe[0]); close(stderr_pipe[1]);
        return 1;
    }
    
    if (pid == 0) {
        /* Child process */
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stderr_pipe[1], STDERR_FILENO);
        
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);
        
        execv(nmcli_path, args);
        _exit(127);
    }
    
    /* Parent process */
    close(stdout_pipe[1]);
    close(stderr_pipe[1]);
    
    if (output_buf && output_buf_size > 0) {
        ssize_t n = read(stdout_pipe[0], output_buf, output_buf_size - 1);
        output_buf[n > 0 ? n : 0] = '\0';
    }
    close(stdout_pipe[0]);
    
    if (error_buf && error_buf_size > 0) {
        ssize_t n = read(stderr_pipe[0], error_buf, error_buf_size - 1);
        if (n > 0) {
            error_buf[n] = '\0';
            while (n > 0 && (error_buf[n-1] == '\n' || error_buf[n-1] == '\r')) {
                error_buf[--n] = '\0';
            }
        } else {
            error_buf[0] = '\0';
        }
    }
    close(stderr_pipe[0]);
    
    int status;
    waitpid(pid, &status, 0);
    
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    
    return 1;
}

/* Enable WLAN radio */
static int wlan_enable(void) {
    char error_buf[MAX_OUTPUT] = {0};
    char *args[] = {nmcli_path, "radio", "wifi", "on", NULL};
    int result = run_nmcli(args, error_buf, sizeof(error_buf));
    
    if (result != 0 && error_buf[0] != '\0') {
        fprintf(stderr, "Error enabling WLAN: %s\n", error_buf);
    }
    return result;
}

/* Disable WLAN radio */
static int wlan_disable(void) {
    char error_buf[MAX_OUTPUT] = {0};
    char *args[] = {nmcli_path, "radio", "wifi", "off", NULL};
    int result = run_nmcli(args, error_buf, sizeof(error_buf));
    
    if (result != 0 && error_buf[0] != '\0') {
        fprintf(stderr, "Error disabling WLAN: %s\n", error_buf);
    }
    return result;
}

/* Delete a connection by name (helper for wlan_connect) */
static void delete_connection(const char *name) {
    char error_buf[MAX_OUTPUT] = {0};
    char *args[] = {nmcli_path, "connection", "delete", (char *)name, NULL};
    run_nmcli(args, error_buf, sizeof(error_buf));
    /* Ignore errors - connection might not exist */
}

/* Connect to WLAN network using connection add method */
static int wlan_connect(const char *ssid, const char *password) {
    char error_buf[MAX_OUTPUT] = {0};
    int result;
    
    if (!ssid || ssid[0] == '\0') {
        fprintf(stderr, "Error: SSID is required\n");
        return 1;
    }
    
    /* If no password, use simple device wifi connect */
    if (!password || password[0] == '\0') {
        char *args[] = {nmcli_path, "device", "wifi", "connect", (char *)ssid, NULL};
        result = run_nmcli(args, error_buf, sizeof(error_buf));
        if (result != 0 && error_buf[0] != '\0') {
            fprintf(stderr, "Error connecting to WLAN '%s': %s\n", ssid, error_buf);
        }
        return result;
    }
    
    /* For secured networks, use connection add with explicit security settings */
    /* This is more reliable than device wifi connect */
    
    /* First delete any existing connection with this SSID */
    delete_connection(ssid);
    
    /* Create connection: nmcli connection add type wifi con-name SSID ssid SSID wifi-sec.key-mgmt wpa-psk wifi-sec.psk PASSWORD */
    char *add_args[] = {
        nmcli_path, "connection", "add",
        "type", "wifi",
        "con-name", (char *)ssid,
        "ssid", (char *)ssid,
        "wifi-sec.key-mgmt", "wpa-psk",
        "wifi-sec.psk", (char *)password,
        NULL
    };
    
    result = run_nmcli(add_args, error_buf, sizeof(error_buf));
    
    if (result != 0) {
        fprintf(stderr, "Error creating connection profile for '%s': %s\n", ssid, error_buf);
        return result;
    }
    
    /* Now activate the connection */
    char *up_args[] = {nmcli_path, "connection", "up", (char *)ssid, NULL};
    result = run_nmcli(up_args, error_buf, sizeof(error_buf));
    
    if (result != 0) {
        fprintf(stderr, "Error activating connection '%s': %s\n", ssid, error_buf);
        /* Clean up the failed connection profile */
        delete_connection(ssid);
        return result;
    }
    
    return 0;
}

/* Disconnect from current WLAN */
static int wlan_disconnect(void) {
    char output_buf[MAX_OUTPUT] = {0};
    char error_buf[MAX_OUTPUT] = {0};
    
    /* First find the wifi device */
    char *args[] = {nmcli_path, "-t", "-f", "DEVICE,TYPE", "device", NULL};
    int result = run_nmcli_with_output(args, output_buf, sizeof(output_buf),
                                        error_buf, sizeof(error_buf));
    
    if (result != 0) {
        fprintf(stderr, "Error listing devices: %s\n", error_buf);
        return result;
    }
    
    /* Parse output to find WLAN device */
    char *line = strtok(output_buf, "\n");
    while (line != NULL) {
        char *colon = strchr(line, ':');
        if (colon != NULL) {
            *colon = '\0';
            char *device = line;
            char *type = colon + 1;
            
            if (strcmp(type, "wifi") == 0) {
                /* Found WLAN device, disconnect it */
                char *disconnect_args[] = {nmcli_path, "device", "disconnect", device, NULL};
                result = run_nmcli(disconnect_args, error_buf, sizeof(error_buf));
                
                if (result != 0 && error_buf[0] != '\0') {
                    fprintf(stderr, "Error disconnecting WLAN device %s: %s\n", device, error_buf);
                }
                return result;
            }
        }
        line = strtok(NULL, "\n");
    }
    
    fprintf(stderr, "Error: No WLAN device found\n");
    return 1;
}

/* Add a new connection */
static int connection_add(const char *type, const char *name, const char *device) {
    char error_buf[MAX_OUTPUT] = {0};
    char *args[10];
    int i = 0;
    
    args[i++] = nmcli_path;
    args[i++] = "connection";
    args[i++] = "add";
    args[i++] = "type";
    args[i++] = (char *)type;
    args[i++] = "con-name";
    args[i++] = (char *)name;
    
    if (device && device[0] != '\0') {
        args[i++] = "ifname";
        args[i++] = (char *)device;
    }
    args[i] = NULL;
    
    int result = run_nmcli(args, error_buf, sizeof(error_buf));
    
    if (result != 0 && error_buf[0] != '\0') {
        fprintf(stderr, "Error adding connection '%s': %s\n", name, error_buf);
    }
    return result;
}

/* Delete a connection */
static int connection_delete(const char *name) {
    char error_buf[MAX_OUTPUT] = {0};
    char *args[] = {nmcli_path, "connection", "delete", (char *)name, NULL};
    int result = run_nmcli(args, error_buf, sizeof(error_buf));
    
    if (result != 0 && error_buf[0] != '\0') {
        fprintf(stderr, "Error deleting connection '%s': %s\n", name, error_buf);
    }
    return result;
}

/* Activate a connection */
static int connection_up(const char *name) {
    char error_buf[MAX_OUTPUT] = {0};
    char *args[] = {nmcli_path, "connection", "up", (char *)name, NULL};
    int result = run_nmcli(args, error_buf, sizeof(error_buf));
    
    if (result != 0 && error_buf[0] != '\0') {
        fprintf(stderr, "Error activating connection '%s': %s\n", name, error_buf);
    }
    return result;
}

/* Deactivate a connection */
static int connection_down(const char *name) {
    char error_buf[MAX_OUTPUT] = {0};
    char *args[] = {nmcli_path, "connection", "down", (char *)name, NULL};
    int result = run_nmcli(args, error_buf, sizeof(error_buf));
    
    if (result != 0 && error_buf[0] != '\0') {
        fprintf(stderr, "Error deactivating connection '%s': %s\n", name, error_buf);
    }
    return result;
}

/* Enable interface */
static int interface_enable(const char *device) {
    char error_buf[MAX_OUTPUT] = {0};
    char output_buf[MAX_OUTPUT] = {0};
    int result;
    
    /* First try nmcli device connect */
    char *args[] = {nmcli_path, "device", "connect", (char *)device, NULL};
    result = run_nmcli(args, error_buf, sizeof(error_buf));
    
    if (result == 0) {
        return 0;
    }
    
    fprintf(stderr, "nmcli device connect failed: %s\n", error_buf);
    
    /* If that failed, try to find and activate an existing connection for this device */
    /* Get list of connections for this device */
    char *list_args[] = {nmcli_path, "-t", "-f", "NAME,DEVICE,TYPE", "connection", "show", NULL};
    result = run_nmcli_with_output(list_args, output_buf, sizeof(output_buf), error_buf, sizeof(error_buf));
    
    if (result == 0 && output_buf[0] != '\0') {
        /* Parse output to find a connection for our device */
        char *saveptr;
        char *line = strtok_r(output_buf, "\n", &saveptr);
        while (line != NULL) {
            /* Format is: connection_name:device:type */
            char conn_name[256] = {0};
            char conn_dev[64] = {0};
            
            char *colon1 = strchr(line, ':');
            if (colon1) {
                strncpy(conn_name, line, colon1 - line);
                conn_name[colon1 - line] = '\0';
                
                char *colon2 = strchr(colon1 + 1, ':');
                if (colon2) {
                    strncpy(conn_dev, colon1 + 1, colon2 - colon1 - 1);
                    conn_dev[colon2 - colon1 - 1] = '\0';
                }
            }
            
            /* Check if this connection is for our device or has no device assigned */
            if (conn_name[0] != '\0' && 
                (strcmp(conn_dev, device) == 0 || conn_dev[0] == '\0' || strcmp(conn_dev, "--") == 0)) {
                /* Found a potential connection, try to activate it */
                fprintf(stdout, "Trying to activate connection '%s' for device %s\n", conn_name, device);
                
                char *up_args[] = {nmcli_path, "connection", "up", conn_name, "ifname", (char *)device, NULL};
                result = run_nmcli(up_args, error_buf, sizeof(error_buf));
                
                if (result == 0) {
                    fprintf(stdout, "Successfully activated connection '%s'\n", conn_name);
                    return 0;
                }
            }
            
            line = strtok_r(NULL, "\n", &saveptr);
        }
    }
    
    /* If still failed, try to bring up the interface with ip link */
    fprintf(stdout, "Trying ip link set %s up...\n", device);
    char ip_path[256] = {0};
    if (find_executable("ip", ip_path, sizeof(ip_path))) {
        char *ip_args[] = {ip_path, "link", "set", (char *)device, "up", NULL};
        result = run_command(ip_args, error_buf, sizeof(error_buf));
        if (result == 0) {
            fprintf(stdout, "Interface %s is up, requesting DHCP...\n", device);
            /* Also try to get DHCP */
            result = dhcp_renew(device);
            return result;
        }
    }
    
    fprintf(stderr, "Error enabling interface '%s': all methods failed\n", device);
    return 1;
}

/* Disable interface */
static int interface_disable(const char *device) {
    char error_buf[MAX_OUTPUT] = {0};
    char *args[] = {nmcli_path, "device", "disconnect", (char *)device, NULL};
    int result = run_nmcli(args, error_buf, sizeof(error_buf));
    
    if (result != 0 && error_buf[0] != '\0') {
        fprintf(stderr, "Error disabling interface '%s': %s\n", device, error_buf);
    }
    return result;
}

/* Run a system command and return exit code */
static int run_command(char *const args[], char *error_buf, size_t error_buf_size) {
    if (!args || !args[0]) {
        if (error_buf && error_buf_size > 0) {
            snprintf(error_buf, error_buf_size, "No command specified");
        }
        return 1;
    }
    
    int pipefd[2];  /* For capturing stderr */
    if (pipe(pipefd) < 0) {
        if (error_buf && error_buf_size > 0) {
            snprintf(error_buf, error_buf_size, "Failed to create pipe: %s", strerror(errno));
        }
        return 1;
    }
    
    pid_t pid = fork();
    
    if (pid < 0) {
        if (error_buf && error_buf_size > 0) {
            snprintf(error_buf, error_buf_size, "Failed to fork: %s", strerror(errno));
        }
        close(pipefd[0]);
        close(pipefd[1]);
        return 1;
    }
    
    if (pid == 0) {
        /* Child process */
        close(pipefd[0]);  /* Close read end */
        
        /* Redirect stderr to pipe */
        dup2(pipefd[1], STDERR_FILENO);
        close(pipefd[1]);
        
        /* Force C locale for consistent error message matching */
        setenv("LC_ALL", "C", 1);
        
        /* Execute command */
        execv(args[0], args);
        
        /* If execv returns, an error occurred */
        fprintf(stderr, "Failed to execute %s: %s\n", args[0], strerror(errno));
        exit(1);
    }
    
    /* Parent process */
    close(pipefd[1]);  /* Close write end */
    
    /* Read stderr */
    if (error_buf && error_buf_size > 0) {
        ssize_t bytes_read = read(pipefd[0], error_buf, error_buf_size - 1);
        if (bytes_read > 0) {
            error_buf[bytes_read] = '\0';
            /* Remove trailing newline */
            if (error_buf[bytes_read - 1] == '\n') {
                error_buf[bytes_read - 1] = '\0';
            }
        } else {
            error_buf[0] = '\0';
        }
    }
    close(pipefd[0]);
    
    int status;
    waitpid(pid, &status, 0);
    
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    
    return 1;
}

/* Renew DHCP lease on interface using dhcpcd */
static int dhcp_renew(const char *interface) {
    char error_buf[MAX_OUTPUT] = {0};
    int result;
    
    if (!interface || interface[0] == '\0') {
        fprintf(stderr, "Error: Interface name is required\n");
        return 1;
    }
    
    if (!find_dhcpcd()) {
        fprintf(stderr, "Error: dhcpcd not found. Is dhcpcd installed?\n");
        return 1;
    }
    
    /* Kill any existing dhcpcd for this interface first */
    char *kill_args[] = {dhcpcd_path, "-x", (char *)interface, NULL};
    run_command(kill_args, error_buf, sizeof(error_buf));
    /* Ignore errors - dhcpcd might not be running */
    
    /* Wait a moment for cleanup */
    usleep(500000);  /* 500ms */
    
    /* Start dhcpcd with options to try harder for IPv4:
     * -4: IPv4 only (focus on getting IPv4)
     * -t 30: 30 second timeout (instead of default ~10s)
     * --noipv4ll: Don't fall back to link-local immediately
     */
    fprintf(stdout, "Requesting IPv4 address via DHCP (30s timeout)...\n");
    char *renew_args[] = {dhcpcd_path, "-4", "-t", "30", "--noipv4ll", (char *)interface, NULL};
    result = run_command(renew_args, error_buf, sizeof(error_buf));
    
    if (result != 0) {
        /* If --noipv4ll failed, try without it */
        fprintf(stdout, "Retrying with fallback options...\n");
        char *retry_args[] = {dhcpcd_path, "-4", "-t", "20", (char *)interface, NULL};
        result = run_command(retry_args, error_buf, sizeof(error_buf));
    }
    
    /* If still failed, try dual-stack */
    if (result != 0) {
        fprintf(stdout, "Trying dual-stack DHCP...\n");
        char *dual_args[] = {dhcpcd_path, "-t", "15", (char *)interface, NULL};
        result = run_command(dual_args, error_buf, sizeof(error_buf));
    }
    
    if (result != 0 && error_buf[0] != '\0') {
        fprintf(stderr, "DHCP request failed on '%s': %s\n", interface, error_buf);
    }
    
    return result;
}

/* Release DHCP lease on interface */
static int dhcp_release(const char *interface) {
    char error_buf[MAX_OUTPUT] = {0};
    
    if (!interface || interface[0] == '\0') {
        fprintf(stderr, "Error: Interface name is required\n");
        return 1;
    }
    
    if (!find_dhcpcd()) {
        fprintf(stderr, "Error: dhcpcd not found. Is dhcpcd installed?\n");
        return 1;
    }
    
    /* Kill dhcpcd for this interface */
    char *args[] = {dhcpcd_path, "-k", (char *)interface, NULL};
    int result = run_command(args, error_buf, sizeof(error_buf));
    
    if (result != 0 && error_buf[0] != '\0') {
        fprintf(stderr, "Error releasing DHCP lease on '%s': %s\n", interface, error_buf);
    }
    
    return result;
}

/* Direct WiFi connection using wpa_cli and dhcpcd */
static int wlan_direct_connect(const char *interface, const char *ssid, const char *password) {
    int result;
    
    if (!interface || interface[0] == '\0') {
        fprintf(stderr, "Error: Interface name is required\n");
        return 1;
    }
    
    if (!ssid || ssid[0] == '\0') {
        fprintf(stderr, "Error: SSID is required\n");
        return 1;
    }
    
    if (!find_wpa_cli()) {
        fprintf(stderr, "Error: wpa_cli not found. Is wpa_supplicant installed?\n");
        return 1;
    }
    
    /* Add network in wpa_supplicant */
    char cmd_buf[512];
    FILE *fp;
    int network_id = -1;
    
    /* Add network and get network ID */
    snprintf(cmd_buf, sizeof(cmd_buf), "%s -i %s add_network", wpa_cli_path, interface);
    fp = popen(cmd_buf, "r");
    if (fp) {
        if (fscanf(fp, "%d", &network_id) != 1) {
            fprintf(stderr, "Error: Failed to add network\n");
            pclose(fp);
            return 1;
        }
        pclose(fp);
    } else {
        fprintf(stderr, "Error: Failed to run wpa_cli add_network\n");
        return 1;
    }
    
    /* Set SSID */
    snprintf(cmd_buf, sizeof(cmd_buf), "%s -i %s set_network %d ssid '\"%s\"'",
             wpa_cli_path, interface, network_id, ssid);
    result = system(cmd_buf);
    if (result != 0) {
        fprintf(stderr, "Error: Failed to set SSID\n");
        return 1;
    }
    
    /* Set password if provided */
    if (password && password[0] != '\0') {
        snprintf(cmd_buf, sizeof(cmd_buf), "%s -i %s set_network %d psk '\"%s\"'",
                 wpa_cli_path, interface, network_id, password);
        result = system(cmd_buf);
        if (result != 0) {
            fprintf(stderr, "Error: Failed to set password\n");
            return 1;
        }
    } else {
        /* Open network - no encryption */
        snprintf(cmd_buf, sizeof(cmd_buf), "%s -i %s set_network %d key_mgmt NONE",
                 wpa_cli_path, interface, network_id);
        result = system(cmd_buf);
        if (result != 0) {
            fprintf(stderr, "Error: Failed to configure open network\n");
            return 1;
        }
    }
    
    /* Enable the network */
    snprintf(cmd_buf, sizeof(cmd_buf), "%s -i %s enable_network %d",
             wpa_cli_path, interface, network_id);
    result = system(cmd_buf);
    if (result != 0) {
        fprintf(stderr, "Error: Failed to enable network\n");
        return 1;
    }
    
    /* Select this network */
    snprintf(cmd_buf, sizeof(cmd_buf), "%s -i %s select_network %d",
             wpa_cli_path, interface, network_id);
    result = system(cmd_buf);
    if (result != 0) {
        fprintf(stderr, "Error: Failed to select network\n");
        return 1;
    }
    
    /* Save configuration */
    snprintf(cmd_buf, sizeof(cmd_buf), "%s -i %s save_config", wpa_cli_path, interface);
    system(cmd_buf);  /* Ignore errors for save_config */
    
    /* Wait for connection and check status */
    fprintf(stdout, "Connecting to WLAN '%s'...\n", ssid);
    int max_wait = 15;  /* Wait up to 15 seconds */
    int connected = 0;
    
    for (int i = 0; i < max_wait; i++) {
        sleep(1);
        
        /* Check wpa_supplicant state */
        snprintf(cmd_buf, sizeof(cmd_buf), "%s -i %s status | grep wpa_state", wpa_cli_path, interface);
        fp = popen(cmd_buf, "r");
        if (fp) {
            char status_line[256];
            if (fgets(status_line, sizeof(status_line), fp)) {
                if (strstr(status_line, "COMPLETED")) {
                    connected = 1;
                    pclose(fp);
                    break;
                }
            }
            pclose(fp);
        }
        
        if (i % 3 == 0) {
            fprintf(stdout, "  Waiting for authentication...\n");
        }
    }
    
    if (!connected) {
        fprintf(stderr, "Error: Failed to authenticate with network '%s'\n", ssid);
        fprintf(stderr, "Please check your password and try again.\n");
        return 1;
    }
    
    fprintf(stdout, "WiFi authentication successful!\n");
    
    /* Wait a bit more for link to be fully up */
    sleep(2);
    
    /* Start DHCP */
    fprintf(stdout, "Requesting IP address via DHCP...\n");
    result = dhcp_renew(interface);
    
    if (result == 0) {
        /* Wait for DHCP to complete */
        sleep(3);
        fprintf(stdout, "Successfully connected to '%s'\n", ssid);
        fprintf(stdout, "Please check your IP address with: ip addr show %s\n", interface);
    } else {
        fprintf(stderr, "Warning: WiFi connected but DHCP may have failed\n");
        fprintf(stderr, "Check with: ip addr show %s\n", interface);
    }
    
    return result;
}

/* ===== FreeBSD-specific implementations ===== */

/* Find the primary wlan device name (wlan0, wlan1, etc.) */
static int bsd_find_wlan_device(char *wlan_dev, size_t wlan_dev_size) {
    /* Check if wlan0 exists */
    if (!find_ifconfig()) return 0;

    char output[MAX_OUTPUT] = {0};
    char error[MAX_OUTPUT] = {0};
    char *args[] = {ifconfig_path, "-l", NULL};
    int ret = run_command_with_output(args, output, sizeof(output), error, sizeof(error));
    if (ret != 0) return 0;

    /* Look for wlanN in the interface list */
    char *tok = strtok(output, " \t\n");
    while (tok) {
        if (strncmp(tok, "wlan", 4) == 0) {
            strncpy(wlan_dev, tok, wlan_dev_size - 1);
            wlan_dev[wlan_dev_size - 1] = '\0';
            return 1;
        }
        tok = strtok(NULL, " \t\n");
    }
    return 0;
}

/* Find the physical wireless device (e.g., iwm0, iwn0) via sysctl */
static int bsd_find_phys_wlan(char *phys_dev, size_t phys_dev_size) {
    if (!find_sysctl()) return 0;

    char output[MAX_OUTPUT] = {0};
    char error[MAX_OUTPUT] = {0};
    char *args[] = {sysctl_path, "net.wlan.devices", NULL};
    int ret = run_command_with_output(args, output, sizeof(output), error, sizeof(error));
    if (ret != 0) return 0;

    /* Output: "net.wlan.devices: iwm0" */
    char *colon = strchr(output, ':');
    if (!colon) return 0;

    char *dev = colon + 1;
    while (*dev == ' ') dev++;

    /* Trim trailing whitespace */
    char *end = dev + strlen(dev) - 1;
    while (end > dev && (*end == '\n' || *end == '\r' || *end == ' ')) {
        *end = '\0';
        end--;
    }

    if (strlen(dev) == 0) return 0;

    /* Take the first device */
    char *space = strchr(dev, ' ');
    if (space) *space = '\0';

    strncpy(phys_dev, dev, phys_dev_size - 1);
    phys_dev[phys_dev_size - 1] = '\0';
    return 1;
}

/* Create a wlan device from a physical wireless device */
static int bsd_wlan_create(const char *phys_dev) {
    if (!find_ifconfig()) {
        fprintf(stderr, "ifconfig not found\n");
        return 1;
    }

    char error[MAX_OUTPUT] = {0};
    char *args[] = {ifconfig_path, "wlan0", "create", "wlandev", (char *)phys_dev, NULL};
    int ret = run_command(args, error, sizeof(error));
    if (ret != 0) {
        fprintf(stderr, "Failed to create wlan0 from %s: %s\n", phys_dev, error);
    }
    return ret;
}

/* Enable WLAN on FreeBSD: bring wlan interface up */
static int bsd_wlan_enable(void) {
    if (!find_ifconfig()) {
        fprintf(stderr, "ifconfig not found\n");
        return 1;
    }

    char wlan_dev[32] = {0};
    if (!bsd_find_wlan_device(wlan_dev, sizeof(wlan_dev))) {
        /* Try to create one */
        char phys_dev[32] = {0};
        if (bsd_find_phys_wlan(phys_dev, sizeof(phys_dev))) {
            if (bsd_wlan_create(phys_dev) != 0) {
                fprintf(stderr, "No wireless device found\n");
                return 1;
            }
            strcpy(wlan_dev, "wlan0");
        } else {
            fprintf(stderr, "No wireless hardware found\n");
            return 1;
        }
    }

    char error[MAX_OUTPUT] = {0};
    char *args[] = {ifconfig_path, wlan_dev, "up", NULL};
    int ret = run_command(args, error, sizeof(error));
    if (ret != 0) {
        fprintf(stderr, "Failed to enable %s: %s\n", wlan_dev, error);
    }
    return ret;
}

/* Disable WLAN on FreeBSD: bring wlan interface down */
static int bsd_wlan_disable(void) {
    if (!find_ifconfig()) {
        fprintf(stderr, "ifconfig not found\n");
        return 1;
    }

    char wlan_dev[32] = {0};
    if (!bsd_find_wlan_device(wlan_dev, sizeof(wlan_dev))) {
        fprintf(stderr, "No wireless device found\n");
        return 1;
    }

    char error[MAX_OUTPUT] = {0};
    char *args[] = {ifconfig_path, wlan_dev, "down", NULL};
    int ret = run_command(args, error, sizeof(error));
    if (ret != 0) {
        fprintf(stderr, "Failed to disable %s: %s\n", wlan_dev, error);
    }
    return ret;
}

/* Connect to a WLAN on FreeBSD using wpa_cli + dhclient */
static int bsd_wlan_connect(const char *ssid, const char *password) {
    char wlan_dev[32] = {0};
    if (!bsd_find_wlan_device(wlan_dev, sizeof(wlan_dev))) {
        fprintf(stderr, "No wireless device found\n");
        return 1;
    }

    if (!find_wpa_cli()) {
        fprintf(stderr, "wpa_cli not found\n");
        return 1;
    }

    /* Bring interface up */
    if (find_ifconfig()) {
        char error[MAX_OUTPUT] = {0};
        char *up_args[] = {ifconfig_path, wlan_dev, "up", NULL};
        run_command(up_args, error, sizeof(error));
    }

    /* Ensure wpa_supplicant is running for this device */
    {
        char cmd[512];
        struct stat st;
        char socket_path[256];
        
        /* Check if wpa_supplicant socket exists for this device */
        snprintf(socket_path, sizeof(socket_path), "/var/run/wpa_supplicant/%s", wlan_dev);
        
        if (stat(socket_path, &st) != 0) {
            /* Socket doesn't exist, create config if needed and start wpa_supplicant */
            fprintf(stderr, "network-helper: Starting wpa_supplicant for %s\n", wlan_dev);
            
            /* Create basic wpa_supplicant.conf if it doesn't exist */
            if (access("/etc/wpa_supplicant.conf", F_OK) != 0) {
                FILE *conf = fopen("/etc/wpa_supplicant.conf", "w");
                if (conf) {
                    fprintf(conf, "ctrl_interface=/var/run/wpa_supplicant\n");
                    fprintf(conf, "ctrl_interface_group=wheel\n");
                    fprintf(conf, "update_config=1\n");
                    fclose(conf);
                    chmod("/etc/wpa_supplicant.conf", 0600);
                    fprintf(stderr, "network-helper: Created /etc/wpa_supplicant.conf\n");
                } else {
                    fprintf(stderr, "network-helper: Could not create /etc/wpa_supplicant.conf\n");
                }
            }
            
            /* Start wpa_supplicant */
            snprintf(cmd, sizeof(cmd), "/usr/sbin/wpa_supplicant -B -i %s -c /etc/wpa_supplicant.conf", wlan_dev);
            fprintf(stderr, "network-helper: Running: %s\n", cmd);
            int ret = system(cmd);
            fprintf(stderr, "network-helper: wpa_supplicant started with return code %d\n", ret);
            /* Give it a moment to start */
            sleep(2);
        }
    }

    /* Add network via wpa_cli */
    char cmd[512];
    FILE *fp;
    int network_id = -1;

    snprintf(cmd, sizeof(cmd), "%s -i %s add_network 2>/dev/null", wpa_cli_path, wlan_dev);
    fp = popen(cmd, "r");
    if (fp) {
        char buf[64];
        if (fgets(buf, sizeof(buf), fp)) {
            network_id = atoi(buf);
        }
        pclose(fp);
    }

    if (network_id < 0) {
        fprintf(stderr, "Failed to add network in wpa_supplicant (network_id=%d)\n", network_id);
        return 1;
    }

    /* Set SSID */
    snprintf(cmd, sizeof(cmd), "%s -i %s set_network %d ssid '\"%s\"' >/dev/null 2>&1",
             wpa_cli_path, wlan_dev, network_id, ssid);
    if (system(cmd) != 0) {
        fprintf(stderr, "Error: Failed to configure SSID in wpa_supplicant\n");
        return 1;
    }

    /* Set password or open network */
    if (password && password[0] != '\0') {
        snprintf(cmd, sizeof(cmd), "%s -i %s set_network %d psk '\"%s\"' >/dev/null 2>&1",
                 wpa_cli_path, wlan_dev, network_id, password);
        if (system(cmd) != 0) {
            fprintf(stderr, "Error: Failed to set WiFi password\n");
            return 1;
        }
    } else {
        snprintf(cmd, sizeof(cmd), "%s -i %s set_network %d key_mgmt NONE >/dev/null 2>&1",
                 wpa_cli_path, wlan_dev, network_id);
        if (system(cmd) != 0) {
            fprintf(stderr, "Error: Failed to configure open network\n");
            return 1;
        }
    }

    /* Enable network (silent) */
    snprintf(cmd, sizeof(cmd), "%s -i %s enable_network %d >/dev/null 2>&1",
             wpa_cli_path, wlan_dev, network_id);
    system(cmd);

    /* Select network (silent) */
    snprintf(cmd, sizeof(cmd), "%s -i %s select_network %d >/dev/null 2>&1",
             wpa_cli_path, wlan_dev, network_id);
    system(cmd);

    /* Save config (silent) */
    snprintf(cmd, sizeof(cmd), "%s -i %s save_config >/dev/null 2>&1",
             wpa_cli_path, wlan_dev);
    system(cmd);

    /* Wait for association */
    fprintf(stdout, "Connecting to '%s'...\n", ssid);
    int connected = 0;
    int wait_count = 0;
    for (int i = 0; i < 15; i++) {
        sleep(1);
        wait_count++;
        if (wait_count % 3 == 0) {
            fprintf(stdout, "  (waiting for authentication)\n");
        }
        
        snprintf(cmd, sizeof(cmd), "%s -i %s status 2>/dev/null", wpa_cli_path, wlan_dev);
        fp = popen(cmd, "r");
        if (fp) {
            char line[256];
            while (fgets(line, sizeof(line), fp)) {
                if (strstr(line, "wpa_state=COMPLETED")) {
                    connected = 1;
                    break;
                }
            }
            pclose(fp);
        }
        if (connected) break;
    }

    if (!connected) {
        fprintf(stderr, "Error: Failed to authenticate with '%s'\n", ssid);
        fprintf(stderr, "  Please check your password and network signal\n");
        return 1;
    }

    fprintf(stdout, "Authentication successful!\n");
    fprintf(stdout, "Requesting IP address via DHCP...\n");

    /* Request DHCP */
    if (find_dhclient()) {
        /* Kill existing dhclient on this interface */
        char kill_cmd[256];
        snprintf(kill_cmd, sizeof(kill_cmd), "pkill -f 'dhclient.*%s' 2>/dev/null", wlan_dev);
        system(kill_cmd);
        usleep(500000);

        char error[MAX_OUTPUT] = {0};
        char *dhcp_args[] = {dhclient_path, wlan_dev, NULL};
        int ret = run_command(dhcp_args, error, sizeof(error));
        if (ret != 0) {
            if (strstr(error, "Cannot open or create pidfile") != NULL) {
                fprintf(stderr, "Error: DHCP client cannot access /var/run (permission issue)\n");
                fprintf(stderr, "  Ensure you are running this command with appropriate privileges\n");
            } else if (strstr(error, "No DHCPOFFERS") != NULL) {
                fprintf(stderr, "Error: No DHCP offers received from network\n");
                fprintf(stderr, "  The network may not have a DHCP server available\n");
            } else if (error[0] != '\0') {
                fprintf(stderr, "Error: DHCP request failed on %s\n", wlan_dev);
                fprintf(stderr, "  Details: %s\n", error);
            } else {
                fprintf(stderr, "Error: DHCP request failed on %s\n", wlan_dev);
            }
            return ret;
        }
    } else if (find_dhcpcd()) {
        char error[MAX_OUTPUT] = {0};
        char *dhcp_args[] = {dhcpcd_path, "-4", "-t", "30", wlan_dev, NULL};
        int ret = run_command(dhcp_args, error, sizeof(error));
        if (ret != 0) {
            if (strstr(error, "Cannot open or create pidfile") != NULL) {
                fprintf(stderr, "Error: DHCP client cannot access /var/run (permission issue)\n");
                fprintf(stderr, "  Ensure you are running this command with appropriate privileges\n");
            } else if (strstr(error, "timed out") != NULL) {
                fprintf(stderr, "Error: DHCP request timed out\n");
                fprintf(stderr, "  The network may be unreachable or has no DHCP server\n");
            } else if (error[0] != '\0') {
                fprintf(stderr, "Error: DHCP request failed on %s\n", wlan_dev);
                fprintf(stderr, "  Details: %s\n", error);
            } else {
                fprintf(stderr, "Error: DHCP request failed on %s\n", wlan_dev);
            }
            return ret;
        }
    } else {
        fprintf(stderr, "Error: No DHCP client found (dhclient or dhcpcd)\n");
        fprintf(stderr, "  WiFi connection established but cannot configure IP address\n");
        return 1;
    }

    fprintf(stdout, "Successfully connected to '%s'\n", ssid);
    fprintf(stdout, "Use 'ip addr show' to check your IP address\n");
    return 0;
}

/* Disconnect from WLAN on FreeBSD */
static int bsd_wlan_disconnect(void) {
    char wlan_dev[32] = {0};
    if (!bsd_find_wlan_device(wlan_dev, sizeof(wlan_dev))) {
        fprintf(stderr, "No wireless device found\n");
        return 1;
    }

    /* Use wpa_cli disconnect if available */
    if (find_wpa_cli()) {
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "%s -i %s disconnect 2>/dev/null",
                 wpa_cli_path, wlan_dev);
        system(cmd);
    }

    /* Release DHCP */
    char kill_cmd[256];
    snprintf(kill_cmd, sizeof(kill_cmd), "pkill -f 'dhclient.*%s' 2>/dev/null", wlan_dev);
    system(kill_cmd);

    return 0;
}

/* Enable an interface on FreeBSD */
static int bsd_interface_enable(const char *device) {
    if (!find_ifconfig()) {
        fprintf(stderr, "ifconfig not found\n");
        return 1;
    }

    char error[MAX_OUTPUT] = {0};
    char *args[] = {ifconfig_path, (char *)device, "up", NULL};
    int ret = run_command(args, error, sizeof(error));
    if (ret != 0) {
        fprintf(stderr, "Failed to enable %s: %s\n", device, error);
        return ret;
    }

    /* If DHCP, request a lease */
    if (find_dhclient()) {
        char *dhcp_args[] = {dhclient_path, (char *)device, NULL};
        run_command(dhcp_args, error, sizeof(error));
    } else if (find_dhcpcd()) {
        char *dhcp_args[] = {dhcpcd_path, "-4", "-t", "30", (char *)device, NULL};
        run_command(dhcp_args, error, sizeof(error));
    }

    return 0;
}

/* Disable an interface on FreeBSD */
static int bsd_interface_disable(const char *device) {
    if (!find_ifconfig()) {
        fprintf(stderr, "ifconfig not found\n");
        return 1;
    }

    /* Kill dhclient for this interface */
    char kill_cmd[256];
    snprintf(kill_cmd, sizeof(kill_cmd), "pkill -f 'dhclient.*%s' 2>/dev/null", device);
    system(kill_cmd);

    char error[MAX_OUTPUT] = {0};
    char *args[] = {ifconfig_path, (char *)device, "down", NULL};
    int ret = run_command(args, error, sizeof(error));
    if (ret != 0) {
        fprintf(stderr, "Failed to disable %s: %s\n", device, error);
    }
    return ret;
}

/* DHCP renew on FreeBSD using dhclient */
static int bsd_dhcp_renew(const char *interface) {
    if (find_dhclient()) {
        /* Kill existing dhclient */
        char kill_cmd[256];
        snprintf(kill_cmd, sizeof(kill_cmd), "pkill -f 'dhclient.*%s' 2>/dev/null", interface);
        system(kill_cmd);
        usleep(500000);

        char error[MAX_OUTPUT] = {0};
        char *args[] = {dhclient_path, (char *)interface, NULL};
        int ret = run_command(args, error, sizeof(error));
        if (ret != 0) {
            fprintf(stderr, "dhclient failed on %s: %s\n", interface, error);
        }
        return ret;
    }
    /* Fall back to dhcpcd */
    return dhcp_renew(interface);
}

/* DHCP release on FreeBSD */
static int bsd_dhcp_release(const char *interface) {
    if (find_dhclient()) {
        char kill_cmd[256];
        snprintf(kill_cmd, sizeof(kill_cmd), "pkill -f 'dhclient.*%s' 2>/dev/null", interface);
        system(kill_cmd);
        return 0;
    }
    return dhcp_release(interface);
}

/* Delete a saved wpa_supplicant network by SSID */
static int bsd_connection_delete(const char *ssid) {
    char wlan_dev[32] = {0};
    if (!bsd_find_wlan_device(wlan_dev, sizeof(wlan_dev))) {
        fprintf(stderr, "No wireless device found\n");
        return 1;
    }

    if (!find_wpa_cli()) {
        fprintf(stderr, "wpa_cli not found\n");
        return 1;
    }

    /* List networks and find matching SSID */
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "%s -i %s list_networks 2>/dev/null", wpa_cli_path, wlan_dev);
    FILE *fp = popen(cmd, "r");
    if (!fp) {
        fprintf(stderr, "Failed to list networks\n");
        return 1;
    }

    char line[256];
    int found_id = -1;
    while (fgets(line, sizeof(line), fp)) {
        /* Format: "0\tMyNetwork\tany\t[CURRENT]" */
        int net_id;
        char net_ssid[128];
        if (sscanf(line, "%d\t%127[^\t]", &net_id, net_ssid) >= 2) {
            if (strcmp(net_ssid, ssid) == 0) {
                found_id = net_id;
                break;
            }
        }
    }
    pclose(fp);

    if (found_id < 0) {
        fprintf(stderr, "Network '%s' not found in wpa_supplicant\n", ssid);
        return 1;
    }

    snprintf(cmd, sizeof(cmd), "%s -i %s remove_network %d 2>/dev/null",
             wpa_cli_path, wlan_dev, found_id);
    system(cmd);

    snprintf(cmd, sizeof(cmd), "%s -i %s save_config 2>/dev/null",
             wpa_cli_path, wlan_dev);
    system(cmd);

    fprintf(stdout, "Removed network '%s'\n", ssid);
    return 0;
}

/* Run a command with stdout capture (needed for BSD find_wlan_device) */
static int run_command_with_output(char *const args[], char *output_buf, size_t output_buf_size,
                                    char *error_buf, size_t error_buf_size) {
    if (!args || !args[0]) return 1;

    int stdout_pipe[2];
    int stderr_pipe[2];

    if (pipe(stdout_pipe) < 0 || pipe(stderr_pipe) < 0) {
        if (error_buf) snprintf(error_buf, error_buf_size, "pipe failed");
        return 1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(stdout_pipe[0]); close(stdout_pipe[1]);
        close(stderr_pipe[0]); close(stderr_pipe[1]);
        return 1;
    }

    if (pid == 0) {
        close(stdout_pipe[0]);
        close(stderr_pipe[0]);
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stderr_pipe[1], STDERR_FILENO);
        close(stdout_pipe[1]);
        close(stderr_pipe[1]);
        execv(args[0], args);
        _exit(127);
    }

    close(stdout_pipe[1]);
    close(stderr_pipe[1]);

    if (output_buf && output_buf_size > 0) {
        ssize_t n = read(stdout_pipe[0], output_buf, output_buf_size - 1);
        output_buf[n > 0 ? n : 0] = '\0';
    }
    close(stdout_pipe[0]);

    if (error_buf && error_buf_size > 0) {
        ssize_t n = read(stderr_pipe[0], error_buf, error_buf_size - 1);
        if (n > 0) {
            error_buf[n] = '\0';
        } else {
            error_buf[0] = '\0';
        }
    }
    close(stderr_pipe[0]);

    int status;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

/*
 * Setup a NIC on FreeBSD, similar to GhostBSD's setup-nic.py.
 *
 * For WiFi NICs: creates /etc/wpa_supplicant.conf if missing,
 * writes wlans_<nic>="wlan<N>" and ifconfig_wlan<N>="WPA DHCP"
 * to rc.conf via sysrc, runs /etc/pccard_ether <nic> startchildren.
 *
 * For Ethernet NICs: writes ifconfig_<nic>=DHCP to rc.conf,
 * runs /etc/pccard_ether <nic> start.
 */

/* Regex-style check: is this a known WiFi driver name? */
static int is_wifi_driver(const char *nic) {
    /* Taken from devd.conf wifi-driver-regex, same as GhostBSD setup-nic.py */
    static const char *wifi_prefixes[] = {
        "ath", "bwi", "bwn", "ipw", "iwlwifi", "iwi", "iwm", "iwn",
        "malo", "mwl", "mt79", "otus", "ral", "rsu", "rtw", "rtwn",
        "rum", "run", "uath", "upgt", "ural", "urtw", "wpi", "wtap",
        "zyd", NULL
    };
    for (int i = 0; wifi_prefixes[i]; i++) {
        size_t plen = strlen(wifi_prefixes[i]);
        if (strncmp(nic, wifi_prefixes[i], plen) == 0) {
            /* Rest must be digits (e.g., iwm0, ath10k0) */
            const char *rest = nic + plen;
            if (*rest == '\0') return 1; /* bare name, unusual but accept */
            while (*rest) {
                if (*rest < '0' || *rest > '9') return 0;
                rest++;
            }
            return 1;
        }
    }
    /* Also handle ath followed by digits+k patterns like ath10k */
    if (strncmp(nic, "ath", 3) == 0) {
        const char *rest = nic + 3;
        while (*rest >= '0' && *rest <= '9') rest++;
        if (*rest == 'k') {
            rest++;
            while (*rest >= '0' && *rest <= '9') rest++;
            if (*rest == '\0') return 1;
        }
    }
    return 0;
}

/* Check if a NIC should be skipped (pseudo-interface) */
static int is_pseudo_nic(const char *nic) {
    static const char *pseudo_prefixes[] = {
        "enc", "lo", "fwe", "fwip", "tap", "plip", "pfsync", "pflog",
        "ipfw", "tun", "sl", "faith", "ppp", "bridge", "wg", "wlan",
        NULL
    };
    for (int i = 0; pseudo_prefixes[i]; i++) {
        size_t plen = strlen(pseudo_prefixes[i]);
        if (strncmp(nic, pseudo_prefixes[i], plen) == 0) {
            const char *rest = nic + plen;
            while (*rest) {
                if (*rest < '0' || *rest > '9') return 0;
                rest++;
            }
            return 1;
        }
    }
    /* vm-* interfaces */
    if (strncmp(nic, "vm-", 3) == 0) return 1;
    return 0;
}

/* Read the contents of /etc/rc.conf (and /etc/rc.conf.local if it exists) */
static int read_rc_conf(char *buf, size_t buf_size) {
    buf[0] = '\0';
    FILE *f = fopen("/etc/rc.conf", "r");
    if (!f) return 0;
    size_t total = 0;
    size_t nread;
    char tmp[4096];
    while ((nread = fread(tmp, 1, sizeof(tmp), f)) > 0 && total + nread < buf_size - 1) {
        memcpy(buf + total, tmp, nread);
        total += nread;
    }
    fclose(f);
    buf[total] = '\0';

    /* Also append /etc/rc.conf.local if it exists */
    f = fopen("/etc/rc.conf.local", "r");
    if (f) {
        while ((nread = fread(tmp, 1, sizeof(tmp), f)) > 0 && total + nread < buf_size - 1) {
            memcpy(buf + total, tmp, nread);
            total += nread;
        }
        fclose(f);
        buf[total] = '\0';
    }
    return 1;
}

static int bsd_setup_nic(const char *nic) {
    if (!nic || !*nic) {
        fprintf(stderr, "setup-nic: no NIC specified\n");
        return 1;
    }

    /* Skip pseudo-interfaces */
    if (is_pseudo_nic(nic)) {
        fprintf(stdout, "setup-nic: skipping pseudo-interface %s\n", nic);
        return 0;
    }

    /* Read current rc.conf content */
    char rc_content[32768];
    if (!read_rc_conf(rc_content, sizeof(rc_content))) {
        fprintf(stderr, "setup-nic: cannot read /etc/rc.conf\n");
        return 1;
    }

    if (is_wifi_driver(nic)) {
        fprintf(stdout, "setup-nic: %s is a WiFi driver\n", nic);

        /* Ensure /etc/wpa_supplicant.conf exists */
        struct stat st;
        if (stat("/etc/wpa_supplicant.conf", &st) != 0) {
            fprintf(stdout, "setup-nic: creating /etc/wpa_supplicant.conf\n");
            int fd = open("/etc/wpa_supplicant.conf", O_CREAT | O_WRONLY | O_TRUNC, 0600);
            if (fd >= 0) {
                /* Write a minimal config */
                const char *initial =
                    "# wpa_supplicant configuration\n"
                    "ctrl_interface=/var/run/wpa_supplicant\n"
                    "ctrl_interface_group=wheel\n"
                    "update_config=1\n";
                ssize_t dummy = write(fd, initial, strlen(initial));
                (void)dummy;
                close(fd);
                /* Ensure ownership: root:wheel, mode 0600 */
                chmod("/etc/wpa_supplicant.conf", 0600);
            } else {
                fprintf(stderr, "setup-nic: cannot create /etc/wpa_supplicant.conf: %s\n",
                        strerror(errno));
            }
        }

        /* Check if wlans_<nic>= already set in rc.conf */
        char wlans_key[128];
        snprintf(wlans_key, sizeof(wlans_key), "wlans_%s=", nic);
        if (!strstr(rc_content, wlans_key)) {
            /* Find a free wlanN */
            int wlan_num = -1;
            for (int n = 0; n < 9; n++) {
                char wlan_name[16];
                snprintf(wlan_name, sizeof(wlan_name), "wlan%d", n);
                if (!strstr(rc_content, wlan_name)) {
                    wlan_num = n;
                    break;
                }
            }
            if (wlan_num < 0) {
                fprintf(stderr, "setup-nic: no free wlan device number found\n");
                return 1;
            }

            fprintf(stdout, "setup-nic: configuring %s -> wlan%d\n", nic, wlan_num);

            if (find_sysrc()) {
                char sysrc_arg1[256];
                char sysrc_arg2[256];
                char error[MAX_OUTPUT] = {0};

                /* sysrc wlans_<nic>="wlan<N>" */
                snprintf(sysrc_arg1, sizeof(sysrc_arg1),
                         "wlans_%s=wlan%d", nic, wlan_num);
                char *args1[] = {sysrc_path, sysrc_arg1, NULL};
                int ret = run_command(args1, error, sizeof(error));
                if (ret != 0) {
                    fprintf(stderr, "setup-nic: sysrc failed: %s\n", error);
                    return 1;
                }

                /* sysrc ifconfig_wlan<N>="WPA DHCP" */
                snprintf(sysrc_arg2, sizeof(sysrc_arg2),
                         "ifconfig_wlan%d=WPA DHCP", wlan_num);
                char *args2[] = {sysrc_path, sysrc_arg2, NULL};
                ret = run_command(args2, error, sizeof(error));
                if (ret != 0) {
                    fprintf(stderr, "setup-nic: sysrc failed: %s\n", error);
                    return 1;
                }
            } else {
                fprintf(stderr, "setup-nic: sysrc not found, cannot configure rc.conf\n");
                return 1;
            }
        } else {
            fprintf(stdout, "setup-nic: %s already has wlans_ entry in rc.conf\n", nic);
        }

        /* Run /etc/pccard_ether <nic> startchildren if it exists */
        struct stat pccard_st;
        if (stat("/etc/pccard_ether", &pccard_st) == 0) {
            char error[MAX_OUTPUT] = {0};
            char *args[] = {"/etc/pccard_ether", (char *)nic, "startchildren", NULL};
            fprintf(stdout, "setup-nic: running /etc/pccard_ether %s startchildren\n", nic);
            int ret = run_command(args, error, sizeof(error));
            if (ret != 0) {
                fprintf(stderr, "setup-nic: pccard_ether failed: %s\n", error);
                /* Non-fatal: pccard_ether may not be needed */
            }
        }

        /* Also ensure wpa_supplicant is running for this wlan device */
        if (find_wpa_supplicant()) {
            /* Check if wpa_supplicant is already running for the wlan interface */
            char check_cmd[256];
            snprintf(check_cmd, sizeof(check_cmd),
                     "pgrep -f 'wpa_supplicant.*wlan' >/dev/null 2>&1");
            if (system(check_cmd) != 0) {
                /* Not running; the rc system should start it, but give a hint */
                fprintf(stdout,
                    "setup-nic: wpa_supplicant not running; it will be started by rc\n");
            }
        }

        fprintf(stdout, "setup-nic: WiFi NIC %s configured\n", nic);

    } else {
        /* Ethernet NIC */
        fprintf(stdout, "setup-nic: %s is an Ethernet NIC\n", nic);

        /* Check if ifconfig_<nic>= already set in rc.conf */
        char ifconfig_key[128];
        snprintf(ifconfig_key, sizeof(ifconfig_key), "ifconfig_%s=", nic);
        if (!strstr(rc_content, ifconfig_key)) {
            fprintf(stdout, "setup-nic: configuring %s for DHCP\n", nic);

            if (find_sysrc()) {
                char sysrc_arg[256];
                char error[MAX_OUTPUT] = {0};

                /* sysrc ifconfig_<nic>=DHCP */
                snprintf(sysrc_arg, sizeof(sysrc_arg), "ifconfig_%s=DHCP", nic);
                char *args[] = {sysrc_path, sysrc_arg, NULL};
                int ret = run_command(args, error, sizeof(error));
                if (ret != 0) {
                    fprintf(stderr, "setup-nic: sysrc failed: %s\n", error);
                    return 1;
                }
            } else {
                fprintf(stderr, "setup-nic: sysrc not found, cannot configure rc.conf\n");
                return 1;
            }
        } else {
            fprintf(stdout, "setup-nic: %s already has ifconfig_ entry in rc.conf\n", nic);
        }

        /* Run /etc/pccard_ether <nic> start if it exists */
        struct stat pccard_st;
        if (stat("/etc/pccard_ether", &pccard_st) == 0) {
            char error[MAX_OUTPUT] = {0};
            char *args[] = {"/etc/pccard_ether", (char *)nic, "start", NULL};
            fprintf(stdout, "setup-nic: running /etc/pccard_ether %s start\n", nic);
            int ret = run_command(args, error, sizeof(error));
            if (ret != 0) {
                fprintf(stderr, "setup-nic: pccard_ether failed: %s\n", error);
            }
        }

        fprintf(stdout, "setup-nic: Ethernet NIC %s configured\n", nic);
    }

    return 0;
}

/* Print usage */
static void usage(const char *prog) {
    fprintf(stderr, "Network Helper - Privileged network operations\n\n");
    fprintf(stderr, "Usage: %s <command> [arguments...]\n\n", prog);
    fprintf(stderr, "Commands:\n");
    fprintf(stderr, "  wlan-enable                              Enable WLAN radio\n");
    fprintf(stderr, "  wlan-disable                             Disable WLAN radio\n");
    fprintf(stderr, "  wlan-connect <ssid> [password]           Connect to WLAN network\n");
    fprintf(stderr, "  wlan-disconnect                          Disconnect from WLAN\n");
    fprintf(stderr, "  wlan-direct-connect <iface> <ssid> [pw]  Direct wpa_supplicant + DHCP connection\n");
    fprintf(stderr, "  wlan-create <phys_dev>                   Create wlan device (FreeBSD only)\n");
    fprintf(stderr, "  setup-nic <device>                       Setup NIC in rc.conf (FreeBSD only)\n");
    fprintf(stderr, "  dhcp-renew <interface>                   Renew DHCP lease on interface\n");
    fprintf(stderr, "  dhcp-release <interface>                 Release DHCP lease on interface\n");
    fprintf(stderr, "  connection-add <type> <name> [device]    Add connection (Linux only)\n");
    fprintf(stderr, "  connection-delete <name>                 Delete connection\n");
    fprintf(stderr, "  connection-up <name>                     Activate connection\n");
    fprintf(stderr, "  connection-down <name>                   Deactivate connection\n");
    fprintf(stderr, "  interface-enable <device>                Enable interface\n");
    fprintf(stderr, "  interface-disable <device>               Disable interface\n");
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        usage(argv[0]);
        return 1;
    }

    detect_os();

    if (!is_freebsd) {
        if (!find_nmcli()) {
            fprintf(stderr, "Error: nmcli not found. Is NetworkManager installed?\n");
            return 1;
        }
    } else {
        if (!find_ifconfig()) {
            fprintf(stderr, "Error: ifconfig not found on FreeBSD.\n");
            return 1;
        }
    }
    
    const char *command = argv[1];
    int result = 0;
    
    if (strcmp(command, "wlan-enable") == 0) {
        result = is_freebsd ? bsd_wlan_enable() : wlan_enable();
    } else if (strcmp(command, "wlan-disable") == 0) {
        result = is_freebsd ? bsd_wlan_disable() : wlan_disable();
    } else if (strcmp(command, "wlan-connect") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Error: wlan-connect requires SSID argument\n");
            result = 1;
        } else {
            const char *ssid = argv[2];
            const char *password = (argc >= 4) ? argv[3] : NULL;
            result = is_freebsd ? bsd_wlan_connect(ssid, password) : wlan_connect(ssid, password);
        }
    } else if (strcmp(command, "wlan-disconnect") == 0) {
        result = is_freebsd ? bsd_wlan_disconnect() : wlan_disconnect();
    } else if (strcmp(command, "wlan-direct-connect") == 0) {
        if (argc < 4) {
            fprintf(stderr, "Error: wlan-direct-connect requires interface and SSID arguments\n");
            result = 1;
        } else {
            const char *interface = argv[2];
            const char *ssid = argv[3];
            const char *password = (argc >= 5) ? argv[4] : NULL;
            if (is_freebsd) {
                /* On FreeBSD, wlan-connect already does the direct method */
                (void)interface;
                result = bsd_wlan_connect(ssid, password);
            } else {
                result = wlan_direct_connect(interface, ssid, password);
            }
        }
    } else if (strcmp(command, "dhcp-renew") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Error: dhcp-renew requires interface argument\n");
            result = 1;
        } else {
            const char *interface = argv[2];
            result = is_freebsd ? bsd_dhcp_renew(interface) : dhcp_renew(interface);
        }
    } else if (strcmp(command, "dhcp-release") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Error: dhcp-release requires interface argument\n");
            result = 1;
        } else {
            const char *interface = argv[2];
            result = is_freebsd ? bsd_dhcp_release(interface) : dhcp_release(interface);
        }
    } else if (strcmp(command, "connection-add") == 0) {
        if (is_freebsd) {
            fprintf(stderr, "connection-add not supported on FreeBSD (use wlan-connect)\n");
            result = 1;
        } else if (argc < 4) {
            fprintf(stderr, "Error: connection-add requires type and name arguments\n");
            result = 1;
        } else {
            const char *type = argv[2];
            const char *name = argv[3];
            const char *device = (argc >= 5) ? argv[4] : NULL;
            result = connection_add(type, name, device);
        }
    } else if (strcmp(command, "connection-delete") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Error: connection-delete requires name argument\n");
            result = 1;
        } else {
            const char *name = argv[2];
            result = is_freebsd ? bsd_connection_delete(name) : connection_delete(name);
        }
    } else if (strcmp(command, "connection-up") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Error: connection-up requires name argument\n");
            result = 1;
        } else {
            const char *name = argv[2];
            if (is_freebsd) {
                /* On FreeBSD, connection-up enables the interface */
                result = bsd_interface_enable(name);
            } else {
                result = connection_up(name);
            }
        }
    } else if (strcmp(command, "connection-down") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Error: connection-down requires name argument\n");
            result = 1;
        } else {
            const char *name = argv[2];
            if (is_freebsd) {
                result = bsd_interface_disable(name);
            } else {
                result = connection_down(name);
            }
        }
    } else if (strcmp(command, "interface-enable") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Error: interface-enable requires device argument\n");
            result = 1;
        } else {
            const char *device = argv[2];
            result = is_freebsd ? bsd_interface_enable(device) : interface_enable(device);
        }
    } else if (strcmp(command, "interface-disable") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Error: interface-disable requires device argument\n");
            result = 1;
        } else {
            const char *device = argv[2];
            result = is_freebsd ? bsd_interface_disable(device) : interface_disable(device);
        }
    } else if (strcmp(command, "wlan-create") == 0) {
        if (!is_freebsd) {
            fprintf(stderr, "wlan-create is only supported on FreeBSD\n");
            result = 1;
        } else if (argc < 3) {
            fprintf(stderr, "Error: wlan-create requires physical device argument\n");
            result = 1;
        } else {
            const char *phys_dev = argv[2];
            result = bsd_wlan_create(phys_dev);
        }
    } else if (strcmp(command, "setup-nic") == 0) {
        if (!is_freebsd) {
            fprintf(stderr, "setup-nic is only supported on FreeBSD\n");
            result = 1;
        } else if (argc < 3) {
            fprintf(stderr, "Error: setup-nic requires device argument\n");
            result = 1;
        } else {
            const char *device = argv[2];
            result = bsd_setup_nic(device);
        }
    } else {
        fprintf(stderr, "Error: Unknown command '%s'\n\n", command);
        usage(argv[0]);
        result = 1;
    }
    
    return result;
}

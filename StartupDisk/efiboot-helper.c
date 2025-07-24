#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <errno.h>

#define MAX_LINE 1024
#define MAX_ARGS 32

// Function to execute a command and return its output
int execute_command(char *command, char *output, int output_size, char *error, int error_size) {
    FILE *fp;
    char *line = NULL;
    size_t len = 0;
    ssize_t read;
    int status;
    
    // Clear output buffers
    output[0] = '\0';
    error[0] = '\0';
    
    // Execute the command
    fp = popen(command, "r");
    if (fp == NULL) {
        snprintf(error, error_size, "Failed to execute command: %s", strerror(errno));
        return -1;
    }
    
    // Read output
    while ((read = getline(&line, &len, fp)) != -1) {
        if (strlen(output) + read < output_size - 1) {
            strcat(output, line);
        }
    }
    
    if (line) {
        free(line);
    }
    
    status = pclose(fp);
    return WEXITSTATUS(status);
}

// Function to list boot entries
void list_boot_entries() {
    char output[4096];
    char error[1024];
    int result;
    
    printf("COMMAND:list\n");
    result = execute_command("/usr/sbin/efibootmgr -v", output, sizeof(output), error, sizeof(error));
    
    printf("RESULT:%d\n", result);
    printf("OUTPUT_START\n");
    printf("%s", output);
    printf("OUTPUT_END\n");
    if (strlen(error) > 0) {
        printf("ERROR_START\n");
        printf("%s", error);
        printf("ERROR_END\n");
    }
    printf("COMMAND_END\n");
    fflush(stdout);
}

// Function to set next boot entry
void set_next_boot(char *bootnum) {
    char command[256];
    char output[1024];
    char error[1024];
    int result;
    
    printf("COMMAND:set_next_boot\n");
    snprintf(command, sizeof(command), "/usr/sbin/efibootmgr -n -b %s", bootnum);
    result = execute_command(command, output, sizeof(output), error, sizeof(error));
    
    printf("RESULT:%d\n", result);
    printf("OUTPUT_START\n");
    printf("%s", output);
    printf("OUTPUT_END\n");
    if (strlen(error) > 0) {
        printf("ERROR_START\n");
        printf("%s", error);
        printf("ERROR_END\n");
    }
    printf("COMMAND_END\n");
    fflush(stdout);
}

// Function to restart system
void restart_system() {
    char output[1024];
    char error[1024];
    int result;
    
    printf("COMMAND:restart\n");
    result = execute_command("/sbin/shutdown -r now", output, sizeof(output), error, sizeof(error));
    
    printf("RESULT:%d\n", result);
    printf("OUTPUT_START\n");
    printf("%s", output);
    printf("OUTPUT_END\n");
    if (strlen(error) > 0) {
        printf("ERROR_START\n");
        printf("%s", error);
        printf("ERROR_END\n");
    }
    printf("COMMAND_END\n");
    fflush(stdout);
}

int main() {
    char line[MAX_LINE];
    char *token;
    
    printf("READY\n");
    fflush(stdout);
    
    // Main command loop
    while (fgets(line, sizeof(line), stdin)) {
        // Remove newline
        line[strcspn(line, "\n")] = 0;
        
        if (strcmp(line, "list") == 0) {
            list_boot_entries();
        } else if (strncmp(line, "set_next_boot ", 14) == 0) {
            char *bootnum = line + 14;
            set_next_boot(bootnum);
        } else if (strcmp(line, "restart") == 0) {
            restart_system();
        } else if (strcmp(line, "quit") == 0) {
            break;
        } else if (strcmp(line, "ping") == 0) {
            printf("PONG\n");
            fflush(stdout);
        } else {
            printf("COMMAND:unknown\n");
            printf("RESULT:-1\n");
            printf("ERROR_START\nUnknown command: %s\nERROR_END\n", line);
            printf("COMMAND_END\n");
            fflush(stdout);
        }
    }
    
    return 0;
}

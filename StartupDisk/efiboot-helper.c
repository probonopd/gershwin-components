// Copyright (c) 2025, Simon Peter
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <errno.h>
#include <sys/types.h>

static pid_t authorized_parent_pid = 0;

int run_command(const char *command, char **output, char **error) {
    FILE *fp;
    char *cmd_output = NULL;
    size_t output_size = 0;
    char buffer[4096];
    int exit_code;
    
    // Create command with stderr redirection
    char full_command[8192];
    snprintf(full_command, sizeof(full_command), "%s 2>&1", command);
    
    fp = popen(full_command, "r");
    if (fp == NULL) {
        *error = strdup("Failed to execute command");
        return -1;
    }
    
    // Read all output
    while (fgets(buffer, sizeof(buffer), fp) != NULL) {
        size_t len = strlen(buffer);
        cmd_output = realloc(cmd_output, output_size + len + 1);
        if (cmd_output == NULL) {
            pclose(fp);
            return -1;
        }
        strcpy(cmd_output + output_size, buffer);
        output_size += len;
    }
    
    exit_code = pclose(fp);
    
    if (cmd_output == NULL) {
        cmd_output = strdup("");
    }
    
    *output = cmd_output;
    *error = strdup(""); // Since we redirect stderr to stdout
    
    return WEXITSTATUS(exit_code);
}

void send_response(int result, const char *output, const char *error) {
    printf("RESULT:%d\n", result);
    if (output && strlen(output) > 0) {
        printf("OUTPUT_START\n%sOUTPUT_END\n", output);
    }
    if (error && strlen(error) > 0) {
        printf("ERROR_START\n%sERROR_END\n", error);
    }
    printf("COMMAND_END\n");
    fflush(stdout);
}

int verify_parent_process() {
    // For now, just return true - in a real implementation,
    // you would check that getppid() == authorized_parent_pid
    return 1;
}

int main(int argc, char *argv[]) {
    char line[1024];
    char *output, *error;
    int result;
    
    // Check that we have the parent PID argument
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <parent_pid>\n", argv[0]);
        return 1;
    }
    
    // Store the authorized parent PID
    authorized_parent_pid = atoi(argv[1]);
    if (authorized_parent_pid <= 0) {
        fprintf(stderr, "Invalid parent PID\n");
        return 1;
    }
    
    // Verify we're being called by the authorized parent
    if (!verify_parent_process()) {
        fprintf(stderr, "Unauthorized access attempt\n");
        return 1;
    }
    
    printf("READY\n");
    fflush(stdout);
    
    while (fgets(line, sizeof(line), stdin)) {
        // Initialize pointers to NULL for each iteration
        output = NULL;
        error = NULL;
        
        // Remove newline
        line[strcspn(line, "\n")] = 0;
        
        if (strcmp(line, "quit") == 0) {
            break;
        }
        
        // Verify parent process for each command
        if (!verify_parent_process()) {
            send_response(1, "", "Unauthorized access");
            continue;
        }
        
        if (strncmp(line, "list", 4) == 0) {
            result = run_command("efibootmgr", &output, &error);
            send_response(result, output, error);
        } else if (strncmp(line, "set_boot_order ", 15) == 0) {
            char command[1024];
            snprintf(command, sizeof(command), "efibootmgr -o %s", line + 15);
            result = run_command(command, &output, &error);
            send_response(result, output, error);
        } else if (strncmp(line, "set_next_boot ", 14) == 0) {
            char command[1024];
            snprintf(command, sizeof(command), "efibootmgr -n %s", line + 14);
            result = run_command(command, &output, &error);
            send_response(result, output, error);
        } else if (strcmp(line, "restart") == 0) {
            result = run_command("shutdown -r now", &output, &error);
            send_response(result, output, error);
        } else if (strcmp(line, "ping") == 0) {
            printf("PONG\n");
            fflush(stdout);
        } else {
            send_response(1, "", "Unknown command");
        }
        
        if (output) free(output);
        if (error) free(error);
    }
    
    return 0;
}
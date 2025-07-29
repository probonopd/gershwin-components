#!/bin/sh

# Create a debug version that just logs all communication
cat > debug-auth.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <string.h>
#include <errno.h>

int main() {
    int sockfd;
    struct sockaddr_un addr;
    char buffer[4096];
    ssize_t bytes;
    
    sockfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sockfd < 0) {
        perror("socket");
        return 1;
    }
    
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, "/tmp/minibus-socket");
    
    if (connect(sockfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("connect");
        return 1;
    }
    
    printf("Connected to MiniBus socket\n");
    
    // Read initial auth challenge
    bytes = read(sockfd, buffer, sizeof(buffer) - 1);
    if (bytes > 0) {
        buffer[bytes] = '\0';
        printf("Server sent: ");
        for (int i = 0; i < bytes; i++) {
            if (buffer[i] >= 32 && buffer[i] <= 126) {
                printf("%c", buffer[i]);
            } else {
                printf("\\x%02x", (unsigned char)buffer[i]);
            }
        }
        printf("\n");
    }
    
    // Send typical dbus-send auth sequence
    const char *auth1 = "\0AUTH EXTERNAL 31303030\r\n";
    write(sockfd, auth1, strlen(auth1 + 1) + 1);
    printf("Sent AUTH EXTERNAL\n");
    
    // Read response
    bytes = read(sockfd, buffer, sizeof(buffer) - 1);
    if (bytes > 0) {
        buffer[bytes] = '\0';
        printf("Server response: ");
        for (int i = 0; i < bytes; i++) {
            if (buffer[i] >= 32 && buffer[i] <= 126) {
                printf("%c", buffer[i]);
            } else {
                printf("\\x%02x", (unsigned char)buffer[i]);
            }
        }
        printf("\n");
    }
    
    // Send NEGOTIATE_UNIX_FD
    const char *negotiate = "NEGOTIATE_UNIX_FD\r\n";
    write(sockfd, negotiate, strlen(negotiate));
    printf("Sent NEGOTIATE_UNIX_FD\n");
    
    // Read response
    bytes = read(sockfd, buffer, sizeof(buffer) - 1);
    if (bytes > 0) {
        buffer[bytes] = '\0';
        printf("Server response: ");
        for (int i = 0; i < bytes; i++) {
            if (buffer[i] >= 32 && buffer[i] <= 126) {
                printf("%c", buffer[i]);
            } else {
                printf("\\x%02x", (unsigned char)buffer[i]);
            }
        }
        printf("\n");
    }
    
    // Send BEGIN
    const char *begin = "BEGIN\r\n";
    write(sockfd, begin, strlen(begin));
    printf("Sent BEGIN\n");
    
    // Now try to send a Hello message
    sleep(1);
    
    close(sockfd);
    return 0;
}
EOF

gcc -o debug-auth debug-auth.c
echo "Compiled debug-auth tool"

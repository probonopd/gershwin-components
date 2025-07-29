#!/bin/bash
# Direct protocol test

echo "=== Direct D-Bus Protocol Test ==="

# Kill any existing daemon
pkill -f minibus
sleep 1

# Clean up socket
rm -f /tmp/minibus-socket

# Start daemon in background  
echo "Starting daemon..."
export DBUS_SESSION_BUS_ADDRESS="unix:path=/tmp/minibus-socket"
./obj/minibus &
DAEMON_PID=$!
sleep 2

echo "Testing with netcat-style protocol test..."

# Create a test client that speaks D-Bus protocol directly
cat > test_client.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <errno.h>

int main() {
    int sockfd;
    struct sockaddr_un addr;
    
    // Create socket
    sockfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sockfd < 0) {
        perror("socket");
        return 1;
    }
    
    // Connect to daemon
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, "/tmp/minibus-socket");
    
    if (connect(sockfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("connect");
        return 1;
    }
    
    printf("Connected to daemon\n");
    
    // Send authentication
    const char *auth = "AUTH EXTERNAL 31303031\r\n";
    send(sockfd, auth, strlen(auth), 0);
    
    // Read OK response
    char buffer[256];
    int n = recv(sockfd, buffer, sizeof(buffer)-1, 0);
    if (n > 0) {
        buffer[n] = 0;
        printf("Auth response: %s", buffer);
    }
    
    // Send NEGOTIATE_UNIX_FD (will get ERROR)
    const char *negotiate = "NEGOTIATE_UNIX_FD\r\n";
    send(sockfd, negotiate, strlen(negotiate), 0);
    
    // Read ERROR response
    n = recv(sockfd, buffer, sizeof(buffer)-1, 0);
    if (n > 0) {
        buffer[n] = 0;
        printf("Negotiate response: %s", buffer);
    }
    
    // Send BEGIN
    const char *begin = "BEGIN\r\n";
    send(sockfd, begin, strlen(begin), 0);
    printf("Sent BEGIN\n");
    
    // Now send Hello message (hex encoded)
    unsigned char hello_msg[] = {
        0x6c, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x6e, 0x00, 0x00, 0x00,
        0x01, 0x01, 0x6f, 0x00, 0x15, 0x00, 0x00, 0x00, 0x2f, 0x6f, 0x72, 0x67, 0x2f, 0x66, 0x72, 0x65,
        0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2f, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00,
        0x06, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
        0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
        0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
        0x03, 0x01, 0x73, 0x00, 0x05, 0x00, 0x00, 0x00, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x00, 0x00
    };
    
    send(sockfd, hello_msg, sizeof(hello_msg), 0);
    printf("Sent Hello message (%ld bytes)\n", sizeof(hello_msg));
    
    // Try to read reply with timeout
    fd_set readfds;
    struct timeval timeout;
    FD_ZERO(&readfds);
    FD_SET(sockfd, &readfds);
    timeout.tv_sec = 5;
    timeout.tv_usec = 0;
    
    int ready = select(sockfd + 1, &readfds, NULL, NULL, &timeout);
    if (ready > 0) {
        n = recv(sockfd, buffer, sizeof(buffer), 0);
        if (n > 0) {
            printf("Received reply: %d bytes\n", n);
            for (int i = 0; i < n && i < 64; i++) {
                printf("%02x ", (unsigned char)buffer[i]);
                if ((i + 1) % 16 == 0) printf("\n");
            }
            if (n % 16 != 0) printf("\n");
        } else if (n == 0) {
            printf("Connection closed by daemon\n");
        } else {
            perror("recv");
        }
    } else if (ready == 0) {
        printf("Timeout waiting for reply\n");
    } else {
        perror("select");
    }
    
    close(sockfd);
    return 0;
}
EOF

# Compile test client
clang19 -o test_client test_client.c
./test_client

# Clean up
echo "Cleaning up..."
kill $DAEMON_PID 2>/dev/null
wait $DAEMON_PID 2>/dev/null
rm -f /tmp/minibus-socket test_client test_client.c

echo "=== Test complete ==="

#!/bin/bash
# Test our client against the real system D-Bus daemon

echo "=== Testing against real system D-Bus daemon ==="

# First, let's see what D-Bus session address is normally used
echo "Current D-Bus session address: $DBUS_SESSION_BUS_ADDRESS"

# If no session bus is running, we can try to start one temporarily
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    echo "No session bus found, trying to find system bus or start a temporary one..."
    
    # Check if there's a system bus we can use for testing
    if [ -S /var/run/dbus/system_bus_socket ]; then
        echo "Found system bus at /var/run/dbus/system_bus_socket"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/var/run/dbus/system_bus_socket"
    else
        echo "Starting temporary session bus..."
        # Start a temporary session bus
        dbus-daemon --session --fork --print-address > /tmp/test-dbus-address 2>/dev/null
        if [ $? -eq 0 ]; then
            export DBUS_SESSION_BUS_ADDRESS=$(cat /tmp/test-dbus-address)
            echo "Started temporary session bus: $DBUS_SESSION_BUS_ADDRESS"
        else
            echo "Could not start temporary session bus, will try direct socket test"
        fi
    fi
fi

if [ -n "$DBUS_SESSION_BUS_ADDRESS" ]; then
    echo "Testing dbus-send against real daemon..."
    timeout 5 dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.Hello
    
    echo ""
    echo "Testing our custom client against real daemon..."
    
    # Extract socket path from DBUS_SESSION_BUS_ADDRESS
    SOCKET_PATH=$(echo "$DBUS_SESSION_BUS_ADDRESS" | sed 's/unix:path=//')
    echo "Using socket: $SOCKET_PATH"
    
    # Create a test client to connect to the real daemon
    cat > test_real_daemon.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <errno.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        printf("Usage: %s <socket_path>\n", argv[0]);
        return 1;
    }
    
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
    strcpy(addr.sun_path, argv[1]);
    
    if (connect(sockfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("connect");
        return 1;
    }
    
    printf("Connected to real D-Bus daemon at %s\n", argv[1]);
    
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
    
    // Send NEGOTIATE_UNIX_FD
    const char *negotiate = "NEGOTIATE_UNIX_FD\r\n";
    send(sockfd, negotiate, strlen(negotiate), 0);
    
    // Read response (could be OK or ERROR)
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
            
            // Try to parse the reply to see if it's a valid unique name
            if (n > 16) {
                // Check if this is a METHOD_RETURN message (type 2)
                if ((unsigned char)buffer[1] == 0x02) {
                    printf("SUCCESS: Received METHOD_RETURN message from real daemon!\n");
                    
                    // Keep connection alive and try to send another message
                    printf("Trying to send ListNames method...\n");
                    
                    // ListNames message (simplified)
                    unsigned char listnames_msg[] = {
                        0x6c, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x6e, 0x00, 0x00, 0x00,
                        0x01, 0x01, 0x6f, 0x00, 0x15, 0x00, 0x00, 0x00, 0x2f, 0x6f, 0x72, 0x67, 0x2f, 0x66, 0x72, 0x65,
                        0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2f, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00,
                        0x06, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
                        0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
                        0x02, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
                        0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
                        0x03, 0x01, 0x73, 0x00, 0x09, 0x00, 0x00, 0x00, 0x4c, 0x69, 0x73, 0x74, 0x4e, 0x61, 0x6d, 0x65, 0x73, 0x00, 0x00, 0x00
                    };
                    
                    send(sockfd, listnames_msg, sizeof(listnames_msg), 0);
                    printf("Sent ListNames message\n");
                    
                    // Wait for another reply
                    ready = select(sockfd + 1, &readfds, NULL, NULL, &timeout);
                    if (ready > 0) {
                        n = recv(sockfd, buffer, sizeof(buffer), 0);
                        if (n > 0) {
                            printf("Received ListNames reply: %d bytes\n", n);
                        }
                    }
                }
            }
        } else if (n == 0) {
            printf("Connection closed by real daemon\n");
        } else {
            perror("recv");
        }
    } else if (ready == 0) {
        printf("Timeout waiting for reply from real daemon\n");
    } else {
        perror("select");
    }
    
    close(sockfd);
    return 0;
}
EOF

    # Compile and run test client
    clang19 -o test_real_daemon test_real_daemon.c
    ./test_real_daemon "$SOCKET_PATH"
    
    # Clean up
    rm -f test_real_daemon test_real_daemon.c
    
    # If we started a temporary daemon, kill it
    if [ -f /tmp/test-dbus-address ]; then
        pkill -f "dbus-daemon.*$(cat /tmp/test-dbus-address)"
        rm -f /tmp/test-dbus-address
    fi
else
    echo "No D-Bus daemon available for testing"
fi

echo "=== Test complete ==="

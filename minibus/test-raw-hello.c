#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

void hexdump(const unsigned char *data, size_t len) {
    for (size_t i = 0; i < len; i++) {
        printf("%02x ", data[i]);
        if ((i + 1) % 16 == 0) printf("\n");
    }
    if (len % 16 != 0) printf("\n");
}

int main() {
    int sock;
    struct sockaddr_un addr;
    char buffer[1024];
    ssize_t bytes;
    
    // Create socket
    sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock == -1) {
        perror("socket");
        return 1;
    }
    
    // Connect to MiniBus
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, "/tmp/minibus-socket");
    
    if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) == -1) {
        perror("connect");
        close(sock);
        return 1;
    }
    
    printf("Connected to MiniBus socket\n");
    
    // Send auth sequence
    const char *auth_external = "AUTH EXTERNAL 31303031\r\n";
    send(sock, auth_external, strlen(auth_external), 0);
    
    bytes = recv(sock, buffer, sizeof(buffer), 0);
    printf("Auth response (%zd bytes): ", bytes);
    hexdump((unsigned char*)buffer, bytes);
    printf("Auth response text: %.*s\n", (int)bytes, buffer);
    
    // Send negotiate unix fd
    const char *negotiate = "NEGOTIATE_UNIX_FD\r\n";
    send(sock, negotiate, strlen(negotiate), 0);
    
    bytes = recv(sock, buffer, sizeof(buffer), 0);
    printf("Negotiate response (%zd bytes): ", bytes);
    hexdump((unsigned char*)buffer, bytes);
    printf("Negotiate response text: %.*s\n", (int)bytes, buffer);
    
    // Send begin
    const char *begin = "BEGIN\r\n";
    send(sock, begin, strlen(begin), 0);
    
    printf("Authentication completed, sending Hello message\n");
    
    // Send Hello message (D-Bus format)
    // This is a method call to org.freedesktop.DBus.Hello
    unsigned char hello_msg[] = {
        0x6c, 0x01, 0x00, 0x01,  // Endianness, type, flags, version
        0x00, 0x00, 0x00, 0x00,  // Body length (0)
        0x01, 0x00, 0x00, 0x00,  // Serial number (1)
        0x6e, 0x00, 0x00, 0x00,  // Header fields array length
        // Header fields...
        0x01, 0x01, 0x6f, 0x00, 0x15, 0x00, 0x00, 0x00, 0x2f, 0x6f, 0x72, 0x67, 0x2f, 0x66, 0x72, 0x65,
        0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2f, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00,
        0x02, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
        0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
        0x03, 0x01, 0x73, 0x00, 0x05, 0x00, 0x00, 0x00, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x00, 0x00,
        0x06, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00, 0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
        0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00
    };
    
    send(sock, hello_msg, sizeof(hello_msg), 0);
    
    printf("Hello message sent, waiting for reply...\n");
    
    // Receive Hello reply
    bytes = recv(sock, buffer, sizeof(buffer), 0);
    printf("Hello reply (%zd bytes):\n", bytes);
    hexdump((unsigned char*)buffer, bytes);
    
    // Try to parse the reply
    if (bytes >= 16) {
        unsigned char endian = buffer[0];
        unsigned char type = buffer[1];
        uint32_t body_len = *(uint32_t*)(buffer + 4);
        uint32_t serial = *(uint32_t*)(buffer + 8);
        uint32_t fields_len = *(uint32_t*)(buffer + 12);
        
        printf("Message: endian=%c type=%d body_len=%u serial=%u fields_len=%u\n",
               endian, type, body_len, serial, fields_len);
               
        // Look for the body (unique name string)
        size_t body_start = 16 + fields_len;
        // Align to 8-byte boundary
        body_start = (body_start + 7) & ~7;
        
        if (body_start + 4 < bytes) {
            uint32_t str_len = *(uint32_t*)(buffer + body_start);
            printf("String length in body: %u\n", str_len);
            
            if (body_start + 4 + str_len < bytes) {
                printf("Unique name: '%.*s'\n", str_len, buffer + body_start + 4);
            }
        }
    }
    
    close(sock);
    printf("Test completed\n");
    return 0;
}

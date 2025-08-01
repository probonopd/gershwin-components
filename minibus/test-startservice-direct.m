#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/un.h>

int main() {
    @autoreleasepool {
        // Create socket
        int sock = socket(AF_UNIX, SOCK_STREAM, 0);
        if (sock < 0) {
            perror("socket");
            return 1;
        }
        
        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strcpy(addr.sun_path, "/tmp/minibus-socket");
        
        if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
            perror("connect");
            close(sock);
            return 1;
        }
        
        // Send AUTH
        char auth_cmd[] = "AUTH EXTERNAL\r\n";
        send(sock, auth_cmd, strlen(auth_cmd), 0);
        
        char response[1000];
        ssize_t n = recv(sock, response, sizeof(response)-1, 0);
        response[n] = '\0';
        printf("Auth response: %s", response);
        
        // Send BEGIN
        char begin_cmd[] = "BEGIN\r\n";
        send(sock, begin_cmd, strlen(begin_cmd), 0);
        
        // Send Hello message
        unsigned char hello_msg[] = {
            'l',  // little endian
            1,    // MESSAGE_TYPE_METHOD_CALL
            0,    // no flags
            1,    // major protocol version
            0x00, 0x00, 0x00, 0x00, // body length (0)
            0x00, 0x00, 0x00, 0x01, // serial = 1
            
            // Header fields array length (will be calculated)
            0x00, 0x00, 0x00, 0x40, // 64 bytes of header fields
            
            // FIELD_PATH = 1
            0x01, 0x01, 0x6F, 0x00, // field code 1, signature "o", padding
            0x00, 0x00, 0x00, 0x15, // string length 21
            '/', 'o', 'r', 'g', '/', 'f', 'r', 'e', 'e', 'd', 'e', 's', 'k', 't', 'o', 'p', '/', 'D', 'B', 'u', 's', 0x00, 0x00, 0x00, // path + padding
            
            // FIELD_MEMBER = 3
            0x03, 0x01, 0x73, 0x00, // field code 3, signature "s", padding  
            0x00, 0x00, 0x00, 0x05, // string length 5
            'H', 'e', 'l', 'l', 'o', 0x00, 0x00, 0x00 // "Hello" + padding
        };
        
        send(sock, hello_msg, sizeof(hello_msg), 0);
        
        // Receive Hello reply
        n = recv(sock, response, sizeof(response), 0);
        printf("Hello reply received: %zd bytes\n", n);
        
        // Now send StartServiceByName message
        unsigned char start_service_msg[] = {
            'l',  // little endian
            1,    // MESSAGE_TYPE_METHOD_CALL
            0,    // no flags
            1,    // major protocol version
            
            // Body length: string "org.xfce.Xfconf" (16 chars + 4 length + alignment) + uint32 (4 bytes) = 24 bytes
            0x18, 0x00, 0x00, 0x00, // body length = 24
            0x00, 0x00, 0x00, 0x02, // serial = 2
            
            // Header fields array length
            0x00, 0x00, 0x00, 0x60, // header fields length = 96 bytes
            
            // FIELD_PATH = 1
            0x01, 0x01, 0x6F, 0x00, // field code 1, signature "o", padding
            0x00, 0x00, 0x00, 0x15, // string length 21
            '/', 'o', 'r', 'g', '/', 'f', 'r', 'e', 'e', 'd', 'e', 's', 'k', 't', 'o', 'p', '/', 'D', 'B', 'u', 's', 0x00, 0x00, 0x00, // path + padding
            
            // FIELD_MEMBER = 3  
            0x03, 0x01, 0x73, 0x00, // field code 3, signature "s", padding
            0x00, 0x00, 0x00, 0x10, // string length 16
            'S', 't', 'a', 'r', 't', 'S', 'e', 'r', 'v', 'i', 'c', 'e', 'B', 'y', 'N', 'a', 'm', 'e', 0x00, 0x00, // "StartServiceByName" + padding
            
            // FIELD_SIGNATURE = 8
            0x08, 0x01, 0x67, 0x00, // field code 8, signature "g", padding
            0x02, 's', 'u', 0x00,   // signature "su" (string + uint32)
            
            // Body data: string "org.xfce.Xfconf" + uint32 flags
            0x00, 0x00, 0x00, 0x0F, // string length 15
            'o', 'r', 'g', '.', 'x', 'f', 'c', 'e', '.', 'X', 'f', 'c', 'o', 'n', 'f', 0x00, // "org.xfce.Xfconf" + null terminator
            0x00, 0x00, 0x00, 0x00  // uint32 flags = 0
        };
        
        printf("Sending StartServiceByName message (%zu bytes):\n", sizeof(start_service_msg));
        for (int i = 0; i < sizeof(start_service_msg); i++) {
            printf("%02x ", start_service_msg[i]);
            if ((i + 1) % 16 == 0) printf("\n");
        }
        printf("\n");
        
        send(sock, start_service_msg, sizeof(start_service_msg), 0);
        
        // Wait for reply
        sleep(1);
        n = recv(sock, response, sizeof(response), 0);
        printf("StartServiceByName reply received: %zd bytes\n", n);
        
        close(sock);
    }
    return 0;
}

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <dbus/dbus.h>

void print_hex_dump(const char *data, int len, const char *label) {
    printf("\n=== %s ===\n", label);
    printf("Length: %d bytes\n", len);
    
    for (int i = 0; i < len; i += 16) {
        printf("%04x: ", i);
        
        // Hex bytes
        for (int j = 0; j < 16; j++) {
            if (i + j < len) {
                printf("%02x ", (unsigned char)data[i + j]);
            } else {
                printf("   ");
            }
            if (j == 7) printf(" ");
        }
        
        printf(" |");
        
        // ASCII representation
        for (int j = 0; j < 16 && i + j < len; j++) {
            unsigned char b = data[i + j];
            printf("%c", (b >= 32 && b < 127) ? b : '.');
        }
        
        printf("|\n");
    }
    printf("\n");
}

int main() {
    DBusMessage *msg;
    char *marshalled_data;
    int marshalled_len;
    
    // Create a method call message identical to our test
    msg = dbus_message_new_method_call("org.freedesktop.DBus", 
                                       "/org/freedesktop/DBus",
                                       "org.freedesktop.DBus", 
                                       "ListNames");
    
    if (!msg) {
        fprintf(stderr, "Failed to create message\n");
        return 1;
    }
    
    // Set serial number to 1 for consistency
    dbus_message_set_serial(msg, 1);
    
    // Marshall the message to get raw bytes
    if (!dbus_message_marshal(msg, &marshalled_data, &marshalled_len)) {
        fprintf(stderr, "Failed to marshal message\n");
        dbus_message_unref(msg);
        return 1;
    }
    
    printf("LibDBus ListNames Message Format\n");
    print_hex_dump(marshalled_data, marshalled_len, "LibDBus ListNames Message");
    
    // Print header analysis
    printf("Header Analysis:\n");
    printf("Endian: 0x%02x ('%c')\n", (unsigned char)marshalled_data[0], marshalled_data[0]);
    printf("Type: %d\n", (unsigned char)marshalled_data[1]);
    printf("Flags: %d\n", (unsigned char)marshalled_data[2]);
    printf("Version: %d\n", (unsigned char)marshalled_data[3]);
    
    uint32_t bodyLength = *(uint32_t*)(marshalled_data + 4);
    uint32_t serial = *(uint32_t*)(marshalled_data + 8);
    uint32_t fieldsLength = *(uint32_t*)(marshalled_data + 12);
    
    printf("Body Length: %u\n", bodyLength);
    printf("Serial: %u\n", serial);
    printf("Fields Length: %u\n", fieldsLength);
    
    if (fieldsLength > 0 && marshalled_len >= 16 + fieldsLength) {
        print_hex_dump(marshalled_data + 16, fieldsLength, "Header Fields Only");
    }
    
    // Cleanup
    dbus_free(marshalled_data);
    dbus_message_unref(msg);
    
    return 0;
}

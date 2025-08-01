#import <Foundation/Foundation.h>
#import <glib.h>
#import <gio/gio.h>
#import "MBClient.h"

static void mb_hexdump(NSData *data, NSString *prefix) {
    const uint8_t *bytes = [data bytes];
    NSUInteger length = [data length];
    
    printf("%s (%lu bytes):\n", [prefix UTF8String], length);
    for (NSUInteger i = 0; i < length; i += 16) {
        printf("%04lx: ", i);
        
        // Print hex bytes
        for (NSUInteger j = 0; j < 16; j++) {
            if (i + j < length) {
                printf("%02x ", bytes[i + j]);
            } else {
                printf("   ");
            }
        }
        
        printf(" ");
        
        // Print ASCII
        for (NSUInteger j = 0; j < 16 && i + j < length; j++) {
            uint8_t byte = bytes[i + j];
            printf("%c", (byte >= 32 && byte < 127) ? byte : '.');
        }
        
        printf("\n");
    }
    printf("\n");
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"Starting D-Bus message parsing debug tool");
        
        // Connect to D-Bus using GDBus
        GError *error = NULL;
        GDBusConnection *connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
        if (!connection) {
            NSLog(@"Failed to connect to session bus: %s", error->message);
            g_error_free(error);
            return 1;
        }
        
        NSLog(@"Connected to D-Bus session bus");
        
        // Try calling StartServiceByName with debugging
        NSLog(@"Calling StartServiceByName for 'org.xfce.Session.Manager'...");
        
        GVariant *result = g_dbus_connection_call_sync(
            connection,
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus", 
            "org.freedesktop.DBus",
            "StartServiceByName",
            g_variant_new("(su)", "org.xfce.Session.Manager", 0),
            G_VARIANT_TYPE("(u)"),
            G_DBUS_CALL_FLAGS_NONE,
            -1,
            NULL,
            &error
        );
        
        if (result) {
            guint32 reply_code;
            g_variant_get(result, "(u)", &reply_code);
            NSLog(@"StartServiceByName returned: %u", reply_code);
            g_variant_unref(result);
        } else {
            NSLog(@"StartServiceByName failed: %s", error ? error->message : "Unknown error");
            if (error) g_error_free(error);
        }
        
        // Try creating a proxy for org.freedesktop.DBus (should work)
        NSLog(@"Creating proxy for org.freedesktop.DBus...");
        
        GDBusProxy *bus_proxy = g_dbus_proxy_new_sync(
            connection,
            G_DBUS_PROXY_FLAGS_NONE,
            NULL,
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            NULL,
            &error
        );
        
        if (bus_proxy) {
            NSLog(@"Successfully created proxy for org.freedesktop.DBus");
            
            // Test ListNames
            GVariant *names_result = g_dbus_proxy_call_sync(
                bus_proxy,
                "ListNames",
                NULL,
                G_DBUS_CALL_FLAGS_NONE,
                -1,
                NULL,
                &error
            );
            
            if (names_result) {
                NSLog(@"ListNames succeeded");
                g_variant_unref(names_result);
            } else {
                NSLog(@"ListNames failed: %s", error ? error->message : "Unknown error");
                if (error) g_error_free(error);
            }
            
            g_object_unref(bus_proxy);
        } else {
            NSLog(@"Failed to create proxy for org.freedesktop.DBus: %s", error ? error->message : "Unknown error");
            if (error) g_error_free(error);
        }
        
        // Now try a non-existent service
        NSLog(@"Creating proxy for org.xfce.Session.Manager...");
        
        GDBusProxy *session_proxy = g_dbus_proxy_new_sync(
            connection,
            G_DBUS_PROXY_FLAGS_NONE,
            NULL,
            "org.xfce.Session.Manager",
            "/org/xfce/Session/Manager",
            "org.xfce.Session.Manager",
            NULL,
            &error
        );
        
        if (session_proxy) {
            NSLog(@"Successfully created proxy for org.xfce.Session.Manager");
            g_object_unref(session_proxy);
        } else {
            NSLog(@"Failed to create proxy for org.xfce.Session.Manager: %s", error ? error->message : "Unknown error");
            if (error) {
                NSLog(@"Error domain: %s, code: %d", g_quark_to_string(error->domain), error->code);
                g_error_free(error);
            }
        }
        
        g_object_unref(connection);
    }
    
    return 0;
}

#import <Foundation/Foundation.h>
#import <glib.h>
#import <gio/gio.h>

static void test_start_service_by_name(void)
{
    GError *error = NULL;
    
    // Set up the session bus address to point to our MiniBus daemon
    g_setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/tmp/dbus-socket", TRUE);
    
    g_print("Testing StartServiceByName with MiniBus...\n");
    
    // Get the session bus connection
    GDBusConnection *connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!connection) {
        g_critical("Failed to get session bus connection: %s", 
                   error ? error->message : "unknown error");
        if (error) g_error_free(error);
        return;
    }
    
    g_print("Successfully connected to D-Bus session bus\n");
    
    // Test calling StartServiceByName directly for org.freedesktop.DBus
    g_print("Testing StartServiceByName for org.freedesktop.DBus...\n");
    GVariant *result = g_dbus_connection_call_sync(
        connection,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "StartServiceByName",
        g_variant_new("(su)", "org.freedesktop.DBus", 0),
        G_VARIANT_TYPE("(u)"),
        G_DBUS_CALL_FLAGS_NONE,
        5000, // 5 second timeout
        NULL,
        &error
    );
    
    if (!result) {
        g_critical("StartServiceByName failed: %s", 
                   error ? error->message : "unknown error");
        if (error) {
            g_print("Error domain: %s, code: %d\n", 
                     g_quark_to_string(error->domain), error->code);
            g_error_free(error);
            error = NULL;
        }
    } else {
        guint32 start_result;
        g_variant_get(result, "(u)", &start_result);
        g_print("StartServiceByName succeeded with result: %u\n", start_result);
        g_variant_unref(result);
    }
    
    // Test calling StartServiceByName for a non-existent service
    g_print("Testing StartServiceByName for org.example.NonExistent...\n");
    result = g_dbus_connection_call_sync(
        connection,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "StartServiceByName",
        g_variant_new("(su)", "org.example.NonExistent", 0),
        G_VARIANT_TYPE("(u)"),
        G_DBUS_CALL_FLAGS_NONE,
        5000, // 5 second timeout
        NULL,
        &error
    );
    
    if (!result) {
        g_print("StartServiceByName failed as expected: %s\n", 
                 error ? error->message : "unknown error");
        if (error) {
            g_print("Error domain: %s, code: %d\n", 
                     g_quark_to_string(error->domain), error->code);
            g_error_free(error);
            error = NULL;
        }
    } else {
        guint32 start_result;
        g_variant_get(result, "(u)", &start_result);
        g_print("StartServiceByName unexpectedly succeeded with result: %u\n", start_result);
        g_variant_unref(result);
    }
    
    g_object_unref(connection);
    g_print("Test completed\n");
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        NSLog(@"Starting StartServiceByName test with MiniBus");
        
        test_start_service_by_name();
        
        NSLog(@"StartServiceByName test completed");
    }
    
    return 0;
}

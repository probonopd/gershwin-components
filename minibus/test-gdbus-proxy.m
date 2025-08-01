#import <Foundation/Foundation.h>
#import <glib.h>
#import <gio/gio.h>

static void test_gdbus_proxy_creation(void)
{
    GError *error = NULL;
    
    // Set up the session bus address to point to our MiniBus daemon
    g_setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/tmp/dbus-socket", TRUE);
    
    g_print("Testing GDBus proxy creation with MiniBus...\n");
    
    // Get the session bus connection
    GDBusConnection *connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!connection) {
        g_critical("Failed to get session bus connection: %s", 
                   error ? error->message : "unknown error");
        if (error) g_error_free(error);
        return;
    }
    
    g_print("Successfully connected to D-Bus session bus\n");
    
    // Test creating a proxy for a non-existent service (this should be the common case)
    g_print("Creating proxy for org.xfce.Session.Manager...\n");
    GDBusProxy *proxy = g_dbus_proxy_new_sync(
        connection,
        G_DBUS_PROXY_FLAGS_NONE,
        NULL, // info
        "org.xfce.Session.Manager",
        "/org/xfce/Session/Manager",
        "org.xfce.Session.Manager",
        NULL, // cancellable
        &error
    );
    
    if (!proxy) {
        g_critical("Failed to create proxy for org.xfce.Session.Manager: %s", 
                   error ? error->message : "unknown error");
        if (error) {
            g_print("Error domain: %s, code: %d\n", 
                     g_quark_to_string(error->domain), error->code);
            g_error_free(error);
            error = NULL;
        }
    } else {
        g_print("Successfully created proxy for org.xfce.Session.Manager\n");
        
        // Test calling a method on the proxy (this should fail gracefully)
        g_print("Testing method call on proxy...\n");
        GVariant *result = g_dbus_proxy_call_sync(
            proxy,
            "ListClients",
            NULL, // parameters
            G_DBUS_CALL_FLAGS_NONE,
            -1, // timeout
            NULL, // cancellable  
            &error
        );
        
        if (!result) {
            g_print("Method call failed as expected: %s\n", 
                     error ? error->message : "unknown error");
            if (error) g_error_free(error);
            error = NULL;
        } else {
            g_print("Method call unexpectedly succeeded\n");
            g_variant_unref(result);
        }
        
        g_object_unref(proxy);
    }
    
    // Test creating proxy for the D-Bus daemon itself
    g_print("Creating proxy for org.freedesktop.DBus...\n");
    GDBusProxy *bus_proxy = g_dbus_proxy_new_sync(
        connection,
        G_DBUS_PROXY_FLAGS_NONE,
        NULL, // info
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        NULL, // cancellable
        &error
    );
    
    if (!bus_proxy) {
        g_critical("Failed to create proxy for org.freedesktop.DBus: %s", 
                   error ? error->message : "unknown error");
        if (error) {
            g_print("Error domain: %s, code: %d\n", 
                     g_quark_to_string(error->domain), error->code);
            g_error_free(error);
            error = NULL;
        }
    } else {
        g_print("Successfully created proxy for org.freedesktop.DBus\n");
        
        // Test calling ListNames
        g_print("Testing ListNames call...\n");
        GVariant *result = g_dbus_proxy_call_sync(
            bus_proxy,
            "ListNames",
            NULL, // parameters
            G_DBUS_CALL_FLAGS_NONE,
            -1, // timeout
            NULL, // cancellable  
            &error
        );
        
        if (!result) {
            g_critical("ListNames call failed: %s\n", 
                       error ? error->message : "unknown error");
            if (error) g_error_free(error);
        } else {
            g_print("ListNames call succeeded\n");
            gchar *result_str = g_variant_print(result, TRUE);
            g_print("Result: %s\n", result_str);
            g_free(result_str);
            g_variant_unref(result);
        }
        
        g_object_unref(bus_proxy);
    }
    
    g_object_unref(connection);
    g_print("Test completed\n");
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        NSLog(@"Starting GDBus proxy test with MiniBus");
        
        test_gdbus_proxy_creation();
        
        NSLog(@"GDBus proxy test completed");
    }
    
    return 0;
}

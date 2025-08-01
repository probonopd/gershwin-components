#include <gio/gio.h>
#include <stdio.h>

int main(int argc, char *argv[]) {
    GError *error = NULL;
    
    // Set the D-Bus address to our MiniBus socket
    g_setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/tmp/minibus-socket", TRUE);
    
    printf("Attempting to connect to MiniBus at /tmp/minibus-socket...\n");
    
    // Get the session bus connection
    GDBusConnection *connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    if (!connection) {
        printf("Failed to get session bus: %s\n", error ? error->message : "Unknown error");
        if (error) g_error_free(error);
        return 1;
    }
    
    printf("Connected to D-Bus successfully!\n");
    
    // Test basic introspection
    printf("Testing introspection on org.freedesktop.DBus...\n");
    
    GVariant *result = g_dbus_connection_call_sync(
        connection,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus.Introspectable",
        "Introspect",
        NULL,
        G_VARIANT_TYPE("(s)"),
        G_DBUS_CALL_FLAGS_NONE,
        5000, // 5 second timeout
        NULL,
        &error
    );
    
    if (result) {
        gchar *introspection_xml;
        g_variant_get(result, "(s)", &introspection_xml);
        printf("Introspection successful! XML length: %lu\n", strlen(introspection_xml));
        g_free(introspection_xml);
        g_variant_unref(result);
    } else {
        printf("Introspection failed: %s\n", error ? error->message : "Unknown error");
        if (error) g_error_free(error);
    }
    
    // Test ListNames
    printf("Testing ListNames...\n");
    result = g_dbus_connection_call_sync(
        connection,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "ListNames",
        NULL,
        G_VARIANT_TYPE("(as)"),
        G_DBUS_CALL_FLAGS_NONE,
        5000,
        NULL,
        &error
    );
    
    if (result) {
        GVariantIter *iter;
        gchar *name;
        g_variant_get(result, "(as)", &iter);
        
        printf("Available names:\n");
        while (g_variant_iter_loop(iter, "s", &name)) {
            printf("  %s\n", name);
        }
        
        g_variant_iter_free(iter);
        g_variant_unref(result);
    } else {
        printf("ListNames failed: %s\n", error ? error->message : "Unknown error");
        if (error) g_error_free(error);
    }
    
    // Try to create a proxy for org.xfce.Xfconf
    printf("Testing proxy creation for org.xfce.Xfconf...\n");
    GDBusProxy *proxy = g_dbus_proxy_new_sync(
        connection,
        G_DBUS_PROXY_FLAGS_NONE,
        NULL,
        "org.xfce.Xfconf",
        "/org/xfce/Xfconf",
        "org.xfce.Xfconf",
        NULL,
        &error
    );
    
    if (proxy) {
        printf("Proxy created successfully!\n");
        g_object_unref(proxy);
    } else {
        printf("Proxy creation failed: %s\n", error ? error->message : "Unknown error");
        if (error) g_error_free(error);
    }
    
    g_object_unref(connection);
    printf("Test completed.\n");
    return 0;
}

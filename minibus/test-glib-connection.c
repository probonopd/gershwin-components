#include <gio/gio.h>
#include <glib.h>
#include <stdio.h>

int main(int argc, char *argv[])
{
    GError *error = NULL;
    GDBusConnection *connection = NULL;
    
    /* Try to connect to MiniBus using environment variable like xfce4-panel does */
    printf("DBUS_SESSION_BUS_ADDRESS: %s\n", g_getenv("DBUS_SESSION_BUS_ADDRESS"));
    
    if (!g_getenv("DBUS_SESSION_BUS_ADDRESS")) {
        g_setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/tmp/minibus-socket", TRUE);
        printf("Set DBUS_SESSION_BUS_ADDRESS to unix:path=/tmp/minibus-socket\n");
    }
    
    /* Try to connect using the session bus method (like xfce4-panel) */
    printf("Attempting to get session bus connection...\n");
    
    connection = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
    
    if (error) {
        printf("Error getting session bus: %s\n", error->message);
        g_error_free(error);
        error = NULL;
        
        /* Fallback: try direct connection */
        printf("Fallback: trying direct connection to MiniBus\n");
        connection = g_dbus_connection_new_for_address_sync(
            "unix:path=/tmp/minibus-socket",
            G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
            NULL,  /* observer */
            NULL,  /* cancellable */
            &error
        );
    }
    
    if (error) {
        printf("Error connecting to MiniBus: %s\n", error->message);
        g_error_free(error);
        return 1;
    }
    
    if (!connection) {
        printf("Failed to create connection (no error reported)\n");
        return 1;
    }
    
    printf("Successfully connected to MiniBus!\n");
    printf("Connection unique name: %s\n", g_dbus_connection_get_unique_name(connection));
    printf("Connection is closed: %s\n", g_dbus_connection_is_closed(connection) ? "YES" : "NO");
    
    /* Test creating a proxy like xfce4-panel does */
    GDBusProxy *proxy = g_dbus_proxy_new_sync(
        connection,
        G_DBUS_PROXY_FLAGS_NONE,
        NULL,  /* info */
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        NULL,  /* cancellable */
        &error
    );
    
    if (error) {
        printf("Error creating proxy: %s\n", error->message);
        g_error_free(error);
    } else if (proxy) {
        printf("Successfully created D-Bus proxy!\n");
        
        /* Test a simple method call */
        GVariant *result = g_dbus_proxy_call_sync(
            proxy,
            "ListNames",
            NULL,  /* parameters */
            G_DBUS_CALL_FLAGS_NONE,
            -1,    /* timeout */
            NULL,  /* cancellable */
            &error
        );
        
        if (error) {
            printf("Error calling ListNames: %s\n", error->message);
            g_error_free(error);
        } else if (result) {
            printf("ListNames call succeeded!\n");
            g_variant_unref(result);
        }
        
        g_object_unref(proxy);
    }
    
    g_object_unref(connection);
    printf("Test completed.\n");
    
    return 0;
}

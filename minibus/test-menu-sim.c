/*
 * test-menu-sim.c - libdbus test client mimicking Menu.app's bus usage.
 *
 * Role "registrar" (what Menu.app does):
 *   - dbus_bus_get(SESSION), Hello (implicit), request name
 *     com.canonical.AppMenu.Registrar with REPLACE_EXISTING|ALLOW_REPLACEMENT
 *   - AddMatch for org.freedesktop.DBus NameOwnerChanged
 *   - serve method calls on /com/canonical/AppMenu/Registrar
 *     (RegisterWindow, UnregisterWindow, GetMenuForWindow, Introspect)
 *   - emit WindowRegistered signal after RegisterWindow
 *
 * Role "client" (what a GTK appmenu exporter does):
 *   - connect, AddMatch for WindowRegistered signal from the registrar
 *   - call RegisterWindow on the registrar (send_with_reply_and_block)
 *   - call GetMenuForWindow and print the reply
 *
 * Usage: test-menu-sim registrar|client <bus-address>
 */

#include <dbus/dbus.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static DBusConnection *conn;

static void die(const char *msg, DBusError *err)
{
    if (err && dbus_error_is_set(err))
        fprintf(stderr, "FAIL: %s: %s\n", msg, err->message);
    else
        fprintf(stderr, "FAIL: %s\n", msg);
    exit(1);
}

static void add_match(const char *rule)
{
    DBusError err;
    dbus_error_init(&err);
    dbus_bus_add_match(conn, rule, &err);
    if (dbus_error_is_set(&err))
        die("AddMatch failed", &err);
    dbus_connection_flush(conn);
    printf("MATCH: %s\n", rule);
}

static void send_signal_window_registered(unsigned window_id)
{
    DBusMessage *sig;
    dbus_uint32_t wid = window_id;
    const char *service = ":1.99.test";
    const char *path = "/org/appmenu/test";

    sig = dbus_message_new_signal("/com/canonical/AppMenu/Registrar",
                                  "com.canonical.AppMenu.Registrar",
                                  "WindowRegistered");
    if (!sig)
        die("new_signal", NULL);
    dbus_message_append_args(sig, DBUS_TYPE_UINT32, &wid,
                             DBUS_TYPE_STRING, &service,
                             DBUS_TYPE_OBJECT_PATH, &path,
                             DBUS_TYPE_INVALID);
    if (!dbus_connection_send(conn, sig, NULL))
        die("send signal", NULL);
    dbus_connection_flush(conn);
    dbus_message_unref(sig);
    printf("SIGNAL: WindowRegistered sent\n");
}

static void serve_registrar(long run_ms)
{
    long elapsed = 0;

    while (elapsed < run_ms) {
        dbus_connection_read_write(conn, 100);
        while (1) {
            DBusMessage *msg = dbus_connection_pop_message(conn);
            if (!msg)
                break;

            int type = dbus_message_get_type(msg);
            if (type == DBUS_MESSAGE_TYPE_METHOD_CALL) {
                const char *iface = dbus_message_get_interface(msg);
                const char *member = dbus_message_get_member(msg);
                printf("CALL: %s.%s path=%s\n",
                       iface ? iface : "(nil)",
                       member ? member : "(nil)",
                       dbus_message_get_path(msg));

                if (iface && strcmp(iface, "org.freedesktop.DBus.Introspectable") == 0 &&
                    member && strcmp(member, "Introspect") == 0) {
                    DBusMessage *reply = dbus_message_new_method_return(msg);
                    const char *xml =
                        "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\" "
                        "\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">\n"
                        "<node>\n"
                        "  <interface name=\"com.canonical.AppMenu.Registrar\">\n"
                        "    <method name=\"RegisterWindow\">\n"
                        "      <arg name=\"windowId\" type=\"u\" direction=\"in\"/>\n"
                        "      <arg name=\"menuObjectPath\" type=\"o\" direction=\"in\"/>\n"
                        "    </method>\n"
                        "    <method name=\"GetMenuForWindow\">\n"
                        "      <arg name=\"windowId\" type=\"u\" direction=\"in\"/>\n"
                        "      <arg name=\"service\" type=\"s\" direction=\"out\"/>\n"
                        "      <arg name=\"menuObjectPath\" type=\"o\" direction=\"out\"/>\n"
                        "    </method>\n"
                        "  </interface>\n"
                        "</node>";
                    dbus_message_append_args(reply, DBUS_TYPE_STRING, &xml,
                                             DBUS_TYPE_INVALID);
                    dbus_connection_send(conn, reply, NULL);
                    dbus_message_unref(reply);
                    printf("REPLY: Introspect xml\n");
                } else if (iface && strcmp(iface, "com.canonical.AppMenu.Registrar") == 0) {
                    DBusMessage *reply = dbus_message_new_method_return(msg);
                    if (member && strcmp(member, "RegisterWindow") == 0) {
                        dbus_uint32_t wid = 0;
                        const char *menu_path = NULL;
                        dbus_message_get_args(msg, NULL,
                                              DBUS_TYPE_UINT32, &wid,
                                              DBUS_TYPE_OBJECT_PATH, &menu_path,
                                              DBUS_TYPE_INVALID);
                        printf("CALL: RegisterWindow(%u, %s)\n", wid,
                               menu_path ? menu_path : "(nil)");
                        /* Menu.app emits WindowRegistered after RegisterWindow */
                        send_signal_window_registered(wid);
                        dbus_message_append_args(reply, DBUS_TYPE_INVALID);
                    } else if (member && strcmp(member, "GetMenuForWindow") == 0) {
                        const char *service = ":1.99.test";
                        const char *menu_path = "/org/appmenu/test";
                        dbus_message_append_args(reply,
                                                 DBUS_TYPE_STRING, &service,
                                                 DBUS_TYPE_OBJECT_PATH, &menu_path,
                                                 DBUS_TYPE_INVALID);
                        printf("REPLY: GetMenuForWindow -> %s %s\n", service, menu_path);
                    } else if (member && strcmp(member, "UnregisterWindow") == 0) {
                        dbus_message_append_args(reply, DBUS_TYPE_INVALID);
                    } else {
                        DBusMessage *err = dbus_message_new_error_printf(
                            msg, "org.freedesktop.DBus.Error.UnknownMethod",
                            "No such method %s", member ? member : "?");
                        dbus_connection_send(conn, err, NULL);
                        dbus_message_unref(err);
                        dbus_message_unref(reply);
                        dbus_message_unref(msg);
                        continue;
                    }
                    dbus_connection_send(conn, reply, NULL);
                    dbus_message_unref(reply);
                } else if (iface && strcmp(iface, "org.freedesktop.DBus.Peer") == 0) {
                    if (member && strcmp(member, "Ping") == 0) {
                        DBusMessage *reply = dbus_message_new_method_return(msg);
                        dbus_connection_send(conn, reply, NULL);
                        dbus_message_unref(reply);
                    } else if (member && strcmp(member, "GetMachineId") == 0) {
                        DBusMessage *reply = dbus_message_new_method_return(msg);
                        char id[33];
                        for (int i = 0; i < 32; i++)
                            id[i] = '0' + (i % 10);
                        id[32] = 0;
                        dbus_message_append_args(reply, DBUS_TYPE_STRING, &id,
                                                 DBUS_TYPE_INVALID);
                        dbus_connection_send(conn, reply, NULL);
                        dbus_message_unref(reply);
                    }
                } else {
                    DBusMessage *err = dbus_message_new_error(
                        msg, "org.freedesktop.DBus.Error.UnknownInterface",
                        "No such interface");
                    dbus_connection_send(conn, err, NULL);
                    dbus_message_unref(err);
                }
                dbus_connection_flush(conn);
            } else if (type == DBUS_MESSAGE_TYPE_SIGNAL) {
                const char *iface = dbus_message_get_interface(msg);
                const char *member = dbus_message_get_member(msg);
                printf("SIGNAL-RECV: %s.%s sender=%s\n",
                       iface ? iface : "(nil)", member ? member : "(nil)",
                       dbus_message_get_sender(msg));
            }
            dbus_message_unref(msg);
        }
        elapsed += 100;
    }
}

static void run_client(void)
{
    DBusError err;
    dbus_error_init(&err);

    add_match("type='signal',interface='com.canonical.AppMenu.Registrar',member='WindowRegistered'");

    /* Call RegisterWindow on the registrar */
    DBusMessage *call = dbus_message_new_method_call(
        "com.canonical.AppMenu.Registrar", "/com/canonical/AppMenu/Registrar",
        "com.canonical.AppMenu.Registrar", "RegisterWindow");
    if (!call)
        die("new_method_call", NULL);
    dbus_uint32_t wid = 42;
    const char *menu_path = "/org/appmenu/test";
    dbus_message_append_args(call, DBUS_TYPE_UINT32, &wid,
                             DBUS_TYPE_OBJECT_PATH, &menu_path,
                             DBUS_TYPE_INVALID);
    DBusMessage *reply = dbus_connection_send_with_reply_and_block(
        conn, call, 5000, &err);
    if (!reply)
        die("RegisterWindow call (send_with_reply_and_block)", &err);
    printf("REPLY-RECV: RegisterWindow ok\n");
    dbus_message_unref(call);
    dbus_message_unref(reply);

    /* Give the signal a moment, then drain it */
    for (int i = 0; i < 10; i++) {
        dbus_connection_read_write(conn, 100);
        DBusMessage *msg;
        int got_signal = 0;
        while ((msg = dbus_connection_pop_message(conn)) != NULL) {
            if (dbus_message_get_type(msg) == DBUS_MESSAGE_TYPE_SIGNAL) {
                printf("SIGNAL-RECV: %s.%s sender=%s\n",
                       dbus_message_get_interface(msg),
                       dbus_message_get_member(msg),
                       dbus_message_get_sender(msg));
                got_signal = 1;
            }
            dbus_message_unref(msg);
        }
        if (got_signal)
            break;
    }

    /* Call GetMenuForWindow */
    call = dbus_message_new_method_call(
        "com.canonical.AppMenu.Registrar", "/com/canonical/AppMenu/Registrar",
        "com.canonical.AppMenu.Registrar", "GetMenuForWindow");
    dbus_message_append_args(call, DBUS_TYPE_UINT32, &wid, DBUS_TYPE_INVALID);
    reply = dbus_connection_send_with_reply_and_block(conn, call, 5000, &err);
    if (!reply)
        die("GetMenuForWindow call", &err);
    const char *service = NULL;
    const char *menu_obj = NULL;
    if (!dbus_message_get_args(reply, &err,
                               DBUS_TYPE_STRING, &service,
                               DBUS_TYPE_OBJECT_PATH, &menu_obj,
                               DBUS_TYPE_INVALID))
        die("parse GetMenuForWindow reply", &err);
    printf("REPLY-RECV: GetMenuForWindow -> %s %s\n", service, menu_obj);
    dbus_message_unref(call);
    dbus_message_unref(reply);
    printf("CLIENT: done\n");
}

int main(int argc, char **argv)
{
    DBusError err;
    const char *address = getenv("DBUS_SESSION_BUS_ADDRESS");

    if (argc < 2) {
        fprintf(stderr, "usage: %s registrar|client [bus-address]\n", argv[0]);
        return 2;
    }
    if (argc > 2)
        address = argv[2];
    if (!address || !*address) {
        fprintf(stderr, "no bus address\n");
        return 2;
    }

    dbus_error_init(&err);
    conn = dbus_connection_open_private(address, &err);
    if (!conn)
        die("connect", &err);
    dbus_connection_set_exit_on_disconnect(conn, TRUE);
    if (!dbus_bus_register(conn, &err))
        die("register (Hello)", &err);
    printf("CONNECTED: unique name %s\n", dbus_bus_get_unique_name(conn));

    if (strcmp(argv[1], "registrar") == 0) {
        /* Exactly what Menu.app does */
        dbus_uint32_t flags = DBUS_NAME_FLAG_REPLACE_EXISTING |
                              DBUS_NAME_FLAG_ALLOW_REPLACEMENT;
        dbus_uint32_t result = dbus_bus_request_name(
            conn, "com.canonical.AppMenu.Registrar", flags, &err);
        if (dbus_error_is_set(&err))
            die("request_name", &err);
        printf("REQUESTNAME: com.canonical.AppMenu.Registrar -> %u\n", result);
        if (result != DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER &&
            result != DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER) {
            fprintf(stderr, "FAIL: could not become primary owner (result %u)\n", result);
            return 1;
        }
        add_match("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged'");
        serve_registrar(argc > 3 ? atol(argv[3]) : 15000);
        printf("REGISTRAR: done\n");
    } else {
        run_client();
    }

    return 0;
}

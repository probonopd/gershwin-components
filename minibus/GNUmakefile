include $(GNUSTEP_MAKEFILES)/common.make

# Tools
TOOL_NAME = minibus minibus-test simple-test simple-format-test byte-analyzer test-real-dbus test-hello-only minibus-libdbus hello-field-analyzer compare-hello-format test-hello-destination test-hello-reply-only test-alignment hello-length-analysis debug-listnames debug-message-format debug-listnames-serialization test-array-parsing test-requestname debug-hello-reply test-gdbus-proxy test-start-service test-message-parsing debug-message-parsing test-dict-roundtrip test-empty-string-issue test-variant-format test-complex-signature

minibus_OBJC_FILES = main-daemon.m MBDaemon.m MBConnection.m MBMessage.m MBTransport.m MBClient.m MBServiceManager.m MBServiceFile.m
minibus-test_OBJC_FILES = main-test.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
simple-test_OBJC_FILES = simple-test.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
simple-format-test_OBJC_FILES = simple-format-test.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
byte-analyzer_OBJC_FILES = byte-analyzer.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
test-real-dbus_OBJC_FILES = test-real-dbus.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
test-hello-only_OBJC_FILES = test-hello-only.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
hello-field-analyzer_OBJC_FILES = hello-field-analyzer.m MBMessage.m MBTransport.m
compare-hello-format_OBJC_FILES = compare-hello-format.m MBMessage.m MBTransport.m MBConnection.m MBDaemon.m MBServiceManager.m MBServiceFile.m
test-hello-destination_OBJC_FILES = test-hello-destination.m MBMessage.m MBTransport.m
test-hello-reply-only_OBJC_FILES = test-hello-reply-only.m MBMessage.m MBTransport.m
test-alignment_OBJC_FILES = test-alignment.m MBMessage.m MBTransport.m
hello-length-analysis_OBJC_FILES = hello-length-analysis.m MBMessage.m MBTransport.m
debug-listnames_OBJC_FILES = debug-listnames.m MBMessage.m MBTransport.m
debug-message-format_OBJC_FILES = debug-message-format.m MBMessage.m MBTransport.m
debug-listnames-serialization_OBJC_FILES = debug-listnames-serialization.m MBMessage.m MBTransport.m
test-array-parsing_OBJC_FILES = test-array-parsing.m MBMessage.m
test-requestname_OBJC_FILES = test-requestname.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
debug-hello-reply_OBJC_FILES = debug-hello-reply.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
test-gdbus-proxy_OBJC_FILES = test-gdbus-proxy.m
test-start-service_OBJC_FILES = test-start-service.m
test-message-parsing_OBJC_FILES = test-message-parsing.m MBMessage.m MBTransport.m
debug-message-parsing_OBJC_FILES = debug-message-parsing.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
debug-parsing-issue_OBJC_FILES = debug-parsing-issue.m MBMessage.m MBTransport.m
test-service_OBJC_FILES = test-service.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
test-activation-client_OBJC_FILES = test-activation-client.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
test-auto-activation_OBJC_FILES = test-auto-activation.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
debug-nameowner-signal_OBJC_FILES = debug-nameowner-signal.m MBMessage.m MBTransport.m
test-glib-simple_C_FILES = test-glib-simple.c
debug-parsing-detailed_OBJC_FILES = debug-parsing-detailed.m MBMessage.m MBTransport.m
test-second-message_OBJC_FILES = test-second-message.m MBMessage.m MBTransport.m
test-full-buffer_OBJC_FILES = test-full-buffer.m MBMessage.m MBTransport.m
test-startservice_OBJC_FILES = test-startservice.m MBMessage.m MBTransport.m
test-startservice-direct_OBJC_FILES = test-startservice-direct.m
debug-offset-469_OBJC_FILES = debug-offset-469.m MBMessage.m MBTransport.m
test-comprehensive-types_OBJC_FILES = test-comprehensive-types.m MBMessage.m MBTransport.m
test-struct-types_OBJC_FILES = test-struct-types.m MBMessage.m MBTransport.m
debug-struct-serialization_OBJC_FILES = debug-struct-serialization.m MBMessage.m MBTransport.m
debug-struct-signature_OBJC_FILES = debug-struct-signature.m MBMessage.m MBTransport.m
debug-struct-parsing_OBJC_FILES = debug-struct-parsing.m MBMessage.m MBTransport.m
test-enhanced-introspection_OBJC_FILES = test-enhanced-introspection.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
test-real-introspection_OBJC_FILES = test-real-introspection.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
debug-uint32_OBJC_FILES = debug-uint32.m
debug-uint32-detailed_OBJC_FILES = debug-uint32-detailed.m
test-signature-fix_OBJC_FILES = test-signature-fix.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
test-requestname-signature_OBJC_FILES = test-requestname-signature.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
test-variant-fix_OBJC_FILES = test-variant-fix.m MBMessage.m MBTransport.m
test-xfce-compatibility_OBJC_FILES = test-xfce-compatibility.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
test-dict-roundtrip_OBJC_FILES = test-dict-roundtrip.m MBMessage.m
test-empty-string-issue_OBJC_FILES = test-empty-string-issue.m MBMessage.m
test-variant-format_OBJC_FILES = test-variant-format.m MBMessage.m
test-complex-signature_OBJC_FILES = test-complex-signature.m MBMessage.m

# Compiler flags for production builds
minibus_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
minibus-test_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
simple-test_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
simple-format-test_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
byte-analyzer_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
test-real-dbus_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
minibus-libdbus_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
test-hello-only_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
hello-field-analyzer_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
compare-hello-format_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
test-hello-destination_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
test-hello-reply-only_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
test-alignment_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
test-array-parsing_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
test-gdbus-proxy_OBJCFLAGS += -Wall -Wextra -O2 -fblocks $(shell pkg-config --cflags glib-2.0 gio-2.0)
test-start-service_OBJCFLAGS += -Wall -Wextra -O2 -fblocks $(shell pkg-config --cflags glib-2.0 gio-2.0)
debug-message-parsing_OBJCFLAGS += -Wall -Wextra -O2 -fblocks $(shell pkg-config --cflags glib-2.0 gio-2.0)
test-glib-simple_CFLAGS += -Wall -Wextra -O2 $(shell pkg-config --cflags glib-2.0 gio-2.0)

# Include paths
minibus_CPPFLAGS += -DGNUSTEP -I/usr/local/include $(shell pkg-config --cflags dbus-1)
minibus-test_CPPFLAGS += -DGNUSTEP -I/usr/local/include $(shell pkg-config --cflags dbus-1)
simple-test_CPPFLAGS += -DGNUSTEP -I/usr/local/include $(shell pkg-config --cflags dbus-1)
simple-format-test_CPPFLAGS += -DGNUSTEP -I/usr/local/include $(shell pkg-config --cflags dbus-1)
byte-analyzer_CPPFLAGS += -DGNUSTEP -I/usr/local/include $(shell pkg-config --cflags dbus-1)
test-real-dbus_CPPFLAGS += -DGNUSTEP -I/usr/local/include $(shell pkg-config --cflags dbus-1)
minibus-libdbus_CPPFLAGS += -DGNUSTEP -I/usr/local/include $(shell pkg-config --cflags dbus-1)
hello-field-analyzer_CPPFLAGS += -DGNUSTEP -I/usr/local/include
compare-hello-format_CPPFLAGS += -DGNUSTEP -I/usr/local/include
test-hello-destination_CPPFLAGS += -DGNUSTEP -I/usr/local/include
test-hello-reply-only_CPPFLAGS += -DGNUSTEP -I/usr/local/include
test-alignment_CPPFLAGS += -DGNUSTEP -I/usr/local/include
hello-length-analysis_CPPFLAGS += -DGNUSTEP -I/usr/local/include
test-array-parsing_CPPFLAGS += -DGNUSTEP -I/usr/local/include
test-requestname_CPPFLAGS += -DGNUSTEP -I/usr/local/include
test-gdbus-proxy_CPPFLAGS += -DGNUSTEP -I/usr/local/include $(shell pkg-config --cflags glib-2.0 gio-2.0)
test-start-service_CPPFLAGS += -DGNUSTEP -I/usr/local/include $(shell pkg-config --cflags glib-2.0 gio-2.0)

# Library paths and links
minibus_LDFLAGS += -L/usr/local/lib $(shell pkg-config --libs dbus-1)
minibus-test_LDFLAGS += -L/usr/local/lib $(shell pkg-config --libs dbus-1)
simple-test_LDFLAGS += -L/usr/local/lib $(shell pkg-config --libs dbus-1)
simple-format-test_LDFLAGS += -L/usr/local/lib $(shell pkg-config --libs dbus-1)
byte-analyzer_LDFLAGS += -L/usr/local/lib
test-real-dbus_LDFLAGS += -L/usr/local/lib
minibus-libdbus_LDFLAGS += -L/usr/local/lib $(shell pkg-config --libs dbus-1)
hello-field-analyzer_LDFLAGS += -L/usr/local/lib
compare-hello-format_LDFLAGS += -L/usr/local/lib
test-hello-destination_LDFLAGS += -L/usr/local/lib
test-hello-reply-only_LDFLAGS += -L/usr/local/lib
test-alignment_LDFLAGS += -L/usr/local/lib
hello-length-analysis_LDFLAGS += -L/usr/local/lib
test-array-parsing_LDFLAGS += -L/usr/local/lib
test-requestname_LDFLAGS = -lgnustep-base -lobjc

minibus_TOOL_LIBS += -lobjc -lBlocksRuntime
minibus-test_TOOL_LIBS += -lobjc -lBlocksRuntime
simple-test_TOOL_LIBS += -lobjc -lBlocksRuntime
simple-format-test_TOOL_LIBS += -lobjc -lBlocksRuntime
byte-analyzer_TOOL_LIBS += -lobjc -lBlocksRuntime
test-real-dbus_TOOL_LIBS += -lobjc -lBlocksRuntime
hello-field-analyzer_TOOL_LIBS += -lobjc -lBlocksRuntime
compare-hello-format_TOOL_LIBS += -lobjc -lBlocksRuntime
test-hello-destination_TOOL_LIBS += -lobjc -lBlocksRuntime
test-hello-reply-only_TOOL_LIBS += -lobjc -lBlocksRuntime
test-alignment_TOOL_LIBS += -lobjc -lBlocksRuntime
hello-length-analysis_TOOL_LIBS += -lobjc -lBlocksRuntime
debug-listnames-serialization_TOOL_LIBS += -lobjc -lBlocksRuntime
test-array-parsing_TOOL_LIBS += -lobjc -lBlocksRuntime
test-gdbus-proxy_TOOL_LIBS += -lobjc -lBlocksRuntime $(shell pkg-config --libs glib-2.0 gio-2.0)
test-start-service_TOOL_LIBS += -lobjc -lBlocksRuntime $(shell pkg-config --libs glib-2.0 gio-2.0)

test-glib-simple_TOOL_LIBS += -lobjc -lBlocksRuntime $(shell pkg-config --libs glib-2.0 gio-2.0)

debug-listnames-serialization_CPPFLAGS += -DGNUSTEP -I/usr/local/include

include $(GNUSTEP_MAKEFILES)/tool.make

# Test targets
test: all
	@echo "Starting minibus daemon in background..."
	./$(GNUSTEP_OBJ_DIR)/minibus &
	@sleep 2
	@echo "Running simple test..."
	./$(GNUSTEP_OBJ_DIR)/simple-test
	@echo "Stopping daemon..."
	pkill -f minibus || true

.PHONY: test
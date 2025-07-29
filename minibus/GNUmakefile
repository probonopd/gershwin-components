include $(GNUSTEP_MAKEFILES)/common.make

# Tools
TOOL_NAME = minibus minibus-test simple-test simple-format-test byte-analyzer test-real-dbus test-hello-only minibus-libdbus hello-field-analyzer compare-hello-format test-hello-destination test-hello-reply-only test-alignment hello-length-analysis debug-listnames debug-message-format

minibus_OBJC_FILES = main-daemon.m MBDaemon.m MBConnection.m MBMessage.m MBTransport.m MBClient.m
minibus-test_OBJC_FILES = main-test.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
simple-test_OBJC_FILES = simple-test.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
simple-format-test_OBJC_FILES = simple-format-test.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
byte-analyzer_OBJC_FILES = byte-analyzer.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
test-real-dbus_OBJC_FILES = test-real-dbus.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
test-hello-only_OBJC_FILES = test-hello-only.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
hello-field-analyzer_OBJC_FILES = hello-field-analyzer.m MBMessage.m MBTransport.m
compare-hello-format_OBJC_FILES = compare-hello-format.m MBMessage.m MBTransport.m MBConnection.m MBDaemon.m
test-hello-destination_OBJC_FILES = test-hello-destination.m MBMessage.m MBTransport.m
test-hello-reply-only_OBJC_FILES = test-hello-reply-only.m MBMessage.m MBTransport.m
test-alignment_OBJC_FILES = test-alignment.m MBMessage.m MBTransport.m
hello-length-analysis_OBJC_FILES = hello-length-analysis.m MBMessage.m MBTransport.m
debug-listnames_OBJC_FILES = debug-listnames.m MBMessage.m MBTransport.m
debug-message-format_OBJC_FILES = debug-message-format.m MBMessage.m MBTransport.m

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
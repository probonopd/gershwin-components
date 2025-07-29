include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = minibus minibus-test simple-test

minibus_OBJC_FILES = main-daemon.m MBDaemon.m MBConnection.m MBMessage.m MBTransport.m MBClient.m
minibus-test_OBJC_FILES = main-test.m MBClient.m MBConnection.m MBMessage.m MBTransport.m
simple-test_OBJC_FILES = simple-test.m MBClient.m MBConnection.m MBMessage.m MBTransport.m

# Compiler flags for production builds
minibus_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
minibus-test_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
simple-test_OBJCFLAGS += -Wall -Wextra -O2 -fblocks
minibus-libdbus_OBJCFLAGS += -Wall -Wextra -O2 -fblocks

# Include paths
minibus_CPPFLAGS += -DGNUSTEP -I/usr/local/include $(shell pkg-config --cflags dbus-1)
minibus-test_CPPFLAGS += -DGNUSTEP -I/usr/local/include $(shell pkg-config --cflags dbus-1)
simple-test_CPPFLAGS += -DGNUSTEP -I/usr/local/include $(shell pkg-config --cflags dbus-1)
minibus-libdbus_CPPFLAGS += -DGNUSTEP -I/usr/local/include $(shell pkg-config --cflags dbus-1)

# Library paths and links
minibus_LDFLAGS += -L/usr/local/lib $(shell pkg-config --libs dbus-1)
minibus-test_LDFLAGS += -L/usr/local/lib $(shell pkg-config --libs dbus-1)
simple-test_LDFLAGS += -L/usr/local/lib $(shell pkg-config --libs dbus-1)
minibus-libdbus_LDFLAGS += -L/usr/local/lib $(shell pkg-config --libs dbus-1)

minibus_TOOL_LIBS += -lobjc -lBlocksRuntime
minibus-test_TOOL_LIBS += -lobjc -lBlocksRuntime
simple-test_TOOL_LIBS += -lobjc -lBlocksRuntime
minibus-libdbus_TOOL_LIBS += -lobjc -lBlocksRuntime

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
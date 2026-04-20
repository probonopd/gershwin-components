include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = dshelper

dshelper_OBJC_FILES = \
	main.m \
	dshelper.m

dshelper_HEADER_FILES = \
	dshelper.h

dshelper_OBJCFLAGS = -fobjc-arc
dshelper_LDFLAGS = -lcrypt -ldispatch -lBlocksRuntime

# Install to /System/Library/Tools
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

include $(GNUSTEP_MAKEFILES)/tool.make

# Install service files (platform-specific)
after-install::
ifeq ($(findstring freebsd,$(GNUSTEP_HOST_OS)),freebsd)
	$(MKINSTALLDIRS) /usr/local/etc/rc.d
	$(INSTALL) -m 555 dshelper.rc /usr/local/etc/rc.d/dshelper
endif
ifeq ($(findstring linux,$(GNUSTEP_HOST_OS)),linux)
	@if command -v systemctl >/dev/null 2>&1; then \
		$(MKINSTALLDIRS) /etc/systemd/system; \
		$(INSTALL) -m 644 dshelper.service /etc/systemd/system/dshelper.service; \
		$(INSTALL) -m 644 gdomap.service /etc/systemd/system/gdomap.service; \
		echo "Installed systemd services (dshelper + gdomap)"; \
	elif [ -d /etc/init.d ]; then \
		$(INSTALL) -m 755 dshelper.init /etc/init.d/dshelper; \
		echo "Installed sysvinit script"; \
	else \
		echo "No supported init system detected"; \
	fi
endif

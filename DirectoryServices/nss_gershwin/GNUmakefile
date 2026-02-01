include $(GNUSTEP_MAKEFILES)/common.make

# FreeBSD/Linux NSS expects nss_<name>.so.1 (no lib prefix)
# GNUstep library.make adds lib prefix, so we use custom targets

CC ?= cc
CFLAGS += -Wall -Wextra -fPIC
LDFLAGS += -shared

NSS_LIB = nss_gershwin.so.1
INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARIES)

all: $(NSS_LIB)

$(NSS_LIB): nss_gershwin.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f $(NSS_LIB) *.o

install: $(NSS_LIB)
	install -d $(INSTALL_DIR)
	install -m 755 $(NSS_LIB) $(INSTALL_DIR)/$(NSS_LIB)
ifeq ($(findstring freebsd,$(GNUSTEP_HOST_OS)),freebsd)
	@if [ -d /usr/local/libdata/ldconfig ]; then \
		echo "$(INSTALL_DIR)" > /usr/local/libdata/ldconfig/gershwin; \
	fi
endif
	ldconfig -m $(INSTALL_DIR) || true

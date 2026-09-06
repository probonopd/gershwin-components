include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

# NSS module naming conventions:
# - FreeBSD: nss_<name>.so.1
# - Linux glibc: libnss_<name>.so.2

CC ?= cc
CFLAGS += -Wall -Wextra -fPIC
LDFLAGS += -shared

ifeq ($(findstring linux,$(GNUSTEP_HOST_OS)),linux)
NSS_LIB = libnss_gershwin.so.2
else
NSS_LIB = nss_gershwin.so.1
endif
INSTALL_DIR = $(GNUSTEP_SYSTEM_LIBRARIES)

all: $(NSS_LIB)

$(NSS_LIB): nss_gershwin.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f $(NSS_LIB) *.o

install: $(NSS_LIB)
	install -d $(INSTALL_DIR)
	install -m 755 $(NSS_LIB) $(INSTALL_DIR)/$(NSS_LIB)
ifeq ($(findstring linux,$(GNUSTEP_HOST_OS)),linux)
	install -d /etc/ld.so.conf.d
	@echo "$(INSTALL_DIR)" > /etc/ld.so.conf.d/gershwin.conf
	ldconfig
endif
ifeq ($(findstring freebsd,$(GNUSTEP_HOST_OS)),freebsd)
	install -d /usr/local/libdata/ldconfig
	@echo "$(INSTALL_DIR)" > /usr/local/libdata/ldconfig/gershwin
	ldconfig
endif


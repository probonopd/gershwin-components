include $(GNUSTEP_MAKEFILES)/common.make

LIBRARY_NAME = nss_gershwin

nss_gershwin_C_FILES = nss_gershwin.c

nss_gershwin_CFLAGS = -Wall -Wextra
nss_gershwin_LDFLAGS =

# Build as shared library with version
nss_gershwin_SOVERSION = 1

# Install to /System/Library/Libraries
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

include $(GNUSTEP_MAKEFILES)/library.make

# Custom post-install to run ldconfig
after-install::
	ldconfig -m $(GNUSTEP_LIBRARIES)

# Clean up module files
after-clean::
	rm -f *.o *.so *.so.*

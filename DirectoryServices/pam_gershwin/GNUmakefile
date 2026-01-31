include $(GNUSTEP_MAKEFILES)/common.make

LIBRARY_NAME = pam_gershwin

pam_gershwin_C_FILES = pam_gershwin.c

pam_gershwin_CFLAGS = -Wall -Wextra
pam_gershwin_LDFLAGS = -lpam

# Install to /System/Library/Libraries
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

include $(GNUSTEP_MAKEFILES)/library.make

# Clean up module files
after-clean::
	rm -f *.o *.so *.so.*

include $(GNUSTEP_MAKEFILES)/common.make

# Build order matters: gsdh first, then NSS module
# Note: PAM module removed - authentication works via pam_unix using NSS
SUBPROJECTS = gsdh nss_gershwin

include $(GNUSTEP_MAKEFILES)/aggregate.make

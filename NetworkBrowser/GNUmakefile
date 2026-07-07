include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_SYSTEM_APPS := $(GNUSTEP_SYSTEM_APPS)/Utilities
GNUSTEP_LOCAL_APPS := $(GNUSTEP_LOCAL_APPS)/Utilities

# Disable desktop file generation early (pl2link tool not available)
ADDITIONAL_TOOL_LIBS = 
GNUSTEP_TOOL_LIBS = 

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

APP_NAME = NetworkBrowser
PACKAGE_NAME = NetworkBrowser
VERSION = 0.1

NetworkBrowser_PRINCIPAL_CLASS = NSApplication
NetworkBrowser_APPLICATION_ICON =

NetworkBrowser_HEADER_FILES = \
	NetworkBrowser.h \
	ServiceListView.h \
	ServiceDetailsView.h

NetworkBrowser_OBJC_FILES = \
	Main.m \
	NetworkBrowser.m \
	ServiceListView.m \
	ServiceDetailsView.m

NetworkBrowser_RESOURCE_FILES = \
	Info.plist \
	NetworkBrowser.desktop

NetworkBrowser_LOCALIZED_RESOURCE_FILES =

# Command-line test tools
NetworkBrowserTest_OBJC_FILES = \
	NetworkBrowserTest.m

MdnsSdCheckTest_OBJC_FILES = \
	MdnsSdCheckTest.m

TOOL_NAME = NetworkBrowserTest MdnsSdCheckTest
HAVE_DNS_SD := $(shell pkg-config --exists dns-sd 2>/dev/null && echo yes || echo no)

ifeq ($(HAVE_DNS_SD),no)
  HAVE_DNS_SD := $(shell pkg-config --exists avahi-compat-libdns_sd 2>/dev/null && echo yes || echo no)
endif

ifeq ($(HAVE_DNS_SD),no)
  # Try alternative: check if header exists
  HAVE_DNS_SD_HEADER := $(shell test -f /usr/include/dns_sd.h && echo yes || echo no)
  ifeq ($(HAVE_DNS_SD_HEADER),no)
    # Try Avahi compatibility header
    HAVE_DNS_SD_HEADER := $(shell test -d /usr/include/avahi-compat-libdns_sd && echo yes || echo no)
  endif
  ifeq ($(HAVE_DNS_SD_HEADER),no)
    # Try system-specific locations
    HAVE_DNS_SD_HEADER := $(shell test -f /usr/local/include/dns_sd.h && echo yes || echo no)
  endif
else
  HAVE_DNS_SD_HEADER := yes
endif

ifeq ($(HAVE_DNS_SD_HEADER),yes)
  # Try to find the library in common locations and multiarch paths
  HAVE_DNS_SD_LIB := $(shell test -f /usr/lib/libdns_sd.so -o -f /usr/lib/libdns_sd.a || \
    test -f /usr/lib/*/libdns_sd.so -o -f /usr/lib/*/libdns_sd.a || \
    test -f /usr/local/lib/libdns_sd.so -o -f /usr/local/lib/libdns_sd.a && echo yes || echo no)
  ifeq ($(HAVE_DNS_SD_LIB),no)
    # Check for Avahi's compatibility library symlink
    HAVE_DNS_SD_LIB := $(shell test -f /usr/lib/libavahi-compat-libdnssd.so* 2>/dev/null || \
      test -f /usr/lib/*/libavahi-compat-libdnssd.so* 2>/dev/null && echo yes || echo no)
  endif
else
  HAVE_DNS_SD_LIB := no
endif

ifeq ($(HAVE_DNS_SD_HEADER),yes)
  ifeq ($(HAVE_DNS_SD_LIB),yes)
    # NextBSD ships the base mDNSResponder client library as
    # /usr/lib/system/libdns_sd.so. That directory is on Gershwin binaries'
    # runtime RUNPATH but is NOT a default link-time search dir, so name the
    # -L explicitly here. Gated on that exact base file existing, so Linux
    # (/usr/lib, default path) and FreeBSD ports (/usr/local/lib) — where this
    # file is absent — are completely unaffected.
    ifneq ($(wildcard /usr/lib/system/libdns_sd.so),)
      NetworkBrowser_GUI_LIBS += -L/usr/lib/system
      NetworkBrowserTest_GUI_LIBS += -L/usr/lib/system
    endif
    NetworkBrowser_GUI_LIBS += -ldns_sd
    NetworkBrowserTest_GUI_LIBS += -ldns_sd
    ADDITIONAL_OBJCFLAGS += -DHAVE_DNS_SD=1
  else
    $(error libdns_sd not found. Please install it:\
      \n  - Debian/Ubuntu: apt-get install libavahi-compat-libdnssd-dev\
      \n  - Fedora/RHEL: dnf install avahi-compat-libdns_sd-devel\
      \n  - FreeBSD/OpenBSD: pkg install mDNSResponder\
      \n  - macOS: Should be included in System Framework)
  endif
else
  $(error dns_sd.h header not found. Please install libdns_sd development files:\
    \n  - Debian/Ubuntu: apt-get install libavahi-compat-libdnssd-dev\
    \n  - Fedora/RHEL: dnf install avahi-compat-libdns_sd-devel\
    \n  - FreeBSD/OpenBSD: pkg install mDNSResponder\
    \n  - macOS: Xcode Command Line Tools (xcode-select --install))
endif

-include GNUmakefile.local

include $(GNUSTEP_MAKEFILES)/application.make
include $(GNUSTEP_MAKEFILES)/tool.make

before-install::
	mkdir -p $(GNUSTEP_APPS)

# Override desktop file generation to avoid pl2link requirement
NetworkBrowser.app/Resources/NetworkBrowser.desktop: NetworkBrowser.desktop
	@mkdir -p NetworkBrowser.app/Resources
	@cp NetworkBrowser.desktop NetworkBrowser.app/Resources/NetworkBrowser.desktop

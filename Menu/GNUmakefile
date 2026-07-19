GNUSTEP_INSTALLATION_DOMAIN = SYSTEM
include $(GNUSTEP_MAKEFILES)/common.make

PACKAGE_NAME = Menu
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM
VERSION = 1.0
APP_NAME = Menu

# Ensure internal GNUstep install uses the canonical CoreServices path.
# This sets APP_INSTALL_DIR in $(GNUSTEP_MAKEFILES)/Instance/application.make
Menu_INSTALL_DIR = /System/Library/CoreServices/Applications

# App info
Menu_APPLICATION_ICON = Menu.png
Menu_PRINCIPAL_CLASS = MenuApplication

# Source files
Menu_OBJC_FILES = \
	main.m \
	MenuApplication.m \
	MenuController.m \
	MenuProfiler.m \
	MenuBarView.m \
	CustomMenuPanel.m \
	AppMenuWidget.m \
	MenuProtocolManager.m \
	CrashHandler.m \
	GNUStepMenuImporter.m \
	DBusMenuImporter.m \
	GTKMenuImporter.m \
	DBusMenuParser.m \
	GTKMenuParser.m \
	DBusMenuShortcutParser.m \
	GNUStepMenuActionHandler.m \
	DBusMenuActionHandler.m \
	GTKActionHandler.m \
	DBusSubmenuManager.m \
	GTKSubmenuManager.m \
	DBusConnection.m \
	MenuUtils.m \
	X11ShortcutManager.m \
	RoundedCornersView.m \
	ActionSearch.m \
	StatusItemManager.m \
	GSMenuExtraContext.m \
	GSMenuExtraBundle.m \
	GSMenuExtraInstance.m \
	MenuExtrasPrefPanel.m \
	StatusItems/ClockExtra/ClockExtra.m \
	StatusItems/BatteryExtra/BatteryExtra.m \
	StatusItems/WLANExtra/WLANExtra.m \
	StatusItems/SoundExtra/SoundExtra.m \
	StatusItems/BrightnessExtra/BrightnessExtra.m \
	WindowMonitor.m \
	AppMenuImporter.m \
	WindowSwitchContext.m \
	StatusItems/SystemMonitor/CPUProvider.m \
	StatusItems/SystemMonitor/RAMProvider.m \
	SysfsBacklightBackend.m \
	EvdevBrightnessKeySource.m \
	TintedMenuItemCell.m

# Header files
Menu_HEADER_FILES = \
	MenuApplication.h \
	MenuController.h \
	MenuProfiler.h \
	MenuBarView.h \
	CustomMenuPanel.h \
	AppMenuWidget.h \
	MenuProtocolManager.h \
	CrashHandler.h \
	GNUStepMenuIPC.h \
	GNUStepMenuImporter.h \
	DBusMenuImporter.h \
	GTKMenuImporter.h \
	DBusMenuParser.h \
	GTKMenuParser.h \
	DBusMenuShortcutParser.h \
	GNUStepMenuActionHandler.h \
	DBusMenuActionHandler.h \
	GTKActionHandler.h \
	DBusSubmenuManager.h \
	GTKSubmenuManager.h \
	DBusConnection.h \
	MenuUtils.h \
	X11ShortcutManager.h \
	RoundedCornersView.h \
	ActionSearch.h \
	GSMenuExtra.h \
	GSMenuExtraContext.h \
	GSMenuExtraBundle.h \
	GSMenuExtraInstance.h \
	MenuExtrasPrefPanel.h \
	StatusItemProvider.h \
	StatusItemManager.h \
	WindowMonitor.h \
	AppMenuImporter.h \
	WindowSwitchContext.h \
	BacklightBackend.h \
	BrightnessKeySource.h \
	SysfsBacklightBackend.h \
	EvdevBrightnessKeySource.h \
	SoundVolume.h \
	StatusItems/SystemMonitor/CPUProvider.h \
	StatusItems/SystemMonitor/RAMProvider.h \
	TintedMenuItemCell.h

# Resources
Menu_RESOURCE_FILES = \
	Menu.png \
	Info.plist \
	Resources/Icons/battery.png \
	Resources/Icons/battery-medium.png \
	Resources/Icons/battery-low.png \
	Resources/Icons/battery-charged.png \
	Resources/Icons/battery-charging.png \
	Resources/Icons/volume-high.png \
	Resources/Icons/volume-medium.png \
	Resources/Icons/volume-low.png \
	Resources/Icons/volume-muted.png \
	Resources/Icons/wlan.png \
	Resources/Icons/wlan-good.png \
	Resources/Icons/wlan-ok.png \
	Resources/Icons/wlan-weak.png \
	Resources/Icons/wlan-disabled.png \
	Resources/Icons/wlan-off.png \
	Resources/Icons/brightness.png \
	Resources/Icons/clock.png \
	Resources/Icons/cpu.png \
	Resources/Icons/ram.png


# SVG-to-PNG conversion rules
before-build:: $(patsubst %.svg,%.png,$(wildcard Resources/Icons/*.svg))

Resources/Icons/%.png: Resources/Icons/%.svg
	convert -background none -define png:color-type=6 -size 20x20 $< $@

# Libraries and frameworks - configured by configure script
Menu_TOOL_LIBS += -ldbus-1 -lX11
Menu_GUI_LIBS += -L/System/Library/Libraries -lgnustep-gui -lgnustep-base -lobjc -ldispatch -lSoundBackend -lNetworkBackend
Menu_LDFLAGS += -Wl,--export-dynamic -L/System/Library/Libraries -Wl,-rpath,/System/Library/Libraries -Wl,--no-as-needed

# Compiler flags - Force use of /System GNUstep and objc2 with ARC

# Platform-specific flags for Linux and BSD - configured by configure script
UNAME_S := $(shell uname -s)
DBUS_CFLAGS := $(shell pkg-config --cflags dbus-1 2>/dev/null || echo "-I/usr/include/dbus-1.0 -I/usr/lib/dbus-1.0/include")
ifeq ($(UNAME_S),Linux)
	ADDITIONAL_OBJCFLAGS = -Wall -Wextra -O2 -fobjc-runtime=gnustep-2.0 -fobjc-arc -Wno-unused-parameter -D_GNU_SOURCE -I.
	ADDITIONAL_CPPFLAGS = $(DBUS_CFLAGS)
endif
ifeq ($(UNAME_S),FreeBSD)
	ADDITIONAL_OBJCFLAGS = -Wall -Wextra -O2 -fobjc-runtime=gnustep-2.0 -fobjc-arc -Wno-unused-parameter -D_BSD_SOURCE -I.
	ADDITIONAL_CPPFLAGS = $(DBUS_CFLAGS)
	Menu_TOOL_LIBS += -lexecinfo
endif
ifeq ($(UNAME_S),NextBSD)
	ADDITIONAL_OBJCFLAGS = -Wall -Wextra -O2 -fobjc-runtime=gnustep-2.0 -fobjc-arc -Wno-unused-parameter -D_BSD_SOURCE -I.
	ADDITIONAL_CPPFLAGS = $(DBUS_CFLAGS)
	Menu_TOOL_LIBS += -lexecinfo
	Menu_GUI_LIBS += -L/usr/lib/system
	Menu_LDFLAGS += -Wl,-rpath,/usr/lib/system
endif
ifeq ($(UNAME_S),OpenBSD)
	ADDITIONAL_OBJCFLAGS = -Wall -Wextra -O2 -fobjc-runtime=gnustep-2.0 -fobjc-arc -Wno-unused-parameter -D_BSD_SOURCE -I.
	ADDITIONAL_CPPFLAGS = $(DBUS_CFLAGS)
	Menu_TOOL_LIBS += -L/usr/local/lib -lexecinfo
endif

# Profiling: build with  make PROFILE=1  to enable CPU instrumentation.
# When enabled, a summary is printed every 10s and on SIGUSR1.
ifeq ($(PROFILE),1)
ADDITIONAL_OBJCFLAGS += -DMENU_PROFILING=1
endif

ADDITIONAL_OBJCFLAGS += -I../Sound -I../Network -I/System/Library/Headers/SoundBackend -I/System/Library/Headers/NetworkBackend

# Canonical install location for Menu.app
INSTALL_APPS_DIR = /System/Library/CoreServices/Applications

include $(GNUSTEP_MAKEFILES)/application.make

# Build standalone .gsmenuextra bundles after main app is compiled
after-Menu-all::
	@echo "Building standalone menu extra bundles..."
	@(cd StatusItems/ClockExtra && GNUSTEP_MAKEFILES=$(GNUSTEP_MAKEFILES) $(MAKE) all 2>/dev/null || echo "  (ClockExtra skipped)")
	@(cd StatusItems/BatteryExtra && GNUSTEP_MAKEFILES=$(GNUSTEP_MAKEFILES) $(MAKE) all 2>/dev/null || echo "  (BatteryExtra skipped)")
	@(cd StatusItems/WLANExtra && GNUSTEP_MAKEFILES=$(GNUSTEP_MAKEFILES) $(MAKE) all 2>/dev/null || echo "  (WLANExtra skipped)")
	@(cd StatusItems/WLANExtra/wlanauth && GNUSTEP_MAKEFILES=$(GNUSTEP_MAKEFILES) $(MAKE) all 2>/dev/null || echo "  (wlanauth skipped)")
	@cp StatusItems/WLANExtra/wlanauth/obj/wlanauth Resources/ 2>/dev/null || true
	@(cd StatusItems/SoundExtra && GNUSTEP_MAKEFILES=$(GNUSTEP_MAKEFILES) $(MAKE) all 2>/dev/null || echo "  (SoundExtra skipped)")
	@(cd StatusItems/BrightnessExtra && GNUSTEP_MAKEFILES=$(GNUSTEP_MAKEFILES) $(MAKE) all 2>/dev/null || echo "  (BrightnessExtra skipped)")
	@echo "Done building bundles."

# Custom install target that completely overrides built-in behavior
.PHONY: custom-install custom-uninstall

install:: custom-install

custom-install: $(APP_NAME).app
	@echo "Building status item bundles..."
	@(cd StatusItems/SystemMonitor && GNUSTEP_MAKEFILES=$(GNUSTEP_MAKEFILES) $(MAKE) all)
	@(cd StatusItems/ClockExtra && GNUSTEP_MAKEFILES=$(GNUSTEP_MAKEFILES) $(MAKE) all)
	@(cd StatusItems/BatteryExtra && GNUSTEP_MAKEFILES=$(GNUSTEP_MAKEFILES) $(MAKE) all)
	@(cd StatusItems/WLANExtra && GNUSTEP_MAKEFILES=$(GNUSTEP_MAKEFILES) $(MAKE) all)
	@(cd StatusItems/WLANExtra/wlanauth && GNUSTEP_MAKEFILES=$(GNUSTEP_MAKEFILES) $(MAKE) all)
	@if [ -f StatusItems/WLANExtra/wlanauth/obj/wlanauth ]; then \
		cp StatusItems/WLANExtra/wlanauth/obj/wlanauth $(APP_NAME).app/Resources/; \
	fi
	@(cd StatusItems/SoundExtra && GNUSTEP_MAKEFILES=$(GNUSTEP_MAKEFILES) $(MAKE) all)
	@(cd StatusItems/BrightnessExtra && GNUSTEP_MAKEFILES=$(GNUSTEP_MAKEFILES) $(MAKE) all)
	@echo "Status item bundles built successfully"
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Installing $(APP_NAME) to $(DESTDIR)$(INSTALL_APPS_DIR)"; \
		rm -rf $(DESTDIR)/System/Applications/$(APP_NAME).app || true; \
		rm -rf $(DESTDIR)/System/CoreServices/Applications/$(APP_NAME).app || true; \
		rm -rf $(DESTDIR)/System/Library/CoreServices/Applications/$(APP_NAME).app || true; \
		mkdir -p $(DESTDIR)$(INSTALL_APPS_DIR); \
		cp -R $(APP_NAME).app $(DESTDIR)$(INSTALL_APPS_DIR)/; \
		mkdir -p $(DESTDIR)$(INSTALL_APPS_DIR)/$(APP_NAME).app/Resources; \
		cp Menu.png $(DESTDIR)$(INSTALL_APPS_DIR)/$(APP_NAME).app/Resources/; \
		echo "Installing status item bundles..."; \
		mkdir -p $(DESTDIR)/System/Library/Menu/StatusItems; \
		mkdir -p $(DESTDIR)/System/Library/MenuExtras; \
		cp -R StatusItems/SystemMonitor/SystemMonitor.bundle $(DESTDIR)/System/Library/Menu/StatusItems/ || true; \
		cp -R StatusItems/ClockExtra/Clock.gsmenuextra $(DESTDIR)/System/Library/Menu/StatusItems/ || true; \
		cp -R StatusItems/ClockExtra/Clock.gsmenuextra $(DESTDIR)/System/Library/MenuExtras/ || true; \
		cp -R StatusItems/BatteryExtra/Battery.gsmenuextra $(DESTDIR)/System/Library/Menu/StatusItems/ || true; \
		cp -R StatusItems/BatteryExtra/Battery.gsmenuextra $(DESTDIR)/System/Library/MenuExtras/ || true; \
		cp -R StatusItems/WLANExtra/WLAN.gsmenuextra $(DESTDIR)/System/Library/Menu/StatusItems/ || true; \
		cp -R StatusItems/WLANExtra/WLAN.gsmenuextra $(DESTDIR)/System/Library/MenuExtras/ || true; \
		cp -R StatusItems/SoundExtra/Sound.gsmenuextra $(DESTDIR)/System/Library/Menu/StatusItems/ || true; \
		cp -R StatusItems/SoundExtra/Sound.gsmenuextra $(DESTDIR)/System/Library/MenuExtras/ || true; \
		cp -R StatusItems/BrightnessExtra/Brightness.gsmenuextra $(DESTDIR)/System/Library/Menu/StatusItems/ || true; \
		cp -R StatusItems/BrightnessExtra/Brightness.gsmenuextra $(DESTDIR)/System/Library/MenuExtras/ || true; \
	else \
		echo "Installing $(APP_NAME) to $(INSTALL_APPS_DIR)"; \
		rm -rf /System/Applications/$(APP_NAME).app || true; \
		mkdir -p $(INSTALL_APPS_DIR); \
		cp -R $(APP_NAME).app $(INSTALL_APPS_DIR)/; \
		mkdir -p $(INSTALL_APPS_DIR)/$(APP_NAME).app/Resources; \
		cp Menu.png $(INSTALL_APPS_DIR)/$(APP_NAME).app/Resources/; \
			echo "Installing status item bundles..."; \
			mkdir -p /System/Library/MenuExtras; \
			mkdir -p /Local/Library/MenuExtras; \
			cp -R StatusItems/SystemMonitor/SystemMonitor.bundle /System/Library/Menu/StatusItems/ || true; \
			cp -R StatusItems/ClockExtra/Clock.gsmenuextra /System/Library/Menu/StatusItems/ || true; \
			cp -R StatusItems/ClockExtra/Clock.gsmenuextra /System/Library/MenuExtras/ || true; \
			cp -R StatusItems/BatteryExtra/Battery.gsmenuextra /System/Library/Menu/StatusItems/ || true; \
			cp -R StatusItems/BatteryExtra/Battery.gsmenuextra /System/Library/MenuExtras/ || true; \
			cp -R StatusItems/WLANExtra/WLAN.gsmenuextra /System/Library/Menu/StatusItems/ || true; \
			cp -R StatusItems/WLANExtra/WLAN.gsmenuextra /System/Library/MenuExtras/ || true; \
			cp -R StatusItems/SoundExtra/Sound.gsmenuextra /System/Library/Menu/StatusItems/ || true; \
			cp -R StatusItems/SoundExtra/Sound.gsmenuextra /System/Library/MenuExtras/ || true; \
			cp -R StatusItems/BrightnessExtra/Brightness.gsmenuextra /System/Library/Menu/StatusItems/ || true; \
			cp -R StatusItems/BrightnessExtra/Brightness.gsmenuextra /System/Library/MenuExtras/ || true; \
	fi
# Override uninstall target to properly support DESTDIR and PREFIX
uninstall:: custom-uninstall

custom-uninstall:
	@if [ -n "$(DESTDIR)" ]; then \
		echo "Uninstalling $(APP_NAME) from $(DESTDIR)$(INSTALL_APPS_DIR)"; \
		rm -rf $(DESTDIR)$(INSTALL_APPS_DIR)/$(APP_NAME).app; \
	else \
		echo "Uninstalling $(APP_NAME) from $(INSTALL_APPS_DIR)"; \
		rm -rf $(INSTALL_APPS_DIR)/$(APP_NAME).app; \
	fi

include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TOOL_NAME = make_appimage
make_appimage_OBJC_FILES = main.m AppImageBuilder.m LibraryResolver.m InterpreterDeployer.m LibraryDeployer.m
make_appimage_TOOL_LIBS = -lgnustep-base -lobjc

ADDITIONAL_OBJCFLAGS = -Wall -Wextra -fobjc-arc

include $(GNUSTEP_MAKEFILES)/tool.make

# Precompile a static AppRun binary that is shared by all AppImages.
# AppRun reads its app-specific settings from AppRun.plist, so it
# does not need to be regenerated per application — the make_appimage
# tool only writes AppRun.plist and copies the precompiled binary.
before-install:: AppRun
	@true

AppRun: AppRun.c
	@echo "  Compiling static AppRun..."
	@$(CC) -static -Os -Wall -Wno-format-truncation -o AppRun AppRun.c

install::
	@if [ -f AppRun ]; then \
		cp AppRun $(GNUSTEP_SYSTEM_TOOLS)/AppRun; \
		echo "Installed AppRun to $(GNUSTEP_SYSTEM_TOOLS)/AppRun"; \
	fi

clean::
	rm -f AppRun

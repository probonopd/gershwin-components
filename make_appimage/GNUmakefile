include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

COMMON_OBJC_FILES = AppImageBuilder.m LibraryResolver.m InterpreterDeployer.m LibraryDeployer.m
COMMON_TOOL_LIBS = -lgnustep-base -lobjc

TOOL_NAME = make_appimage make_standalone

make_appimage_OBJC_FILES = main.m $(COMMON_OBJC_FILES)
make_appimage_TOOL_LIBS = $(COMMON_TOOL_LIBS)

make_standalone_OBJC_FILES = main_standalone.m $(COMMON_OBJC_FILES)
make_standalone_TOOL_LIBS = $(COMMON_TOOL_LIBS)

ADDITIONAL_OBJCFLAGS = -Wall -Wextra -fobjc-arc

include $(GNUSTEP_MAKEFILES)/tool.make

# Precompile a static AppRun binary that is shared by all AppImages
# and standalone bundles.
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

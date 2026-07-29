include $(GNUSTEP_MAKEFILES)/common.make

GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

TOOL_NAME = make_appimage
make_appimage_OBJC_FILES = main.m AppImageBuilder.m LibraryResolver.m InterpreterDeployer.m LibraryDeployer.m
make_appimage_TOOL_LIBS = -lgnustep-base -lobjc

ADDITIONAL_OBJCFLAGS = -Wall -Wextra -fobjc-arc

include $(GNUSTEP_MAKEFILES)/tool.make

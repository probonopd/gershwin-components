include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

FRAMEWORK_NAME = ItemFlow
VERSION = 1.0.0

ItemFlow_HEADER_FILES = ItemFlowView.h ItemFlow.h
ItemFlow_OBJC_FILES = ItemFlowView.m
ItemFlow_FRAMEWORKS_DEPEND_UPON = AppKit Foundation

# OpenGL support
ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-arc-exceptions
ADDITIONAL_LDFLAGS += -lGL -lGLU

include $(GNUSTEP_MAKEFILES)/framework.make


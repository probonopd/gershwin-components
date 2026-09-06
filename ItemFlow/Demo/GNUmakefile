include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

APP_NAME = ItemFlowDemo

ItemFlowDemo_OBJC_FILES = main.m AppDelegate.m
ItemFlowDemo_GUI_LIBS += -lItemFlow
ItemFlowDemo_RESOURCE_DIRS = 

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fobjc-arc-exceptions
ADDITIONAL_INCLUDE_DIRS += -I../../
ADDITIONAL_LIB_DIRS += -L../ItemFlow.framework
ADDITIONAL_LDFLAGS += -lGL -lGLU

include $(GNUSTEP_MAKEFILES)/application.make


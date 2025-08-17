# GNUmakefile for libDSStore

GNUSTEP_MAKEFILES = /usr/share/GNUstep/Makefiles
include $(GNUSTEP_MAKEFILES)/common.make

# Library
LIBRARY_NAME = libDSStore
libDSStore_OBJC_FILES = DSStore.m DSBuddyAllocator.m DSStoreEntry.m DSStoreCodecs.m SimpleColor.m
libDSStore_HEADER_FILES = DSStore.h DSBuddyAllocator.h DSStoreEntry.h DSStoreCodecs.h SimpleColor.h

# Command line tool  
TOOL_NAME = dsstore
dsstore_OBJC_FILES = dsstore.m
dsstore_TOOL_LIBS = -lDSStore
dsstore_LIB_DIRS = -L./obj

# Compiler flags
ADDITIONAL_OBJCFLAGS = -Wall -Wno-unused-parameter -Wno-unused-variable -O2 -std=gnu99
ADDITIONAL_LDFLAGS = -lgnustep-base -lgnustep-gui -lm

include $(GNUSTEP_MAKEFILES)/library.make
include $(GNUSTEP_MAKEFILES)/tool.make

include $(GNUSTEP_MAKEFILES)/common.make

# Wave-1 sources under test are compiled once into an internal convenience
# library. That library instance carries ARC; the test tools themselves must
# NOT use ARC because the ObjectTesting macros in Testing.h send explicit
# retain/release, which clang rejects in ARC translation units. Per-instance
# *_OBJCFLAGS is supported by gnustep-make (Instance/rules.make).
#
# The tools link the shared variant with an rpath into ./obj: gnustep-make's
# static-library link (-shared -static) is broken with the Debian toolchain
# here, and the archive-by-path trick therefore cannot be used.
LIBRARY_NAME = DUWave1TestSupport
VERSION = 0.1

DUWave1TestSupport_OBJC_FILES = \
    ../Sources/Models/DUStorageCapabilities.m \
    ../Sources/Models/DUStorageDevice.m \
    ../Sources/Models/DUStorageObject.m \
    ../Sources/Models/DUStorageVolume.m \
    ../Sources/Models/DUPartition.m \
    ../Sources/Models/DUPartitionLayout.m \
    ../Sources/Models/DUPartitionPlan.m \
    ../Sources/Utilities/DUErrors.m \
    ../Sources/Utilities/DUParsing.m \
    ../Sources/Models/DUDiskImage.m \
    ../Sources/Models/DUOpticalMedia.m \
    ../Sources/Models/DURAIDSet.m \
    ../Sources/Backend/DUMockStorageBackend.m \
    ../Sources/Backend/DUBackendFactory.m \
    ../Sources/Backend/DUStorageBackend.m \
    ../Sources/Backend/Libraries/DUBlkidLibrary.m \
    ../Sources/Backend/Libraries/DUMountLibrary.m \
    ../Sources/Backend/Libraries/DUExt2Library.m \
    ../Sources/Backend/Libraries/DUArchiveLibrary.m \
    ../Sources/Backend/Libraries/DUFdiskLibrary.m \
    ../Sources/Backend/Parsers/DUBlkidParser.m \
    ../Sources/Backend/Parsers/DUFreeBSDGEOMParser.m \
    ../Sources/Backend/Parsers/DULsblkParser.m \
    ../Sources/Backend/Parsers/DUNetBKSDisklabelParser.m \
    ../Sources/Backend/Parsers/DUOpenBSDDisklabelParser.m \
    ../Sources/Backend/Parsers/DUPartitionTableParser.m

DUWave1TestSupport_OBJCFLAGS = \
    -fobjc-arc -fobjc-arc-exceptions -fobjc-runtime=gnustep-2.0 -fblocks \
    -Wall -Wextra

TEST_TOOL_NAME = t_Parsing t_PartitionLayout t_Models t_MockBackend t_SHA256 t_Libraries

t_Parsing_OBJC_FILES = TestParsing.m
t_PartitionLayout_OBJC_FILES = TestPartitionLayout.m
t_Models_OBJC_FILES = TestModels.m
t_MockBackend_OBJC_FILES = TestMockBackend.m
t_SHA256_OBJC_FILES = TestSHA256.m ../Sources/Utilities/DUSHA256.m
t_Libraries_OBJC_FILES = TestLibraries.m

t_Parsing_OBJCFLAGS = -fobjc-runtime=gnustep-2.0 -fblocks -Wall -Wextra
t_PartitionLayout_OBJCFLAGS = -fobjc-runtime=gnustep-2.0 -fblocks -Wall -Wextra
t_Models_OBJCFLAGS = -fobjc-runtime=gnustep-2.0 -fblocks -Wall -Wextra
t_MockBackend_OBJCFLAGS = -fobjc-runtime=gnustep-2.0 -fblocks -Wall -Wextra
t_SHA256_OBJCFLAGS = -fobjc-runtime=gnustep-2.0 -fblocks -Wall -Wextra
t_Libraries_OBJCFLAGS = -fobjc-runtime=gnustep-2.0 -fblocks -Wall -Wextra

# Static archive by explicit path would be hermetic, but see above; the
# rpath keeps freshly linked binaries from picking up any installed copy.
t_Parsing_TOOL_LIBS = \
    -L$(CURDIR)/obj -lDUWave1TestSupport -lgnustep-base
t_PartitionLayout_TOOL_LIBS = \
    -L$(CURDIR)/obj -lDUWave1TestSupport -lgnustep-base
t_Models_TOOL_LIBS = \
    -L$(CURDIR)/obj -lDUWave1TestSupport -lgnustep-base
t_MockBackend_TOOL_LIBS = \
    -L$(CURDIR)/obj -lDUWave1TestSupport -lgnustep-base
t_Libraries_TOOL_LIBS = \
    -L$(CURDIR)/obj -lDUWave1TestSupport -lgnustep-base

# Mirror the main GNUmakefile's library detection so the wrappers compile
# against the real headers when present; without a header the stub build
# needs no extra flags or link libraries at all (t_Libraries passes in
# both configurations by design).
HAVE_LIBBLKID := $(shell test -f /usr/include/blkid/blkid.h && echo yes)
HAVE_LIBMOUNT := $(shell test -f /usr/include/libmount/libmount.h && echo yes)
HAVE_LIBEXT2FS := $(shell test -f /usr/include/ext2fs/ext2fs.h && echo yes)
HAVE_LIBFDISK := $(shell test -f /usr/include/libfdisk/libfdisk.h && echo yes)
HAVE_LIBARCHIVE := $(shell pkg-config --exists libarchive 2>/dev/null && echo yes)

ifneq ($(HAVE_LIBBLKID),)
DUWave1TestSupport_OBJCFLAGS += -DHAVE_LIBBLKID
ADDITIONAL_LDFLAGS += -lblkid
endif
ifneq ($(HAVE_LIBMOUNT),)
DUWave1TestSupport_OBJCFLAGS += -DHAVE_LIBMOUNT
ADDITIONAL_LDFLAGS += -lmount
endif
ifneq ($(HAVE_LIBEXT2FS),)
DUWave1TestSupport_OBJCFLAGS += -DHAVE_LIBEXT2FS
ADDITIONAL_LDFLAGS += -lext2fs -lcom_err
endif
ifneq ($(HAVE_LIBFDISK),)
DUWave1TestSupport_OBJCFLAGS += -DHAVE_LIBFDISK
ADDITIONAL_LDFLAGS += -lfdisk
endif
ifneq ($(HAVE_LIBARCHIVE),)
DUWave1TestSupport_OBJCFLAGS += -DHAVE_LIBARCHIVE
ADDITIONAL_LDFLAGS += -larchive
endif

ADDITIONAL_LDFLAGS += -Wl,-rpath,$(CURDIR)/obj

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework

ADDITIONAL_INCLUDE_DIRS += \
    -I../Sources \
    -I../Sources/Models \
    -I../Sources/Services \
    -I../Sources/Operations \
    -I../Sources/Utilities \
    -I../Sources/Backend \
    -I../Sources/Backend/Libraries \
    -I../Sources/Backend/Parsers

# Libraries build before tools in serial gnustep-make runs, which is what
# provides the archive the tools link against.
include $(GNUSTEP_MAKEFILES)/library.make
include $(GNUSTEP_MAKEFILES)/test-tool.make

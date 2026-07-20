include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = \
	test_gorm2txt \
	test_txt2gorm \
	test_roundtrip

test_gorm2txt_OBJC_FILES = test_gorm2txt.m
test_txt2gorm_OBJC_FILES = test_txt2gorm.m
test_roundtrip_OBJC_FILES = test_roundtrip.m

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES) -I$(GNUSTEP_MAKEFILES)/TestFramework

test_gorm2txt_OBJCFLAGS = -Wall
test_txt2gorm_OBJCFLAGS = -Wall
test_roundtrip_OBJCFLAGS = -Wall

ADDITIONAL_TOOL_LIBS += -lgnustep-base -lgnustep-gui

include $(GNUSTEP_MAKEFILES)/test-tool.make

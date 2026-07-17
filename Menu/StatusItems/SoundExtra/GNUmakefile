include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = Sound
BUNDLE_EXTENSION = .gsmenuextra

Sound_PRINCIPAL_CLASS = SoundExtra
Sound_OBJC_FILES = SoundExtra.m
Sound_RESOURCE_FILES = Info.plist

Sound_BUNDLE_LIBS += -lSoundBackend
ADDITIONAL_OBJCFLAGS += -I../.. -I../../../Sound -I/System/Library/Headers/SoundBackend

include $(GNUSTEP_MAKEFILES)/bundle.make

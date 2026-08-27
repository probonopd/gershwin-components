include $(GNUSTEP_MAKEFILES)/common.make

TEST_TOOL_NAME = t_License t_Backend t_ResourceProvider t_Manager t_EPUB_LCP t_RealLCP

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework

t_License_OBJC_FILES          = t_License.m
t_Backend_OBJC_FILES          = t_Backend.m
t_ResourceProvider_OBJC_FILES = t_ResourceProvider.m
t_Manager_OBJC_FILES          = t_Manager.m
t_EPUB_LCP_OBJC_FILES          = t_EPUB_LCP.m
t_RealLCP_OBJC_FILES            = t_RealLCP.m

-include GNUmakefile.preamble

include $(GNUSTEP_MAKEFILES)/test-tool.make

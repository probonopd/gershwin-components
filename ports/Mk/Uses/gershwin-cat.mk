# gershwin-cat.mk - Common definitions for Gershwin preference panes
#
# MAINTAINER: ports@FreeBSD.org

# Common settings for all Gershwin preference panes
GERSHWIN_VERSION?=	1.0
USES+=			gnustep
USE_GNUSTEP=		back build

# Default installation directory for preference panes
PREFPANE_INSTALL_DIR?=	${PREFIX}/System/Library/Bundles

# Common build environment
MAKE_ENV+=		GNUSTEP_SYSTEM_ROOT=/System \
			GNUSTEP_SYSTEM_LIBRARY=/System/Library \
			BUNDLE_EXTENSION=.prefPane

# Use clang19 as specified in instructions
CC=			clang19
OBJC=			clang19

# Compiler flags to fix all warnings
CFLAGS+=		-Wall -Wextra -Werror
OBJCFLAGS+=		-Wall -Wextra -Werror

# Common dependencies for preference panes
LIB_DEPENDS+=		libPreferencePanes.so:gnustep/gnustep-preferencepanes

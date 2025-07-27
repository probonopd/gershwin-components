# Feature:		gershwin
# Usage:		USES=gershwin
# 			USE_GERSHWIN=<component>
#
# 			Not specifying USE_GERSHWIN with USES=gershwin is an error.
#			
#			Components can be found in the GERSHWIN_MODULES list below.
#
# MAINTAINER:	ports@FreeBSD.org

.if !defined(_INCLUDE_USES_GERSHWIN_MK)
_INCLUDE_USES_GERSHWIN_MK=		yes
_USES_POST+=	gershwin
.endif

# Set up things after bsd.port.post.mk.
# This way ports can add things to USE_GERSHWIN even after bsd.port.pre.mk is
# included.
.if defined(_POSTMKINCLUDED) && !defined(_INCLUDE_USES_GERSHWIN_POST_MK)
_INCLUDE_USES_GERSHWIN_POST_MK=	yes

.  if !empty(gershwin_ARGS)
IGNORE=		USES=gershwin takes no arguments
.  endif

.  if !defined(USE_GERSHWIN)
IGNORE=		need to specify gershwin modules with USE_GERSHWIN
.  endif

# List of gershwin modules
GERSHWIN_MODULES=	preferencepanes \
			gnustep-system

# Register preference pane dependencies
preferencepanes_LIB_DEPENDS=	${PREFIX}/System/Library/Frameworks/PreferencePanes.framework/PreferencePanes:gnustep/gnustep-preferencepanes
gnustep-system_BUILD_DEPENDS=	${PREFIX}/System/GNUstep.conf:gnustep/gnustep-make

# Set GNUstep paths for Gershwin
GNUSTEP_SYSTEM_ROOT?=	/System
GNUSTEP_SYSTEM_LIBRARY=	${GNUSTEP_SYSTEM_ROOT}/Library
GNUSTEP_SYSTEM_MAKEFILES=	${GNUSTEP_SYSTEM_ROOT}/Library/Makefiles

# Add explicit GNUstep options
.  if defined(GNU_CONFIGURE)
CONFIGURE_ARGS+=--with-gnustep-system-root=${GNUSTEP_SYSTEM_ROOT}
.  endif

# Make environment for GNUstep builds
MAKE_ENV+=	GNUSTEP_SYSTEM_ROOT=${GNUSTEP_SYSTEM_ROOT} \
		GNUSTEP_SYSTEM_LIBRARY=${GNUSTEP_SYSTEM_LIBRARY} \
		GNUSTEP_MAKEFILES=${GNUSTEP_SYSTEM_MAKEFILES}

.  for _module in ${USE_GERSHWIN:M*\:both:C/\:.*//g}
.    if ${GERSHWIN_MODULES:M${_module}} == ""
IGNORE=		uses unknown Gershwin module ${_module}
.    endif
.    if defined(${_module:tu}_BUILD_DEPENDS)
BUILD_DEPENDS+=	${${_module:tu}_BUILD_DEPENDS}
.    endif
.    if defined(${_module:tu}_LIB_DEPENDS)
BUILD_DEPENDS+=	${${_module:tu}_LIB_DEPENDS}
RUN_DEPENDS+=	${${_module:tu}_LIB_DEPENDS}
.    endif
.    if defined(${_module:tu}_RUN_DEPENDS)
RUN_DEPENDS+=	${${_module:tu}_RUN_DEPENDS}
.    endif
.  endfor

.  for _module in ${USE_GERSHWIN:M*\:build:C/\:.*//g}
.    if ${GERSHWIN_MODULES:M${_module}} == ""
IGNORE=		uses unknown Gershwin module ${_module}
.    endif
.    if defined(${_module:tu}_BUILD_DEPENDS)
BUILD_DEPENDS+=	${${_module:tu}_BUILD_DEPENDS}
.    endif
.    if defined(${_module:tu}_LIB_DEPENDS)
BUILD_DEPENDS+=	${${_module:tu}_LIB_DEPENDS}
.    endif
.  endfor

.  for _module in ${USE_GERSHWIN:M*\:run:C/\:.*//g}
.    if ${GERSHWIN_MODULES:M${_module}} == ""
IGNORE=		uses unknown Gershwin module ${_module}
.    endif
.    if defined(${_module:tu}_LIB_DEPENDS)
RUN_DEPENDS+=	${${_module:tu}_LIB_DEPENDS}
.    endif
.    if defined(${_module:tu}_RUN_DEPENDS)
RUN_DEPENDS+=	${${_module:tu}_RUN_DEPENDS}
.    endif
.  endfor

.  for _module in ${USE_GERSHWIN:N*\:*}
.    if ${GERSHWIN_MODULES:M${_module}} == ""
IGNORE=		uses unknown Gershwin module ${_module}
.    endif
.    if defined(${_module:tu}_BUILD_DEPENDS)
BUILD_DEPENDS+=	${${_module:tu}_BUILD_DEPENDS}
.    endif
.    if defined(${_module:tu}_LIB_DEPENDS)
BUILD_DEPENDS+=	${${_module:tu}_LIB_DEPENDS}
RUN_DEPENDS+=	${${_module:tu}_LIB_DEPENDS}
.    endif
.    if defined(${_module:tu}_RUN_DEPENDS)
RUN_DEPENDS+=	${${_module:tu}_RUN_DEPENDS}
.    endif
.  endfor

.endif

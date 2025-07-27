PORTNAME=	gershwin-prefpanes
DISTVERSION=	main
CATEGORIES=	sysutils gnustep

MAINTAINER=	ports@FreeBSD.org
COMMENT=	GNUstep preference pane for managing ZFS boot environments
WWW=		https://github.com/probonopd/gershwin-prefpanes

LICENSE=	BSD2CLAUSE

xxxUSES=		gershwin
xxxUSE_GERSHWIN=	preferencepanes

WRKSRC=		${WRKDIR}/gershwin-prefpanes-main/BootEnvironments

USE_GITHUB=	yes
GH_ACCOUNT=	probonopd
GH_PROJECT=	gershwin-prefpanes
GH_TAGNAME=	main

BUILD_WRKSRC=	${WRKSRC}
INSTALL_WRKSRC=	${WRKSRC}

PLIST_FILES=	System/Library/Bundles/BootEnvironments.prefPane/BootEnvironments \
		System/Library/Bundles/BootEnvironments.prefPane/Resources/BootEnvironments.png \
		System/Library/Bundles/BootEnvironments.prefPane/Resources/BootEnvironmentsInfo.plist \
		System/Library/Bundles/BootEnvironments.prefPane/stamp.make

PLIST_DIRS=	System/Library/Bundles/BootEnvironments.prefPane/Resources \
		System/Library/Bundles/BootEnvironments.prefPane

BUILD_DEPENDS=	tgmake:devel/gmake \
		gnustep-base>=0:lang/gnustep-base \
		gnustep-gui>=0:x11-toolkits/gnustep-gui
RUN_DEPENDS=	bectl:sysutils/beadm

.include <bsd.port.pre.mk>

# Ensure we use the system GNUstep installation at /System
GNUSTEP_SYSTEM_ROOT=	/System

do-build:
	cd ${BUILD_WRKSRC} && ${SETENV} ${MAKE_ENV} gmake

do-install:
	cd ${INSTALL_WRKSRC} && ${SETENV} ${MAKE_ENV} DESTDIR=${STAGEDIR} gmake install

.include <bsd.port.post.mk>
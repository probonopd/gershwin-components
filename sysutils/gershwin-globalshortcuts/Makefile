PORTNAME=	gershwin-globalshortcuts
PORTVERSION=	1.0
CATEGORIES=	sysutils gnustep x11

MAINTAINER=	ports@FreeBSD.org
COMMENT=	GNUstep preference pane and daemon for global keyboard shortcuts
WWW=		https://github.com/probonopd/gershwin-prefpanes

LICENSE=	BSD2CLAUSE

USES=		gershwin
USE_GERSHWIN=	preferencepanes
USE_XORG=	x11

USE_GITHUB=	yes
GH_ACCOUNT=	probonopd
GH_PROJECT=	gershwin-prefpanes

BUILD_WRKSRC=	${WRKDIR}/${DISTNAME}
INSTALL_WRKSRC=	${WRKDIR}/${DISTNAME}

PLIST_FILES=	System/Library/Bundles/GlobalShortcuts.prefPane/GlobalShortcuts \
		System/Library/Bundles/GlobalShortcuts.prefPane/Resources/GlobalShortcuts.png \
		System/Library/Bundles/GlobalShortcuts.prefPane/Resources/GlobalShortcutsInfo.plist \
		System/Library/Bundles/GlobalShortcuts.prefPane/stamp.make \
		bin/globalshortcutsd \
		share/doc/globalshortcutsd/README.md

PLIST_DIRS=	System/Library/Bundles/GlobalShortcuts.prefPane/Resources \
		System/Library/Bundles/GlobalShortcuts.prefPane \
		share/doc/globalshortcutsd

USE_RC_SUBR=	globalshortcutsd

.include <bsd.port.pre.mk>

# Ensure we use the system GNUstep installation at /System
GNUSTEP_SYSTEM_ROOT=	/System

do-build:
	cd ${BUILD_WRKSRC}/GlobalShortcuts && ${SETENV} ${MAKE_ENV} gmake
	cd ${BUILD_WRKSRC}/globalshortcutsd && ${SETENV} ${MAKE_ENV} CC=clang19 OBJC=clang19 gmake

do-install:
	cd ${BUILD_WRKSRC}/GlobalShortcuts && ${SETENV} ${MAKE_ENV} DESTDIR=${STAGEDIR} gmake install
	cd ${BUILD_WRKSRC}/globalshortcutsd && ${SETENV} ${MAKE_ENV} DESTDIR=${STAGEDIR} PREFIX=${PREFIX} gmake install-daemon

.include <bsd.port.post.mk>

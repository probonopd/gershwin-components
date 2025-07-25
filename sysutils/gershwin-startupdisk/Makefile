PORTNAME=	gershwin-startupdisk
PORTVERSION=	1.0
CATEGORIES=	sysutils gnustep

MAINTAINER=	ports@FreeBSD.org
COMMENT=	GNUstep preference pane for managing startup disk selection
WWW=		https://github.com/probonopd/gershwin-prefpanes

LICENSE=	BSD2CLAUSE

USES=		gershwin
USE_GERSHWIN=	preferencepanes

WRKSRC=		${WRKDIR}/${DISTNAME}/StartupDisk

USE_GITHUB=	yes
GH_ACCOUNT=	probonopd
GH_PROJECT=	gershwin-prefpanes

BUILD_WRKSRC=	${WRKSRC}
INSTALL_WRKSRC=	${WRKSRC}

PLIST_FILES=	System/Library/Bundles/StartupDisk.prefPane/StartupDisk \
		System/Library/Bundles/StartupDisk.prefPane/Resources/StartupDisk.png \
		System/Library/Bundles/StartupDisk.prefPane/Resources/StartupDiskInfo.plist \
		System/Library/Bundles/StartupDisk.prefPane/Resources/efiboot-helper \
		System/Library/Bundles/StartupDisk.prefPane/stamp.make

PLIST_DIRS=	System/Library/Bundles/StartupDisk.prefPane/Resources \
		System/Library/Bundles/StartupDisk.prefPane

RUN_DEPENDS=	efibootmgr:sysutils/efibootmgr

# Need to build the efiboot-helper first
pre-build:
	cd ${WRKSRC} && ${SETENV} ${MAKE_ENV} CC=clang19 gmake -f Makefile.helper

.include <bsd.port.pre.mk>

# Ensure we use the system GNUstep installation at /System
GNUSTEP_SYSTEM_ROOT=	/System

do-build:
	cd ${BUILD_WRKSRC} && ${SETENV} ${MAKE_ENV} gmake

do-install:
	cd ${INSTALL_WRKSRC} && ${SETENV} ${MAKE_ENV} DESTDIR=${STAGEDIR} gmake install

.include <bsd.port.post.mk>

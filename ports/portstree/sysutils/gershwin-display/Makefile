PORTNAME=	gershwin-display
DISTVERSION=	0.0.s${SNAPDATE}
CATEGORIES=	sysutils gnustep x11

MAINTAINER=	ports@FreeBSD.org
COMMENT=	GNUstep preference pane for display and monitor configuration
WWW=		https://github.com/probonopd/gershwin-prefpanes

LICENSE=	BSD2CLAUSE

USES=		gershwin
USE_GERSHWIN=	preferencepanes
USE_XORG=	xrandr

WRKSRC=		${WRKDIR}/gershwin-prefpanes-main/Display

USE_GITHUB=	yes
GH_ACCOUNT=	probonopd
GH_PROJECT=	gershwin-prefpanes
GH_TAGNAME=	main

BUILD_WRKSRC=	${WRKSRC}
INSTALL_WRKSRC=	${WRKSRC}

RUN_DEPENDS=	xrandr:x11/xrandr

.include <bsd.port.pre.mk>

do-build:
	cd ${BUILD_WRKSRC} && . /System/Library/Makefiles/GNUstep.sh && gmake

do-stage:
	cd ${BUILD_WRKSRC} && . /System/Library/Makefiles/GNUstep.sh && gmake DESTDIR=${STAGEDIR} install

.include <bsd.port.post.mk>
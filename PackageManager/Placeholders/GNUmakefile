GNUSTEP_INSTALLATION_DOMAIN = SYSTEM
# Placeholder wrapper apps organized by category
#
# Source: <Category>/<SafeName>/Resources/{Info.plist,Install.plist,<SafeName>.png}
# Build:  <Category>/<SafeName>.app/
# Install: /System/Applications/<Category>/<DisplayName>.app/

# Category build template: $(call make-category,safe_key,display_name,app_list)
define make-category
# $(1) = safe key (e.g. "3D_Printing")
# $(2) = display name (e.g. "3D Printing")
# $(3) = space-separated app names (e.g. "FreeCAD PrusaSlicer ...")

.PHONY: $(1)
$(1):
	@cat="$(2)"; \
	for app in $(3); do \
	  dname=$$$$(echo "$$$$app" | tr '_' ' '); \
	  bdir="$$$$cat/$$$$app.app"; \
	  sdir="$$$$cat/$$$$app"; \
	  mkdir -p "$$$$bdir/Resources"; \
	  [ -f "$$$$sdir/Resources/Info.plist" ] && cp "$$$$sdir/Resources/Info.plist" "$$$$bdir/Resources/"; \
	  [ -f "$$$$sdir/Resources/Install.plist" ] && cp "$$$$sdir/Resources/Install.plist" "$$$$bdir/Resources/"; \
	  [ -f "$$$$sdir/Resources/$$$$app.png" ] && cp "$$$$sdir/Resources/$$$$app.png" "$$$$bdir/Resources/"; \
	  ln -sf ../../../OnDemand/OnDemand.app/OnDemand "$$$$bdir/$$$$app"; \
	done

clean::
	@cat="$(2)"; \
	for app in $(3); do \
	  rm -rf "$$$$cat/$$$$app.app"; \
	done
endef

# Do not invoke sudo unconditionally. Image builds and CI run as root, and a
# stock FreeBSD/OpenBSD install has no sudo at all, so this died with
# "sudo: not found" (exit 127). Empty when already root or when sudo is
# missing; otherwise "sudo". Mirrors the guard in OnDemand/GNUmakefile.
SUDO := $(shell if [ "$$(id -u)" = "0" ]; then echo ""; \
	elif command -v sudo >/dev/null 2>&1; then echo "sudo"; \
	else echo ""; fi)

# Install template
define make-install
.PHONY: install-$(1)
install-$(1): $(1)
	@cat="$(2)"; \
	for app in $(3); do \
	  dname=$$$$(echo "$$$$app" | tr '_' ' '); \
	  bdir="$$$$cat/$$$$app.app"; \
	  instdir="/System/Applications/$$$$cat/$$$$dname.app"; \
	  $(SUDO) mkdir -p "$$$$instdir/Resources"; \
	  $(SUDO) cp "$$$$bdir/Resources/"* "$$$$instdir/Resources/"; \
	  $(SUDO) ln -sf /System/Applications/Utilities/OnDemand.app/OnDemand "$$$$instdir/$$$$dname"; \
	done
endef

# --- Category definitions ---
$(eval $(call make-category,3D_Printing,3D Printing,FreeCAD PrusaSlicer Ultimaker_Cura))
$(eval $(call make-category,Audio,Audio,Audacious Audacity LMMS MuseScore))
$(eval $(call make-category,Developer,Developer,Zeal))
$(eval $(call make-category,Graphics,Graphics,Blender GIMP Inkscape Krita Scribus Skanlite))
$(eval $(call make-category,Internet,Internet,Chromium Firefox Thunderbird Transmission))
$(eval $(call make-category,Office,Office,LibreOffice))
$(eval $(call make-category,Video,Video,OBS_Studio Shotcut))

# --- Install definitions ---
$(eval $(call make-install,3D_Printing,3D Printing,FreeCAD PrusaSlicer Ultimaker_Cura))
$(eval $(call make-install,Audio,Audio,Audacious Audacity LMMS MuseScore))
$(eval $(call make-install,Developer,Developer,Zeal))
$(eval $(call make-install,Graphics,Graphics,Blender GIMP Inkscape Krita Scribus Skanlite))
$(eval $(call make-install,Internet,Internet,Chromium Firefox Thunderbird Transmission))
$(eval $(call make-install,Office,Office,LibreOffice))
$(eval $(call make-install,Video,Video,OBS_Studio Shotcut))

# --- Aggregate targets ---
CATS = 3D_Printing Audio Developer Graphics Internet Office Video

.PHONY: all
all: $(CATS)

.PHONY: system-install
system-install: $(addprefix install-,$(CATS))


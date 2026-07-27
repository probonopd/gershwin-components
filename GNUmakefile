# Top-level (phony) GNUmakefile for gershwin-components
# This makefile is intentionally minimal and "phony". It simply dispatches
# common targets to all first-level subdirectories that contain a Makefile.
# Use this from the top of the gershwin-components tree.

# Ensure GNUstep tools (plmerge, etc.) are findable even under sudo,
# which sanitises PATH by default.
GNUSTEP_TOOLS_DIR := /System/Library/Tools
export PATH := $(GNUSTEP_TOOLS_DIR):$(PATH)

# Auto-detect first-level subdirectories that contain a Makefile, Makefile.in, or a configure script
SUBDIRS := $(sort $(shell for d in *; do \
	[ -d "$${d}" ] && [ "$$(readlink "$${d}")" != "." ] && \
	! [ -f "$${d}/.DISABLED" ] && \
	( [ -f "$${d}/GNUmakefile" ] || [ -f "$${d}/Makefile" ] || [ -f "$${d}/Makefile.in" ] || [ -x "$${d}/configure" ] || [ -f "$${d}/configure" ] ) && echo "$${d}"; \
	done))

.PHONY: all build clean install distclean help

all: build

# Components that link against the shared backend libraries must wait until
# Libraries have been installed.  During "gmake" (build only) we skip them
# because /System may not contain the libraries yet.  "sudo gmake install"
# installs Libraries first, then builds and installs these consumers.
ifneq ($(filter Libraries,$(SUBDIRS)),)
LIBRARY_CONSUMERS := $(filter Menu Network Sound Whisper,$(SUBDIRS))
else
LIBRARY_CONSUMERS :=
endif

NON_CONSUMERS := $(filter-out $(LIBRARY_CONSUMERS),$(SUBDIRS))

# Build: compile Libraries and everything that does not need them.
# Consumers (Menu, Network, Sound) are built during "gmake install" after
# Libraries have been placed in /System.
build: $(NON_CONSUMERS)
	@echo "Build completed for all components."

run_configure = echo "Preparing $(1) (running configure)"; ( cd $(1) && if command -v confiture >/dev/null 2>&1; then confiture || true; elif [ -x ./configure ]; then ./configure || true; elif [ -f configure ]; then sh configure || true; elif command -v autoreconf >/dev/null 2>&1; then autoreconf -i && ./configure || true; else echo "No configure tool found in $(1); skipping configure"; fi )

# For each subdir, if a Makefile.in or GNUmakefile.in exists and the generated
# Makefile/GNUmakefile is missing or older, run configure.
$(NON_CONSUMERS):
	@echo "Entering $@";
	@if ( [ -f "$@/Makefile.in" ] && ( [ ! -f "$@/Makefile" ] || [ "$@/Makefile.in" -nt "$@/Makefile" ] ) ) || \
	   ( [ -f "$@/GNUmakefile.in" ] && ( [ ! -f "$@/GNUmakefile" ] || [ "$@/GNUmakefile.in" -nt "$@/GNUmakefile" ] ) ); then \
		$(call run_configure,$@); \
	fi; \
	$(MAKE) -C $@;
	@echo "Leaving $@"

# Clean every subdir (non-fatal)
clean:
	@for d in $(SUBDIRS); do \
		if ( [ -f "$${d}/Makefile.in" ] && ( [ ! -f "$${d}/Makefile" ] || [ "$${d}/Makefile.in" -nt "$${d}/Makefile" ] ) ) || \
		   ( [ -f "$${d}/GNUmakefile.in" ] && ( [ ! -f "$${d}/GNUmakefile" ] || [ "$${d}/GNUmakefile.in" -nt "$${d}/GNUmakefile" ] ) ); then \
			$(call run_configure,$$$$d); \
		fi; \
		if [ -f "$${d}/Makefile" -o -f "$${d}/GNUmakefile" ]; then \
			echo "Cleaning $$d"; $(MAKE) -C $$d clean || true; \
		fi; \
	done

# Distclean: deeper clean if subdirs provide it
distclean: clean
	@for d in $(SUBDIRS); do \
		if ( [ -f "$${d}/Makefile.in" ] && ( [ ! -f "$${d}/Makefile" ] || [ "$${d}/Makefile.in" -nt "$${d}/Makefile" ] ) ) || \
		   ( [ -f "$${d}/GNUmakefile.in" ] && ( [ ! -f "$${d}/GNUmakefile" ] || [ "$${d}/GNUmakefile.in" -nt "$${d}/GNUmakefile" ] ) ); then \
			$(call run_configure,$$$$d); \
		fi; \
		if [ -f "$${d}/Makefile" -o -f "$${d}/GNUmakefile" ]; then \
			echo "Distclean $$d"; $(MAKE) -C $$d distclean || true; \
		fi; \
	done

# Install: Libraries first (so consumers can link), then everything else.
# For library consumers we also run their build step during install because
# they could not be compiled during "gmake" (no Libraries in /System yet).
install:
	@# Phase 1: install Libraries so consumers can find headers and .so files
	@if [ -d "Libraries" ] && [ -f "Libraries/GNUmakefile" ]; then \
		echo "Installing Libraries..."; \
		if ( [ -f "Libraries/Makefile.in" ] && ( [ ! -f "Libraries/Makefile" ] || [ "Libraries/Makefile.in" -nt "Libraries/Makefile" ] ) ) || \
		   ( [ -f "Libraries/GNUmakefile.in" ] && ( [ ! -f "Libraries/GNUmakefile" ] || [ "Libraries/GNUmakefile.in" -nt "Libraries/GNUmakefile" ] ) ); then \
			$(call run_configure,Libraries); \
		fi; \
		$(MAKE) -C Libraries install; \
	fi
	@# Phase 2: install everything else
	@for d in $(filter-out Libraries,$(SUBDIRS)); do \
		if ( [ -f "$${d}/Makefile.in" ] && ( [ ! -f "$${d}/Makefile" ] || [ "$${d}/Makefile.in" -nt "$${d}/Makefile" ] ) ) || \
		   ( [ -f "$${d}/GNUmakefile.in" ] && ( [ ! -f "$${d}/GNUmakefile" ] || [ "$${d}/GNUmakefile.in" -nt "$${d}/GNUmakefile" ] ) ); then \
			$(call run_configure,$$$$d); \
		fi; \
		if [ -f "$${d}/Makefile" -o -f "$${d}/GNUmakefile" ]; then \
			echo "Installing $$d"; \
			if ! $(MAKE) -C $$d install; then \
				echo "ERROR: install failed for $$d" >&2; \
				failed="$$failed $$d"; \
			fi; \
		fi; \
	done; \
	if [ -n "$$failed" ]; then \
		echo "" >&2; \
		echo "ERROR: the following components failed to install:$$failed" >&2; \
		exit 1; \
	fi

help:
	@echo "Top-level GNUmakefile for gershwin-components"; \
	echo "Available subdirectories:"; \
	printf '  %s\n' $(SUBDIRS); \
	echo "Targets: all (default), build, clean, distclean, install, help"

# Top-level (phony) GNUmakefile for gershwin-components
# This makefile is intentionally minimal and "phony". It simply dispatches
# common targets to all first-level subdirectories that contain a Makefile.
# Use this from the top of the gershwin-components tree.

# Auto-detect first-level subdirectories that contain a Makefile, Makefile.in, or a configure script
SUBDIRS := $(sort $(shell for d in *; do \
	[ -d "$${d}" ] && [ "$$(readlink "$${d}")" != "." ] && \
	! [ -f "$${d}/.DISABLED" ] && \
	( [ -f "$${d}/GNUmakefile" ] || [ -f "$${d}/Makefile" ] || [ -f "$${d}/Makefile.in" ] || [ -x "$${d}/configure" ] || [ -f "$${d}/configure" ] ) && echo "$${d}"; \
	done))

.PHONY: all build clean install distclean help $(SUBDIRS)

all: build

# Components that link against the shared backend libraries must wait until the
# Libraries aggregate target has built and installed those dependencies.
ifneq ($(filter Libraries,$(SUBDIRS)),)
LIBRARY_CONSUMERS := $(filter Menu Network Sound,$(SUBDIRS))
$(LIBRARY_CONSUMERS): Libraries
endif

# Build each subdirectory
build: $(SUBDIRS)
	@echo "Build completed for all components."

run_configure = echo "Preparing $(1) (running configure)"; ( cd $(1) && if command -v confiture >/dev/null 2>&1; then confiture || true; elif [ -x ./configure ]; then ./configure || true; elif [ -f configure ]; then sh configure || true; elif command -v autoreconf >/dev/null 2>&1; then autoreconf -i && ./configure || true; else echo "No configure tool found in $(1); skipping configure"; fi )

# For each subdir, if a Makefile.in or GNUmakefile.in exists and the generated
# Makefile/GNUmakefile is missing or older, run configure.
$(SUBDIRS):
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
distclean:
	@for d in $(SUBDIRS); do \
		if ( [ -f "$${d}/Makefile.in" ] && ( [ ! -f "$${d}/Makefile" ] || [ "$${d}/Makefile.in" -nt "$${d}/Makefile" ] ) ) || \
		   ( [ -f "$${d}/GNUmakefile.in" ] && ( [ ! -f "$${d}/GNUmakefile" ] || [ "$${d}/GNUmakefile.in" -nt "$${d}/GNUmakefile" ] ) ); then \
			$(call run_configure,$$$$d); \
		fi; \
		if [ -f "$${d}/Makefile" -o -f "$${d}/GNUmakefile" ]; then \
			echo "Distclean $$d"; $(MAKE) -C $$d distclean || true; \
		fi; \
	done

install:
	@for d in $(SUBDIRS); do \
		if ( [ -f "$${d}/Makefile.in" ] && ( [ ! -f "$${d}/Makefile" ] || [ "$${d}/Makefile.in" -nt "$${d}/Makefile" ] ) ) || \
		   ( [ -f "$${d}/GNUmakefile.in" ] && ( [ ! -f "$${d}/GNUmakefile" ] || [ "$${d}/GNUmakefile.in" -nt "$${d}/GNUmakefile" ] ) ); then \
			$(call run_configure,$$$$d); \
		fi; \
		if [ -f "$${d}/Makefile" -o -f "$${d}/GNUmakefile" ]; then \
			echo "Installing $$d"; $(MAKE) -C $$d install || true; \
		fi; \
	done

help:
	@echo "Top-level GNUmakefile for gershwin-components"; \
	echo "Available subdirectories:"; \
	printf '  %s\n' $(SUBDIRS); \
	echo "Targets: all (default), build, clean, distclean, install, help"

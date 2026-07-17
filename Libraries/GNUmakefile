# Top-level GNUmakefile for Libraries
# Builds and installs shared backend libraries so dependent components can
# link against headers and libraries from the canonical system locations.

SUBDIRS := $(sort $(shell for d in *; do \
	[ -d "$${d}" ] && ! [ -f "$${d}/.DISABLED" ] && \
	[ -f "$${d}/GNUmakefile" ] && echo "$${d}"; \
	done))

.PHONY: all build clean distclean install $(SUBDIRS)

all: build

$(SUBDIRS):
	@echo "Building and installing $@..."
	$(MAKE) -C $@ install
	@echo "$@ done."

build: $(SUBDIRS)
	@echo "All libraries built and installed."

clean:
	@for d in $(SUBDIRS); do \
		echo "Cleaning $$d"; \
		$(MAKE) -C $$d clean; \
	done
	@echo "All libraries cleaned."

distclean: clean
	@for d in $(SUBDIRS); do \
		if [ -f "$${d}/GNUmakefile" ]; then \
			$(MAKE) -C $$d distclean; \
		fi; \
	done

install: build
	@echo "All libraries installed."

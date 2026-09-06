GNUSTEP_INSTALLATION_DOMAIN = SYSTEM
# Top-level GNUmakefile for Assistants
# 1. Builds AssistantFramework (without installing)
# 2. Builds each subfolder that has a GNUmakefile and no .DISABLED
# 3. Install phase handles actual installation
# Error codes are propagated (no || true).

SUBDIRS := $(sort $(shell for d in *; do \
	[ -d "$${d}" ] && [ "$${d}" != "AssistantFramework" ] && \
	! [ -f "$${d}/.DISABLED" ] && \
	[ -f "$${d}/GNUmakefile" ] && echo "$${d}"; \
	done))

.PHONY: all build framework install $(SUBDIRS)

all: build

framework:
	@echo "Building AssistantFramework..."
	$(MAKE) -C AssistantFramework
	@echo "AssistantFramework built."

$(SUBDIRS): framework
	@echo "Building $@..."
	$(MAKE) -C $@ all
	@echo "$@ done."

build: framework $(SUBDIRS)
	@echo "All assistants built."

clean:
	@for d in AssistantFramework $(SUBDIRS); do \
		echo "Cleaning $$d"; \
		$(MAKE) -C $$d clean; \
	done
	@echo "All assistants cleaned."

distclean: clean
	@for d in AssistantFramework $(SUBDIRS); do \
		if [ -f "$${d}/GNUmakefile" ]; then \
			$(MAKE) -C $$d distclean; \
		fi; \
	done

install:
	@echo "Installing AssistantFramework..."
	$(MAKE) -C AssistantFramework install
	@for d in $(SUBDIRS); do \
		echo "Installing $$d..."; \
		$(MAKE) -C $$d install; \
	done
	@echo "All assistants installed."


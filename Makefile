# port-watch
#
# Building needs the Vyto compiler. Point at it however suits you:
#
#     make                          # vytoc on PATH, or $VYTO_HOME/vytoc
#     make VYTOC=/path/to/vytoc     # an explicit binary
#     make VYTO_ROOT=~/vyto         # a voltlang checkout holding ./vytoc
#
# MODPATH is the package root this repo sits in. A root CONTAINS packages, so
# it is the parent directory, not this one — the same shape as lib/ holding
# vyto/. Derived from this file's location, so moving the checkout needs no
# edit.

MODPATH   ?= $(realpath ..)
PREFIX    ?= $(HOME)/.local
DESTDIR   ?=

ifdef VYTO_ROOT
VYTOC     ?= $(VYTO_ROOT)/vytoc
else ifdef VYTO_HOME
VYTOC     ?= $(VYTO_HOME)/vytoc
else
VYTOC     ?= $(shell command -v vytoc 2>/dev/null)
endif

BIN = port-watch

SRC = src/main.vt src/procnet.vt src/sysproc.vt src/attribute.vt src/render.vt \
      src/native/src/proc_shim.c

all: $(BIN)

# Every build target depends on this, so a missing compiler is one clear
# message rather than "vytoc: command not found" repeated per file.
check-vytoc:
	@if [ -z "$(VYTOC)" ] || [ ! -x "$(VYTOC)" ]; then \
		echo "port-watch: cannot find the Vyto compiler."; \
		echo ""; \
		echo "  Install Vyto from https://github.com/vytolang/vyto, then either:"; \
		echo "    - put vytoc on your PATH"; \
		echo "    - set VYTO_HOME to the install root"; \
		echo "    - build here with: make VYTO_ROOT=/path/to/vyto-checkout"; \
		echo "    - or point straight at it: make VYTOC=/path/to/vytoc"; \
		exit 1; \
	fi

$(BIN): $(SRC) | check-vytoc
	$(VYTOC) build src/main.vt --modpath $(MODPATH) -o $@

# What a release is built with: optimised, and from a cleared cache so nothing
# stale can survive into a published artifact.
release: check-vytoc clean-cache
	$(VYTOC) build src/main.vt --modpath $(MODPATH) --release -o $(BIN)

test: all
	sh tests/run_tests.sh

install: release
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 $(BIN) $(DESTDIR)$(PREFIX)/bin/
	@echo "installed to $(DESTDIR)$(PREFIX)/bin/$(BIN)"

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/$(BIN)

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
PLATFORM ?= $(shell uname -s | tr A-Z a-z)-$(shell uname -m)
DISTNAME = port-watch-$(VERSION)-$(PLATFORM)

dist: release
	rm -rf dist/$(DISTNAME)
	mkdir -p dist/$(DISTNAME)
	cp $(BIN) README.md dist/$(DISTNAME)/
	cp LICENSE dist/$(DISTNAME)/ 2>/dev/null || true
	cd dist && tar czf $(DISTNAME).tar.gz $(DISTNAME)
	cd dist && sha256sum $(DISTNAME).tar.gz > $(DISTNAME).tar.gz.sha256
	cd dist && cp $(DISTNAME).tar.gz port-watch-$(PLATFORM).tar.gz
	cd dist && sha256sum port-watch-$(PLATFORM).tar.gz > port-watch-$(PLATFORM).tar.gz.sha256
	@echo "dist/$(DISTNAME).tar.gz"

# Emitted C and objects are cached per entry-file directory, and editing only a
# library .vt does not always invalidate it. Clear it before trusting a build.
clean-cache:
	find . -name .vyto-cache -type d -exec rm -rf {} + 2>/dev/null || true

clean: clean-cache
	rm -f $(BIN)
	rm -rf tests/tmp dist

.PHONY: all check-vytoc release test install uninstall dist clean clean-cache

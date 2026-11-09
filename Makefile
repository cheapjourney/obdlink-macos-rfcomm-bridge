BINARY := build/obdlink-rfcomm
SOURCES := $(wildcard Sources/obdlink-rfcomm/*.swift)
PREFIX ?= /usr/local
SWIFTC ?= swiftc

.PHONY: all build test clean install uninstall

all: build

build: $(BINARY)

$(BINARY): $(SOURCES)
	@mkdir -p build
	$(SWIFTC) -O $(SOURCES) -o $(BINARY)

test: $(BINARY)
	@./$(BINARY) --self-test

clean:
	@rm -rf build .build

install: $(BINARY)
	@install -d $(PREFIX)/bin
	@install -m 0755 $(BINARY) $(PREFIX)/bin/obdlink-rfcomm
	@echo "installed $(PREFIX)/bin/obdlink-rfcomm"

uninstall:
	@rm -f $(PREFIX)/bin/obdlink-rfcomm
	@echo "removed $(PREFIX)/bin/obdlink-rfcomm"

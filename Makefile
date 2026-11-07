BINARY := build/obdlink-rfcomm
SOURCE := Sources/obdlink-rfcomm/main.swift
PREFIX ?= /usr/local
SWIFTC ?= swiftc

.PHONY: all build test clean install uninstall

all: build

build: $(BINARY)

$(BINARY): $(SOURCE)
	@mkdir -p build
	$(SWIFTC) -O $(SOURCE) -o $(BINARY)

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

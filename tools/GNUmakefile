# ==============================================================================
# MicrOS (µOS) Substrate Tools GNUmakefile
# ==============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

# Configurable tools and compiler flags
ZIG ?= zig
SHELLCHECK ?= shellcheck
ZIGFLAGS ?= -ODebug

# Directories
BIN_DIR := bin
SRC_DIR := src
CACHE_DIR := .zig-cache

# Native Zig binaries
BINARIES := \
	$(BIN_DIR)/micros-fb-verify \
	$(BIN_DIR)/micros-lint \
	$(BIN_DIR)/micros-sym \
	$(BIN_DIR)/micros-telem

# Shell scripts
SCRIPTS := \
	micros-inspect.bash \
	micros-runner.bash \
	micros-spec-trace.bash

# Symlink launchers
SYMLINKS := \
	micros-inspect \
	micros-runner \
	micros-spec-trace \
	micros-fb-verify \
	micros-lint \
	micros-sym \
	micros-addr2line \
	micros-telem

# Default goal
.DEFAULT_GOAL := all

.PHONY: all clean test lint fmt fmt-check help

## all: Compile all native tool binaries and setup launcher symlinks
all: $(BINARIES) $(SYMLINKS)

$(BIN_DIR):
	mkdir -p $@

$(BIN_DIR)/micros-fb-verify: $(SRC_DIR)/fb_verify.zig | $(BIN_DIR)
	@echo "=> Compiling $@..."
	$(ZIG) build-exe $< $(ZIGFLAGS) -femit-bin=$@ --cache-dir $(CACHE_DIR)

$(BIN_DIR)/micros-%: $(SRC_DIR)/%.zig | $(BIN_DIR)
	@echo "=> Compiling $@..."
	$(ZIG) build-exe $< $(ZIGFLAGS) -femit-bin=$@ --cache-dir $(CACHE_DIR)

# Launcher symlinks
micros-inspect: micros-inspect.bash
	ln -sf $< $@

micros-runner: micros-runner.bash
	ln -sf $< $@

micros-spec-trace: micros-spec-trace.bash
	ln -sf $< $@

micros-fb-verify: $(BIN_DIR)/micros-fb-verify
	ln -sf $< $@

micros-lint: $(BIN_DIR)/micros-lint
	ln -sf $< $@

micros-sym: $(BIN_DIR)/micros-sym
	ln -sf $< $@

micros-addr2line: micros-sym
	ln -sf $< $@

micros-telem: $(BIN_DIR)/micros-telem
	ln -sf $< $@

## test: Execute unit and integration tests for tools
test: all
	@echo "=> Running tools test suite..."
	$(ZIG) test $(SRC_DIR)/lint.zig --cache-dir $(CACHE_DIR)
	$(ZIG) test $(SRC_DIR)/fb_verify.zig --cache-dir $(CACHE_DIR)
	$(ZIG) test $(SRC_DIR)/sym.zig --cache-dir $(CACHE_DIR)
	$(ZIG) test $(SRC_DIR)/telem.zig --cache-dir $(CACHE_DIR)
	./micros-spec-trace.bash --check
	@echo "=> Tools test suite passed."

## lint: Run shellcheck on scripts and micros-lint on tools source
lint: all
	@echo "=> Linting tool scripts..."
	@if command -v $(SHELLCHECK) >/dev/null 2>&1; then \
		$(SHELLCHECK) $(SCRIPTS); \
	else \
		echo "$(SHELLCHECK) not found, skipping bash linting"; \
	fi
	@echo "=> Linting tools source code..."
	./micros-lint $(SRC_DIR)

## fmt: Format Zig code in tools
fmt:
	@echo "=> Formatting tools Zig code..."
	$(ZIG) fmt $(SRC_DIR)/

## fmt-check: Verify Zig code formatting in tools
fmt-check:
	@echo "=> Checking tools Zig code formatting..."
	$(ZIG) fmt --check $(SRC_DIR)/

## clean: Remove tool binaries, caches, and binary symlinks
clean:
	@echo "=> Cleaning tools workspace..."
	rm -rf $(BIN_DIR) $(CACHE_DIR) micros-fb-verify micros-lint micros-sym micros-addr2line micros-telem
	@echo "=> Tools clean complete."

## help: Print this help message
help:
	@echo "MicrOS (µOS) Tools Build System"
	@echo "-------------------------------"
	@echo "Available targets:"
	@awk '/^## / { sub(/^## /, ""); split($$0, t, ": "); printf "  \033[36m%-15s\033[0m %s\n", t[1], t[2] }' $(MAKEFILE_LIST)

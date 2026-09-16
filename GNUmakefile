# ==============================================================================
# MicrOS (µOS) GNUmakefile
# ==============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

# Configurable tools
ZIG ?= zig

# Core paths
OUT_DIR := zig-out
CACHE_DIR := .zig-cache

# Default goal
.DEFAULT_GOAL := all

.PHONY: all clean test help run

## all: Compile the substrate toolchain and MicrOS Init binary
all:
	@echo "=> Building MicrOS (Phase 0)..."
	$(ZIG) build

## test: Execute the unit and integration test suite
test:
	@echo "=> Running tests..."
	$(ZIG) build test

## clean: Remove build artifacts and Zig caches
clean:
	@echo "=> Cleaning workspace..."
	rm -rf $(OUT_DIR) $(CACHE_DIR)
	@echo "=> Clean complete."

## run: Execute the sandbox (micros-init)
run: all
	@echo "=> Executing MicrOS Sandbox..."
	@./zig-out/bin/micros-init || true

## help: Print this help message
help:
	@echo "MicrOS (µOS) Build System"
	@echo "-------------------------"
	@echo "Available targets:"
	@awk '/^## / { sub(/^## /, ""); split($$0, t, ": "); printf "  \033[36m%-15s\033[0m %s\n", t[1], t[2] }' $(MAKEFILE_LIST)


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

.PHONY: all clean test help run tools fmt fmt-check lint spec-trace check

## all: Compile the substrate toolchain and MicrOS Init binary
all: tools
	@echo "=> Building MicrOS (Phase 0)..."
	$(ZIG) build

## test: Execute the unit and integration test suite
test:
	@echo "=> Running tests..."
	$(ZIG) build test
	$(MAKE) -C tools test

## clean: Remove build artifacts and Zig caches
clean:
	@echo "=> Cleaning workspace..."
	$(MAKE) -C tools clean
	rm -rf $(OUT_DIR) $(CACHE_DIR)
	@echo "=> Clean complete."

## run: Execute the sandbox (micros-init)
run: all
	@echo "=> Executing MicrOS Sandbox..."
	@./zig-out/bin/micros-init || true

## tools: Compile the substrate toolchain
tools:
	@echo "=> Building tools..."
	$(MAKE) -C tools

## fmt: Format Zig code
fmt:
	@echo "=> Formatting Zig code..."
	$(ZIG) fmt src/ build.zig
	$(MAKE) -C tools fmt

## fmt-check: Check Zig code formatting
fmt-check:
	@echo "=> Checking Zig code formatting..."
	$(ZIG) fmt --check src/ build.zig
	$(MAKE) -C tools fmt-check

## lint: Run micros-lint and shellcheck across workspace
lint: tools
	@echo "=> Linting codebase..."
	./tools/micros-lint src/
	$(MAKE) -C tools lint

## spec-trace: Verify 100% specification traceability
spec-trace:
	@echo "=> Running specification traceability auditor..."
	./tools/micros-spec-trace --check

## check: Run all verifications (test, lint, fmt-check, spec-trace)
check: test lint fmt-check spec-trace
	@echo "=> All checks passed successfully."

## help: Print this help message
help:
	@echo "MicrOS (µOS) Build System"
	@echo "-------------------------"
	@echo "Available targets:"
	@awk '/^## / { sub(/^## /, ""); split($$0, t, ": "); printf "  \033[36m%-15s\033[0m %s\n", t[1], t[2] }' $(MAKEFILE_LIST)

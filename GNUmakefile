# ==============================================================================
# MicrOS (µOS) GNUmakefile
# ==============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

# Configurable tools
ZIG ?= zig
AI_PROVIDER ?= gemini
AI_API_KEY ?= $(GEMINI_API_KEY)
AI_MODEL ?=
AI_ENDPOINT ?=
AI_PORT ?=
AI_USE_TLS ?=

ZIG_BUILD_FLAGS := $(if $(AI_PROVIDER),-Dai-provider="$(AI_PROVIDER)",) \
                   $(if $(AI_API_KEY),-Dai-api-key="$(AI_API_KEY)",) \
                   $(if $(AI_MODEL),-Dai-model="$(AI_MODEL)",) \
                   $(if $(AI_ENDPOINT),-Dai-endpoint="$(AI_ENDPOINT)",) \
                   $(if $(AI_PORT),-Dai-port=$(AI_PORT),) \
                   $(if $(AI_USE_TLS),-Dai-use-tls=$(AI_USE_TLS),)

# Core paths
OUT_DIR := zig-out
CACHE_DIR := .zig-cache

# Default goal
.DEFAULT_GOAL := all

.PHONY: all clean test help run run-msh qemu-msh uefi-boot qemu-uefi tools fmt fmt-check lint spec-trace check

## all: Compile the substrate toolchain and MicrOS Init binary
all: tools src/kernel/genesis.mcb
	@echo "=> Building MicrOS..."
	$(ZIG) build $(ZIG_BUILD_FLAGS)

src/kernel/genesis.mcb: lib/macros/harness.mx lib/macros/init.mx | tools
	@echo "=> Packaging Genesis MCB bundle..."
	./tools/micros-bundle $@ harness.mx=lib/macros/harness.mx init.mx=lib/macros/init.mx

## test: Execute the unit and integration test suite
test:
	@echo "=> Running tests..."
	$(ZIG) build test
	$(MAKE) -C tools test

## test-sandbox: Execute Phase 0 direct-syscall sandbox in QEMU/KVM
test-sandbox: all
	@echo "=> Running Phase 0 sandbox in QEMU/KVM..."
	./tools/micros-runner --mode sandbox

## test-qemu: Alias for test-sandbox
test-qemu: test-sandbox

## clean: Remove build artifacts, Zig caches, and ephemeral outputs
clean:
	@echo "=> Cleaning workspace..."
	$(MAKE) -C tools clean
	rm -rf $(OUT_DIR) $(CACHE_DIR) build docs/_build esp
	@echo "=> Clean complete."

## run: Execute the sandbox (micros-init)
run: all
	@echo "=> Executing MicrOS Sandbox..."
	@./zig-out/bin/micros-init || true

## run-msh: Execute the interactive MicroShell (msh) on host
run-msh: all
	@echo "=> Launching MicroShell (msh)..."
	@./zig-out/bin/msh || true

## uki: Build a Unified Kernel Image (UKI) PE/COFF executable (.efi)
uki: all
	@echo "=> Building Unified Kernel Image (UKI)..."
	@mkdir -p build/initramfs/dev build/initramfs/proc build/initramfs/sys build/initramfs/lib/macros
	@cp zig-out/bin/micros-init build/initramfs/init
	@cp zig-out/bin/msh build/initramfs/msh
	@cp lib/macros/*.mx build/initramfs/lib/macros/
	@(cd build/initramfs && find . | cpio -o -H newc --quiet) > build/initramfs.cpio
	@ukify build --linux "/boot/vmlinuz-$$(uname -r)" --initrd build/initramfs.cpio --cmdline "console=ttyS0 earlyprintk=serial,ttyS0 panic=1 rdinit=/init" --output build/micros-sandbox.efi
	@echo "=> UKI generated: build/micros-sandbox.efi"

## test-uki: Boot the Unified Kernel Image (UKI) via UEFI in QEMU/KVM
test-uki: uki
	@echo "=> Booting UKI via UEFI OVMF in QEMU/KVM..."
	@qemu-system-x86_64 -enable-kvm -cpu host -bios /usr/share/OVMF/OVMF_CODE.fd -kernel build/micros-sandbox.efi -serial stdio -display none -no-reboot -m 512M || true

## qemu-msh: Boot into interactive MicroShell inside QEMU/KVM
qemu-msh: all
	@echo "=> Booting into interactive MicroShell in QEMU/KVM..."
	@mkdir -p build/initramfs/dev build/initramfs/proc build/initramfs/sys build/initramfs/lib/macros
	@cp zig-out/bin/micros-init build/initramfs/init
	@cp zig-out/bin/msh build/initramfs/msh
	@cp lib/macros/*.mx build/initramfs/lib/macros/
	@(cd build/initramfs && find . | cpio -o -H newc --quiet) > build/initramfs.cpio
	@qemu-system-x86_64 -enable-kvm -cpu host -kernel "/boot/vmlinuz-$$(uname -r)" -initrd build/initramfs.cpio -append "console=ttyS0 quiet panic=1 rdinit=/msh" -serial stdio -display none -no-reboot -m 256M || true

## uefi-boot: Build bootable UEFI artifacts (boot.efi and genesis.mcb in build/esp)
uefi-boot: all
	@echo "=> Preparing UEFI boot artifacts in build/esp..."
	@mkdir -p build/esp/EFI/BOOT
	@cp zig-out/bin/boot.efi build/esp/EFI/BOOT/BOOTX64.EFI
	@cp src/kernel/genesis.mcb build/esp/genesis.mcb
	@echo "=> UEFI boot artifacts prepared successfully."

## qemu-uefi: Boot bare-metal MicrOS UEFI in QEMU with live display & serial
qemu-uefi: uefi-boot
	@echo "=> Booting MicrOS UEFI in QEMU with live display..."
	@qemu-system-x86_64 -enable-kvm -cpu host -m 512M \
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
		-drive format=raw,file=fat:rw:build/esp \
		-netdev user,id=net0 \
		-device virtio-net-pci,netdev=net0 \
		-serial stdio

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

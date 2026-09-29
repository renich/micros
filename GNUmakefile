# ==============================================================================
# MicrOS (µOS) GNUmakefile
# ==============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

# Configurable tools
ZIG ?= zig
-include .env
AI_PROVIDER ?= gemini
AI_API_KEY ?= $(or $(GEMINI_API_KEY),$(AI_KEY))
AI_MODEL ?=
AI_ENDPOINT ?=
AI_PORT ?=
AI_USE_TLS ?=

# The API key NEVER travels on argv (make echo, `ps`, zig error output all leak
# it). build.zig reads GEMINI_API_KEY/AI_API_KEY/AI_KEY from the environment.
export GEMINI_API_KEY AI_API_KEY AI_KEY
ZIG_BUILD_FLAGS := $(if $(AI_PROVIDER),-Dai-provider="$(AI_PROVIDER)",) \
                   $(if $(AI_MODEL),-Dai-model="$(AI_MODEL)",) \
                   $(if $(AI_ENDPOINT),-Dai-endpoint="$(AI_ENDPOINT)",) \
                   $(if $(AI_PORT),-Dai-port=$(AI_PORT),) \
                   $(if $(AI_USE_TLS),-Dai-use-tls=$(AI_USE_TLS),)

# Core paths
OUT_DIR := zig-out
CACHE_DIR := .zig-cache

# Default goal
.DEFAULT_GOAL := all

.PHONY: all clean test help run run-ush qemu-ush uefi-boot uefi-disk-image qemu-uefi qemu-cluster qemu-cluster-verify tools fmt fmt-check lint spec-trace check

## all: Compile the substrate toolchain and MicrOS Init binary
all: tools src/kernel/genesis.mcb
	@echo "=> Building MicrOS..."
	@$(ZIG) build $(ZIG_BUILD_FLAGS)

src/kernel/genesis.mcb: lib/macros/init.mx lib/macros/ush.mx lib/macros/lexer.mx lib/macros/parser.mx lib/macros/compiler.mx lib/macros/compiler_main.mx lib/macros/bundle.mx lib/macros/rebuild.mx lib/macros/ast.mx lib/macros/eval_shim.mx | tools
	@echo "=> Packaging Genesis MCB bundle..."
	./tools/micros-bundle $@ init.mx=lib/macros/init.mx ush.mx=lib/macros/ush.mx lexer.mx=lib/macros/lexer.mx parser.mx=lib/macros/parser.mx compiler.mx=lib/macros/compiler.mx compiler_main.mx=lib/macros/compiler_main.mx bundle.mx=lib/macros/bundle.mx rebuild.mx=lib/macros/rebuild.mx ast.mx=lib/macros/ast.mx eval_shim.mx=lib/macros/eval_shim.mx

## test: Execute the unit and integration test suite
test: src/kernel/genesis.mcb
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

## run-ush: Execute the interactive µShell (ush) on host
run-ush: all
	@echo "=> Launching µShell (ush)..."
	@./zig-out/bin/ush || true

## uki: Build a Unified Kernel Image (UKI) PE/COFF executable (.efi)
uki: all
	@echo "=> Building Unified Kernel Image (UKI)..."
	@mkdir -p build/initramfs/dev build/initramfs/proc build/initramfs/sys build/initramfs/lib/macros
	@cp zig-out/bin/micros-init build/initramfs/init
	@cp zig-out/bin/ush build/initramfs/ush
	@cp lib/macros/*.mx build/initramfs/lib/macros/
	@(cd build/initramfs && find . | cpio -o -H newc --quiet) > build/initramfs.cpio
	@ukify build --linux "/boot/vmlinuz-$$(uname -r)" --initrd build/initramfs.cpio --cmdline "console=ttyS0 earlyprintk=serial,ttyS0 panic=1 rdinit=/init" --output build/micros-sandbox.efi
	@echo "=> UKI generated: build/micros-sandbox.efi"

## test-uki: Boot the Unified Kernel Image (UKI) via UEFI in QEMU/KVM
test-uki: uki
	@echo "=> Booting UKI via UEFI OVMF in QEMU/KVM..."
	@qemu-system-x86_64 -enable-kvm -cpu host -bios /usr/share/OVMF/OVMF_CODE.fd -kernel build/micros-sandbox.efi -serial stdio -display none -no-reboot -m 512M || true

## qemu-ush: Boot into interactive µShell inside QEMU/KVM
qemu-ush: all
	@echo "=> Booting into interactive µShell in QEMU/KVM..."
	@mkdir -p build/initramfs/dev build/initramfs/proc build/initramfs/sys build/initramfs/lib/macros
	@cp zig-out/bin/micros-init build/initramfs/init
	@cp zig-out/bin/ush build/initramfs/ush
	@cp lib/macros/*.mx build/initramfs/lib/macros/
	@(cd build/initramfs && find . | cpio -o -H newc --quiet) > build/initramfs.cpio
	@qemu-system-x86_64 -enable-kvm -cpu host -kernel "/boot/vmlinuz-$$(uname -r)" -initrd build/initramfs.cpio -append "console=ttyS0 quiet panic=1 rdinit=/ush" -serial stdio -display none -no-reboot -m 256M || true

## uefi-boot: Build bootable UEFI artifacts (boot.efi and genesis.mcb in build/esp)
uefi-boot: all
	@echo "=> Preparing UEFI boot artifacts in build/esp..."
	@mkdir -p build/esp/EFI/BOOT
	@cp zig-out/bin/boot.efi build/esp/EFI/BOOT/BOOTX64.EFI
	@cp src/kernel/genesis.mcb build/esp/genesis.mcb
	@echo "=> UEFI boot artifacts prepared successfully."

## uefi-disk-image: Create a bootable GPT disk image for physical USB/NVMe deployment
uefi-disk-image: uefi-boot
	@echo "=> Emitting bootable raw UEFI GPT disk image in build/micros-uefi.img..."
	@dd if=/dev/zero of=build/micros-uefi.img bs=1M count=64 status=none
	@mkfs.vfat -F 32 build/micros-uefi.img >/dev/null 2>&1
	@mmd -i build/micros-uefi.img ::EFI ::EFI/BOOT >/dev/null 2>&1 || true
	@mcopy -i build/micros-uefi.img build/esp/EFI/BOOT/BOOTX64.EFI ::EFI/BOOT/BOOTX64.EFI >/dev/null 2>&1
	@mcopy -i build/micros-uefi.img build/esp/genesis.mcb ::genesis.mcb >/dev/null 2>&1
	@echo "=> Bootable UEFI disk image created successfully: build/micros-uefi.img"

## qemu-uefi: Boot bare-metal MicrOS UEFI in QEMU with live display & serial
qemu-uefi: uefi-boot
	@echo "=> Booting MicrOS UEFI in QEMU with live display..."
	@mkdir -p build
	@if [ ! -f build/micros-disk.raw ]; then truncate -s 64M build/micros-disk.raw; fi
	@qemu-system-x86_64 -enable-kvm -cpu host -m 512M \
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
		-drive format=raw,file=fat:rw:build/esp \
		-drive id=disk0,if=none,format=raw,file=build/micros-disk.raw \
		-device virtio-blk-pci,drive=disk0 \
		-netdev user,id=net0,hostfwd=tcp::8080-:8080 \
		-device virtio-net-pci,netdev=net0 \
		-device virtio-vga,xres=1280,yres=800 \
		-display gtk,zoom-to-fit=on \
		-serial stdio

## qemu-cluster: Boot virtual dual-node P2P cluster mesh in QEMU with live display
qemu-cluster: uefi-boot
	@./tools/micros-cluster.bash --mode interactive

## qemu-cluster-verify: Headless verification of dual-node P2P cluster mesh startup
qemu-cluster-verify: uefi-boot
	@./tools/micros-cluster.bash --mode verify

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

## arch-gate: Verify microkernel architectural boundary rules
arch-gate: tools
	@echo "=> Checking architectural boundary rules..."
	./tools/micros-arch-gate src/

## check: Run all verifications (test, lint, fmt-check, spec-trace, arch-gate)
check: test lint fmt-check spec-trace arch-gate
	@echo "=> All checks passed successfully."

## help: Print this help message
help:
	@echo "MicrOS (µOS) Build System"
	@echo "-------------------------"
	@echo "Available targets:"
	@awk '/^## / { sub(/^## /, ""); split($$0, t, ": "); printf "  \033[36m%-15s\033[0m %s\n", t[1], t[2] }' $(MAKEFILE_LIST)

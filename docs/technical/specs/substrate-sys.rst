===================================================
Substrate Architecture & System Layer Specification
===================================================

:Document ID: SPEC-TECH-SYS-001
:Status: Approved
:Traced Stories: [US-REN-003], [US-REN-004], [US-GEM-001], [US-GEM-007]

1. Substrate Isolation & Direct Syscalls
========================================
The MicrOS substrate resides in `src/sys/` and links zero external C runtime libraries (`libc`). All interactions with the host Linux kernel or bare-metal environment occur through strongly typed Zig syscall wrappers:

- `src/sys/linux.zig`: Raw syscall invocation (`syscall1` through `syscall6`) with automatic negative errno translation into Zig error unions.
- `src/sys/io.zig`: File descriptor operations (`read`, `write`, `close`, `pipe2`, `dup2`).
- `src/sys/mem.zig`: Virtual memory page allocations (`mmap`, `munmap`) with strict 4096-byte mathematical alignment enforcement.
- `src/sys/process.zig`: Process lifecycle controls (`exit`, `poweroff` via raw ACPI S5 reboot commands `0x4321fedc`).

2. Virtual Memory Architecture
==============================
- Memory pages are mapped using `sys.mem.map` with `Prot.read | Prot.write` and `Flags.private | Flags.anonymous`.
- Allocations require explicit allocator parameters (`std.mem.Allocator`).
- Mathematical page boundary verification ensures zero unaligned access or memory page crossing hazards.

3. Unified Kernel Image (UKI) Boot
==================================
- Packaging: `build/micros-sandbox.efi` is generated via `ukify` combining `systemd-stub`, `/lib/modules/$(uname -r)/vmlinuz`, and `build/initramfs.cpio.gz`.
- Execution: Direct UEFI booting in QEMU/KVM with OVMF firmware (`/usr/share/edk2/ovmf/OVMF_CODE.fd`).
- Measured Execution: Full boot from UEFI initialization to PID 1 substrate self-test and clean ACPI S5 poweroff in under 1.0 second.

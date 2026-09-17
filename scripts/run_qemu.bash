#!/usr/bin/bash
set -euo pipefail
IFS=$'\n\t'

main() {
    # Move to the project root directory relative to this script
    cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

    # Rebuild
    zig build

    # Prepare an EFI system partition directory
    mkdir -p esp/EFI/BOOT
    cp zig-out/bin/boot.efi esp/EFI/BOOT/BOOTX64.EFI
    cp zig-out/bin/kernel esp/kernel.elf

    # You may need to specify the path to your system's OVMF.fd
    # Fedora usually has it at /usr/share/edk2/ovmf/OVMF_CODE.fd
    local ovmf_path="/usr/share/edk2/ovmf/OVMF_CODE.fd"
    if [[ ! -f "$ovmf_path" ]]; then
        ovmf_path="/usr/share/OVMF/OVMF_CODE.fd"
    fi

    if [[ ! -f "$ovmf_path" ]]; then
        printf 'Error: OVMF firmware not found. Please install edk2-ovmf.\n' >&2
        return 1
    fi

    qemu-system-x86_64 \
        -enable-kvm \
        -m 512M \
        -drive "if=pflash,format=raw,readonly=on,file=$ovmf_path" \
        -drive "format=raw,file=fat:rw:esp" \
        -serial stdio \
        -display none
}

main "$@"

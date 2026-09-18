============================================================
In-System Native Machine Code Compiler Backend (SPEC-TECH-LANG-004)
============================================================

:Document ID: SPEC-TECH-LANG-004
:Status: Approved
:Traced Stories: [US-REN-004], [US-REN-006], [US-REN-007], [US-GEM-005], [US-GEM-010]

1. Architectural Axioms & Purpose
=================================
This specification formalizes the **Pure In-System Native Machine Code Compiler Backend and Relocatable ELF64 Emitter** for MicrOS (µOS). Operating within the native Macros compiler subsystem, this engine emits freestanding 64-bit ELF relocatable objects (``.o``) and raw machine code (x86_64) directly on running silicon. It severs the operating system's dependency on host cross-compilers, toolchains, or third-party binary linkers.

1.1 Complete Silicon Autonomy
-----------------------------
To achieve computational sovereignty, MicrOS must be capable of rebuilding its own kernel, runtime, and actor binaries from source on bare metal:
* **Direct Relocatable ELF64 Emission**: Emits standard 64-bit ELF object files with valid section headers, symbol tables, and string tables using zero external dependencies.
* **Hardware W^X Enforcement**: Pages intended for machine execution are allocated strictly Read/Write during compilation and transitioned to Read/Execute (W^X) before invocation via capability-governed syscalls (``sys_mem_protect``).
* **Bit-for-Bit Deterministic Reproducibility**: Binary emission mathematically guarantees identical outputs for identical source ASTs (``BLAKE3(Build_1) == BLAKE3(Build_2)``).

2. ELF64 Binary Layout & Specifications
=======================================

2.1 ELF Header Layout (Elf64_Ehdr)
----------------------------------
The relocatable ELF object begins with the standard 64-byte ELF64 file header:

.. code-block:: zig

   pub const EI_MAG0: usize = 0; // 0x7F
   pub const EI_MAG1: usize = 1; // 'E'
   pub const EI_MAG2: usize = 2; // 'L'
   pub const EI_MAG3: usize = 3; // 'F'
   pub const ELFCLASS64: u8 = 2;
   pub const ELFDATA2LSB: u8 = 1;
   pub const EV_CURRENT: u8 = 1;
   pub const ET_REL: u16 = 1;
   pub const EM_X86_64: u16 = 62;

   pub const Elf64_Ehdr = extern struct {
       e_ident: [16]u8 align(1),
       e_type: u16 align(1),
       e_machine: u16 align(1),
       e_version: u32 align(1),
       e_entry: u64 align(1),
       e_phoff: u64 align(1),
       e_shoff: u64 align(1),
       e_flags: u32 align(1),
       e_ehsize: u16 align(1),
       e_phentsize: u16 align(1),
       e_phnum: u16 align(1),
       e_shentsize: u16 align(1),
       e_shnum: u16 align(1),
       e_shstrndx: u16 align(1),
   };

2.2 Section Header Table (Elf64_Shdr)
-------------------------------------
The emitter writes standard section headers describing object partitions:
* Section 0: ``NULL`` header (all zeros).
* Section 1: ``.text`` (``SHT_PROGBITS``, ``SHF_ALLOC | SHF_EXECINSTR``) - executable x86_64 machine code.
* Section 2: ``.rodata`` (``SHT_PROGBITS``, ``SHF_ALLOC``) - immutable constants and string literals.
* Section 3: ``.data`` (``SHT_PROGBITS``, ``SHF_ALLOC | SHF_WRITE``) - mutable global state.
* Section 4: ``.symtab`` (``SHT_SYMTAB``) - symbol table entries for linker resolution.
* Section 5: ``.strtab`` (``SHT_STRTAB``) - null-terminated symbol names.
* Section 6: ``.shstrtab`` (``SHT_STRTAB``) - null-terminated section header names.

2.3 Symbol Table (Elf64_Sym)
----------------------------
Symbol definitions support external linkers and the kernel's in-memory symbol resolver (``micros-sym``):

.. code-block:: zig

   pub const Elf64_Sym = extern struct {
       st_name: u32 align(1),
       st_info: u8 align(1),
       st_other: u8 align(1),
       st_shndx: u16 align(1),
       st_value: u64 align(1),
       st_size: u64 align(1),
   };

3. Hardware W^X Enforcement & Page Lifecycle
============================================

3.1 Page Permission State Transitions
-------------------------------------
1. **Compilation Phase**: Memory is mapped via ``sys.mem.map`` with permissions ``PROT_READ | PROT_WRITE``. Execution is strictly disabled; any attempt to branch into the buffer faults immediately.
2. **Transition Phase**: Machine code bytes are flushed. ``sys.mem.protect`` transitions the page to ``PROT_READ | PROT_EXEC``. Write permission is irrevocably revoked.
3. **Execution Phase**: The native entry pointer is invoked. The CPU MMU hardware enforces non-writable code execution.
4. **Reclamation Phase**: Upon completion, the page is zeroed and released via ``sys.mem.unmap``.

4. Verification & Traceability Matrix
=====================================

.. list-table::
   :widths: 20 25 55
   :header-rows: 1

   * - Requirement ID
     - Traced Story
     - Verification Method
   * - REQ-EMIT-001
     - [US-REN-004]
     - Zero-libc freestanding ELF64 binary object synthesis and header validation.
   * - REQ-EMIT-002
     - [US-REN-006]
     - Capability-bounded W^X page permission transitions preventing code injection.
   * - REQ-EMIT-003
     - [US-REN-007]
     - Deterministic, bit-for-bit reproducible ELF object emission verified by BLAKE3.
   * - REQ-EMIT-004
     - [US-GEM-005]
     - Exported symbol table (.symtab/.strtab) parsed and resolved by micros-sym.
   * - REQ-EMIT-005
     - [US-GEM-010]
     - Modular architecture under 1,000 LOC per file with bounded function complexity.

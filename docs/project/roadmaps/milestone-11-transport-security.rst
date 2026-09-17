Milestone 11: Transport Security & Freestanding HTTPS Engine
============================================================

:Objective: Deliver a freestanding, pure Zig TLS 1.3 cryptographic transport adapter and zero-allocation HTTP/1.1 client running natively on bare-metal UEFI without libc, enabling secure outbound API communication with Google Cloud and AI endpoints over VirtIO-Net.
:Status: Completed & Verified
:Specification: SPEC-TECH-GEMINI-001

Milestones & Deliverables
-------------------------

* **M11.1: Freestanding TLS 1.3 Transport Stream Adapter**
  - Implement ``TcpStreamAdapter`` in ``src/kernel/net/tls_stream.zig`` adapting the microkernel's non-blocking TCP stack to standard I/O streaming interfaces.
  - Integrate ``std.crypto.tls.Client`` from the Zig standard library in freestanding mode without libc or OS socket abstractions.
  - Implement hardware entropy harvesting via ``rdtsc`` and ``rdrand`` inline x86_64 assembly for cryptographic nonces.
  - Verify live TLS 1.3 handshake against ``generativelanguage.googleapis.com:443`` over VirtIO-Net in bare-metal UEFI QEMU.

* **M11.2: Freestanding Zero-Allocation HTTP/1.1 Client**
  - Implement ``src/kernel/net/http.zig`` providing zero-copy HTTP/1.1 POST formatting, status line parsing, and header inspection.
  - Support ``Authorization: Bearer <TOKEN>`` and API key query parameter schemes.
  - Enforce static buffer limits preventing heap exhaustion and kernel stack overflows.

* **M11.3: Secure Build-Time Provisioning & Validation**
  - Wire build-time API key injection (``-Dai-api-key`` and backward-compatible ``-Dgemini-api-key``) across ``build.zig``.
  - Colocate unit tests in ``src/kernel/net/http.zig`` and ``src/kernel/net/tls_stream.zig`` verifying request serialization and response parsing.

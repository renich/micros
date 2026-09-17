Milestone 12: Pluggable Resident AI & Sovereign Event Loop
==========================================================

:Objective: Completely decouple the microkernel from specific AI providers via a modular Resident AI subsystem (src/kernel/ai/), engineer real-world WAN and TCP communication resilience, and implement the bidirectional sovereign event loop executing emitted Macros code on hardware.
:Status: Completed & Verified
:Specification: SPEC-TECH-GEMINI-001

Milestones & Deliverables
-------------------------

* **M12.1: Pluggable Resident AI Driver Subsystem**
  - Implement polymorphic ``AiClient`` in ``src/kernel/ai/client.zig`` supporting multiple upstream LLM engines.
  - Implement dedicated provider drivers for Google Gemini (``src/kernel/ai/gemini.zig``), OpenAI/vLLM/Ollama (``src/kernel/ai/openai.zig``), and offline deterministic Mock (``src/kernel/ai/mock.zig``).
  - Implement shared sovereign system prompt and JSON escaper in ``src/kernel/ai/provider.zig``.

* **M12.2: Real-World Network Communication Resilience**
  - Enlarge TCP RX buffer to 64KB with modulo 2^32 sequence number window tracking.
  - Implement stop-and-wait reliable delivery per 1460-byte MSS segment with exponential backoff retransmissions.
  - Add rotating local ephemeral port allocation (49152..65535) and multi-tier DNS resolver fallbacks (Google 8.8.8.8, Cloudflare 1.1.1.1).
  - Eliminate UEFI firmware stack overflows by switching large buffer allocations to static BSS buffers and pointer semantics.

* **M12.3: Bidirectional Sovereign Event Loop Execution**
  - Implement multi-turn sovereign event loop in ``src/kernel/main.zig`` (``runSovereignEventLoop``).
  - Parse emitted reStructuredText (``.. code-block:: macros`` / ``.. code-block:: mx``) cognitive responses in CSpace 0.
  - Dynamically compile emitted Macros code using the self-hosted compiler and execute it directly on bare-metal hardware.
  - Expand test suite to 108/108 green unit tests and verify 0 Ten Commandments violations.

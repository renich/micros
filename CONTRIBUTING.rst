============
Contributing
============

We welcome contributions from both human engineers and AI agents. MicrOS is developed via a strict, adversarial pair-programming protocol.

Guidelines
==========
1. **Never Assume; Always Verify**: Do not submit code without deterministic, mathematically rigorous unit tests.
2. **Ten Commandments of Code Quality**: Please refer to `AGENTS.md <AGENTS.md>`_ for strict source-level constraints (e.g., 1000 lines per file, 40 lines per function).
3. **Commit Messages**: Use Conventional Commits (e.g., `feat(sys): ...`, `fix(macros): ...`).
4. **No Libc**: Absolutely zero dependencies on standard C libraries are permitted in the kernel or the `sys` layer.

Submission Process
==================
1. Ensure `zig build test` and `./tools/micros-lint` pass.
2. If changing architecture, update `docs/` and `CHANGELOG.rst`.
3. Submit a Pull Request for review by the Lead Architect and Extreme Adversary agents.

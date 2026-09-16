=========================================
MicrOS (µOS) Master Business Specification
=========================================

:Status: Approved
:Version: 1.0.0
:Date: 2026-09-16

Executive Summary
=================
This master document outlines the business, architectural, and operational requirements for MicrOS (µOS) and the Macros programming language. MicrOS is designed as a sovereign, AI-native operating system delivering sub-second boot times, typed shared-memory ring execution, and zero-libc determinism for both human engineers and autonomous AI agents.

Sub-Specifications
==================

.. toctree::
   :maxdepth: 2
   :caption: Business Documents

   specs/user-personas
   specs/user-stories-renich
   specs/user-stories-gemini

Strategic Objectives
====================
1. **Dual-Native Sovereignty**: Create an environment equally intuitive for human infrastructure architects and autonomous AI engineering agents.
2. **Elimination of Text-Stream Brittleness**: Replace untyped ASCII pipes with typed shared-memory rings in MicroShell (`msh`).
3. **Immutable UKI & UEFI Delivery**: Package unified kernel images (`.efi`) for instant, measured, and verified boots across virtualized and bare-metal nodes.
4. **Context-Window Efficiency**: Enforce strict file size and structural constraints (< 1,000 lines, max 3 nesting levels) to optimize LLM reasoning and code generation.

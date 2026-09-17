// MicrOS (µOS) Harness Bindings Compatibility Layer
// Forwards directly to the unified Sovereign System ABI (abi.zig).

pub const abi = @import("abi.zig");
pub const HarnessContext = abi.AbiContext;
pub const setContext = abi.setContext;
pub const clearContext = abi.clearContext;
pub const registerBindings = abi.registerSyscalls;
pub const registerSyscalls = abi.registerSyscalls;

test {
    _ = abi;
}

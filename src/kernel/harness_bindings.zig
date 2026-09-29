// MicrOS (µOS) Harness Bindings Compatibility Layer
// Forwards directly to the unified Sovereign System ABI (abi.zig),
// providing compatibility shims for offline harness evaluation.

pub const abi = @import("abi.zig");
pub const HarnessContext = abi.AbiContext;
pub const setContext = abi.setContext;
pub const clearContext = abi.clearContext;

pub fn registerBindings(vm: *abi.VM) !void {
    try abi.registerSyscalls(vm);
}

pub const registerSyscalls = registerBindings;

test {
    _ = abi;
}

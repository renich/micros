// MicrOS (µOS) Reactive Vector Compositor
pub const canvas = @import("compositor/canvas.zig");
pub const Canvas = canvas.Canvas;
pub const DamageRect = canvas.DamageRect;
pub const surface = @import("compositor/surface.zig");
pub const Surface = surface.Surface;
pub const SurfaceCommit = surface.SurfaceCommit;
pub const wm = @import("compositor/wm.zig");
pub const Window = wm.Window;
pub const WindowManager = wm.WindowManager;
pub const WindowMode = wm.WindowMode;
pub const input = @import("compositor/input.zig");
pub const PointerState = input.PointerState;
pub const MouseEvent = input.MouseEvent;
pub const Ps2MouseDecoder = input.Ps2MouseDecoder;

test "compositor module tests" {
    _ = canvas;
    _ = surface;
    _ = wm;
    _ = input;
}

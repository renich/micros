// MicrOS (µOS) Workspace Catalog Root Bridge
// Persists the catalog manifest as the catalog sub-root of the CAS root directory and
// restores it at boot, so named artifacts and cached actors survive a cold reboot.
// Zero libc, freestanding, explicit allocator.

const std = @import("std");
const cas_mod = @import("cas.zig");
const chunk_mod = @import("chunk.zig");
const block = @import("../drivers/block.zig");
const root_dir = @import("root_dir.zig");
const catalog_abi = @import("catalog_abi.zig");
const serial = @import("../serial.zig");

pub fn persist(cas: *cas_mod.CasEngine, dev: ?*block.BlockDevice, root: *const [chunk_mod.HASH_SIZE]u8) anyerror!void {
    try root_dir.setCatalogManifestHash(cas, dev, root);
}

/// Rehydrate the workspace manifest recorded in the persisted catalog sub-root.
/// Returns true when a catalog was restored.
pub fn restore(cas: *cas_mod.CasEngine, dev: ?*block.BlockDevice, allocator: std.mem.Allocator) bool {
    const dir = root_dir.load(cas, dev);
    if (std.mem.eql(u8, &dir.catalog_manifest_hash, &root_dir.RootDirectory.ZERO_HASH)) return false;

    const buf = allocator.alloc(u8, catalog_abi.MAX_SERIALIZED_MANIFEST_SIZE) catch return false;
    defer allocator.free(buf);
    const len = cas.getChunk(&dir.catalog_manifest_hash, buf, dev) catch return false;
    catalog_abi.global_catalog.restoreFromManifest(buf[0..len], &dir.catalog_manifest_hash) catch return false;
    serial.writeStatusOk("catl", "Workspace catalog restored from persisted CAS root");
    return true;
}

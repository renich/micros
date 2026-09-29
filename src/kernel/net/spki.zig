// MicrOS (µOS) Subject Public Key Info (SPKI) Trust Substrate
// Freestanding cryptographic certificate pinning for sovereign TLS 1.3 (RFC 7469).
// Zero libc, constant-time verification, fail-closed enforcement.

const std = @import("std");
const builtin = @import("builtin");
const serial = @import("../serial.zig");

pub const SpkiPin = [32]u8;

pub const PinnedEndpoint = struct {
    hostname: []const u8,
    primary_pin: SpkiPin,
    backup_pins: [2]SpkiPin,
    backup_count: usize,
};

pub var allow_unpinned: bool = false;

// Tier 1 ROM: Compile-time Genesis Trust Table
const GENESIS_PINNED_ENDPOINTS = [_]PinnedEndpoint{
    .{
        .hostname = "generativelanguage.googleapis.com",
        // Google Trust Services GTS Root R1 SPKI SHA-256
        .primary_pin = [_]u8{
            0xd9, 0x47, 0x43, 0x2a, 0xb7, 0xcb, 0xd5, 0xcb,
            0x09, 0x58, 0x18, 0x9c, 0x44, 0x56, 0x9e, 0x25,
            0xd2, 0xd0, 0xb7, 0x41, 0x5b, 0xf3, 0xbd, 0x5c,
            0xb4, 0x50, 0x8e, 0xf4, 0x8d, 0x08, 0xca, 0x46,
        },
        // GTS Root R2 & GlobalSign Root R1 backup SPKI hashes
        .backup_pins = [_]SpkiPin{
            [_]u8{
                0xb4, 0x79, 0x15, 0x47, 0x84, 0x96, 0x73, 0x85,
                0xf9, 0xc4, 0x90, 0x89, 0x5c, 0x27, 0x0d, 0x42,
                0x18, 0x3e, 0x84, 0x3b, 0xbf, 0xe4, 0x8a, 0x58,
                0xa6, 0x9d, 0x7b, 0x40, 0x97, 0xeb, 0x63, 0x75,
            },
            [_]u8{
                0xeb, 0xe0, 0x00, 0x0a, 0x6e, 0x45, 0x44, 0xd6,
                0xdb, 0x8b, 0x12, 0x27, 0x09, 0x28, 0x9b, 0xb6,
                0xea, 0x84, 0x34, 0x86, 0x3f, 0x69, 0xab, 0xcf,
                0x58, 0x6e, 0x3f, 0x01, 0x9b, 0x88, 0x49, 0x60,
            },
        },
        .backup_count = 2,
    },
    .{
        .hostname = "test.micros.local",
        // Fixture certificate leaf SPKI SHA-256
        .primary_pin = [_]u8{
            0xfa, 0xf4, 0x45, 0xc0, 0x4c, 0x0e, 0x0e, 0x9e,
            0x3d, 0xbf, 0xe7, 0xf6, 0x29, 0xcf, 0x62, 0x44,
            0x00, 0xd6, 0xc3, 0xc5, 0xe8, 0x4e, 0xf1, 0xcb,
            0xdb, 0x15, 0x7d, 0x6a, 0x83, 0xa4, 0x03, 0x51,
        },
        .backup_pins = [_]SpkiPin{
            [_]u8{
                0xad, 0xd4, 0xd2, 0xa6, 0xdd, 0x80, 0x0a, 0x1b,
                0x98, 0xf3, 0xa3, 0x03, 0xc4, 0x2b, 0xa4, 0xd2,
                0xd1, 0x0c, 0x6c, 0x36, 0x91, 0x55, 0x6d, 0x70,
                0xf0, 0x36, 0x2f, 0xa3, 0xff, 0xbe, 0xb1, 0x87,
            },
            [_]u8{0} ** 32,
        },
        .backup_count = 1,
    },
};

pub fn countProvisionedPins() usize {
    var total: usize = 0;
    for (GENESIS_PINNED_ENDPOINTS) |endpoint| {
        total += 1 + endpoint.backup_count;
    }
    return total;
}

pub fn lookupEndpoint(hostname: []const u8) ?PinnedEndpoint {
    for (GENESIS_PINNED_ENDPOINTS) |endpoint| {
        if (std.mem.eql(u8, endpoint.hostname, hostname)) {
            return endpoint;
        }
    }
    return null;
}

pub fn extractSpkiSha256(cert_der: []const u8) ![32]u8 {
    const cert: std.crypto.Certificate = .{
        .buffer = cert_der,
        .index = 0,
    };
    const parsed = try cert.parse();
    const spki_start = parsed.subject_slice.end;
    const spki_elem = try std.crypto.Certificate.der.Element.parse(cert_der, spki_start);
    const spki_bytes = cert_der[spki_start..spki_elem.slice.end];

    var pin: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(spki_bytes, &pin, .{});
    return pin;
}

pub fn verifySpkiPin(hostname: []const u8, leaf_cert_der: []const u8) !void {
    const leaf_pin = extractSpkiSha256(leaf_cert_der) catch |err| {
        serial.writeString("[FATAL] tls: MALFORMED CERTIFICATE: ");
        serial.writeString(@errorName(err));
        serial.writeString("! Connection aborted.\n");
        return error.CertificatePinMismatch;
    };
    const endpoint = lookupEndpoint(hostname) orelse {
        if (allow_unpinned) {
            serial.writeStatusWarn("tls ", "UNPINNED endpoint allowed by explicit override");
            return;
        }
        serial.writeString("[FATAL] tls: UNKNOWN ENDPOINT ");
        serial.writeString(hostname);
        serial.writeString(" (fail-closed, no pins configured)\n");
        return error.CertificatePinMismatch;
    };

    if (std.crypto.timing_safe.eql([32]u8, leaf_pin, endpoint.primary_pin)) {
        return;
    }
    for (endpoint.backup_pins[0..endpoint.backup_count]) |backup_pin| {
        if (std.crypto.timing_safe.eql([32]u8, leaf_pin, backup_pin)) {
            return;
        }
    }

    serial.writeString("[FATAL] tls: SPKI PIN MISMATCH for ");
    serial.writeString(hostname);
    serial.writeString("! Connection aborted.\n");
    return error.CertificatePinMismatch;
}

pub fn logBootStatus() void {
    const total_pins = countProvisionedPins();
    if (total_pins > 0 and !allow_unpinned) {
        var msg_buf: [64]u8 = undefined;
        if (std.fmt.bufPrint(&msg_buf, "TLS 1.3 SPKI pinning active ({d} pins provisioned)", .{total_pins})) |s| {
            serial.writeStatusOk("tls ", s);
        } else |_| {
            serial.writeStatusOk("tls ", "TLS 1.3 SPKI pinning active");
        }
    } else {
        serial.writeStatusWarn("tls ", "TLS 1.3 active (UNPINNED - zero SPKI pins configured)");
    }
}

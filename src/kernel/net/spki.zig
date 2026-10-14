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
        // Google Trust Services WE2 (ECDSA Intermediate CA) SPKI SHA-256
        .primary_pin = [_]u8{
            0xbe, 0x1e, 0xfc, 0x29, 0x28, 0x35, 0x47, 0x2e,
            0x0d, 0x6a, 0xa1, 0x83, 0x57, 0x5d, 0x30, 0xfd,
            0xc4, 0xdb, 0xf5, 0x51, 0xf7, 0x05, 0x05, 0x19,
            0xa0, 0x25, 0x8d, 0x6b, 0xdd, 0xd6, 0xfc, 0x46,
        },
        // GTS Root R4 (ECDSA Root) & GTS Root R1 (RSA Root) backup SPKI SHA-256 hashes
        .backup_pins = [_]SpkiPin{
            [_]u8{
                0x98, 0x47, 0xe5, 0x65, 0x3e, 0x5e, 0x9e, 0x84,
                0x75, 0x16, 0xe5, 0xcb, 0x81, 0x86, 0x06, 0xaa,
                0x75, 0x44, 0xa1, 0x9b, 0xe6, 0x7f, 0xd7, 0x36,
                0x6d, 0x50, 0x69, 0x88, 0xe8, 0xd8, 0x43, 0x47,
            },
            [_]u8{
                0x87, 0x1a, 0x91, 0x94, 0xf4, 0xee, 0xd5, 0xb3,
                0x12, 0xff, 0x40, 0xc8, 0x4c, 0x1d, 0x52, 0x4a,
                0xed, 0x2f, 0x77, 0x8b, 0xbf, 0xf2, 0x5f, 0x13,
                0x8c, 0xf8, 0x1f, 0x68, 0x0a, 0x7a, 0xdc, 0x67,
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

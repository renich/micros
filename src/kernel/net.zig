// MicrOS (µOS) Sovereign Network Subsystem Root
// Zero libc, capability-oriented network protocol suite.

pub const frame = @import("net/frame.zig");
pub const arp = @import("net/arp.zig");
pub const ipv4 = @import("net/ipv4.zig");
pub const icmp = @import("net/icmp.zig");
pub const udp = @import("net/udp.zig");
pub const dhcp = @import("net/dhcp.zig");
pub const dns = @import("net/dns.zig");
pub const tcp = @import("net/tcp.zig");
pub const stack = @import("net/stack.zig");
pub const tls_stream = @import("net/tls_stream.zig");
pub const http = @import("net/http.zig");

test "kernel net subsystem tests" {
    _ = @import("net/frame.zig");
    _ = @import("net/arp.zig");
    _ = @import("net/ipv4.zig");
    _ = @import("net/icmp.zig");
    _ = @import("net/udp.zig");
    _ = @import("net/dhcp.zig");
    _ = @import("net/dns.zig");
    _ = @import("net/tcp.zig");
    _ = @import("net/stack.zig");
    _ = @import("net/tls_stream.zig");
    _ = @import("net/http.zig");
}

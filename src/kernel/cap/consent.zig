// MicrOS (µOS) O7 Consent Memory Substrate
// Manages per-application capability consent ("Allow Always" / "Session Only" / "Deny"),
// persistent catalog storage (caps.granted.<app>), and elevation detection.
// Zero libc, freestanding, capability-safe.

const std = @import("std");

pub const MAX_APP_NAME_LEN: usize = 32;
pub const MAX_CONSENT_ENTRIES: usize = 32;

pub const ConsentChoice = enum(u8) {
    allow_always = 1,
    session_only = 2,
    deny = 3,
};

pub const AppConsent = struct {
    app_name: [MAX_APP_NAME_LEN]u8,
    app_name_len: usize,
    granted_caps: u64,
    is_persistent: bool,

    pub fn getName(self: *const AppConsent) []const u8 {
        return self.app_name[0..self.app_name_len];
    }
};

pub const ConsentTable = struct {
    entries: [MAX_CONSENT_ENTRIES]?AppConsent = [_]?AppConsent{null} ** MAX_CONSENT_ENTRIES,
    count: usize = 0,

    pub fn init() ConsentTable {
        return ConsentTable{};
    }

    pub fn find(self: *const ConsentTable, app_name: []const u8) ?*const AppConsent {
        for (self.entries[0..self.count]) |*opt_e| {
            if (opt_e.*) |*e| {
                if (std.mem.eql(u8, e.getName(), app_name)) return e;
            }
        }
        return null;
    }

    pub fn recordGrant(
        self: *ConsentTable,
        app_name: []const u8,
        caps: u64,
        choice: ConsentChoice,
    ) !void {
        if (choice == .deny) return;

        for (0..self.count) |i| {
            if (self.entries[i]) |*e| {
                if (std.mem.eql(u8, e.getName(), app_name)) {
                    e.granted_caps = caps;
                    e.is_persistent = (choice == .allow_always);
                    return;
                }
            }
        }

        if (self.count >= MAX_CONSENT_ENTRIES) return error.TableFull;
        var name_buf = [_]u8{0} ** MAX_APP_NAME_LEN;
        const copy_len = @min(app_name.len, MAX_APP_NAME_LEN);
        @memcpy(name_buf[0..copy_len], app_name[0..copy_len]);

        self.entries[self.count] = AppConsent{
            .app_name = name_buf,
            .app_name_len = copy_len,
            .granted_caps = caps,
            .is_persistent = (choice == .allow_always),
        };
        self.count += 1;
    }

    pub fn checkConsent(self: *const ConsentTable, app_name: []const u8, requested_caps: u64) ?bool {
        const existing = self.find(app_name) orelse return null;
        if ((requested_caps & ~existing.granted_caps) == 0) {
            return true;
        }
        return null;
    }

    pub fn revoke(self: *ConsentTable, app_name: []const u8) bool {
        var i: usize = 0;
        while (i < self.count) {
            if (self.entries[i]) |e| {
                if (std.mem.eql(u8, e.getName(), app_name)) {
                    self.removeIndex(i);
                    return true;
                }
            }
            i += 1;
        }
        return false;
    }

    fn removeIndex(self: *ConsentTable, idx: usize) void {
        var j = idx;
        while (j + 1 < self.count) : (j += 1) {
            self.entries[j] = self.entries[j + 1];
        }
        self.entries[self.count - 1] = null;
        self.count -= 1;
    }
};

// === Colocated Unit Tests ===

test "live-synth: O7 consent memory recall" {
    var table = ConsentTable.init();
    const app = "novel_editor";
    const baseline_caps: u64 = 0x0012; // CAP_WINDOW | CAP_STORAGE_READ

    // Turn 1: No previous consent -> checkConsent returns null (prompt required)
    try std.testing.expect(table.checkConsent(app, baseline_caps) == null);

    // User chooses [A]lways
    try table.recordGrant(app, baseline_caps, .allow_always);

    // Turn 2: Subsequent launch recalls consent without prompt
    const turn2 = table.checkConsent(app, baseline_caps);
    try std.testing.expect(turn2 != null and turn2.? == true);

    const consent_entry = table.find(app);
    try std.testing.expect(consent_entry != null);
    try std.testing.expect(consent_entry.?.is_persistent);
}

test "live-synth: O7 user consent deny bails safely without capability grant or actor spawn" {
    var table = ConsentTable.init();
    const app = "untrusted_script";
    const requested_caps: u64 = 0x0040; // CAP_NETWORK

    // User chooses [D]eny
    try table.recordGrant(app, requested_caps, .deny);

    // Deny is not recorded as granted -> subsequent check still returns null
    try std.testing.expect(table.checkConsent(app, requested_caps) == null);
    try std.testing.expect(table.find(app) == null);
}

test "O7 consent lifecycle: grant, recall without prompt, elevation detection, revocation" {
    var table = ConsentTable.init();
    const app = "desk";
    const initial_caps: u64 = 0x0010; // CAP_WINDOW

    // 1. Initial grant
    try table.recordGrant(app, initial_caps, .session_only);
    try std.testing.expect(table.checkConsent(app, initial_caps).? == true);

    // 2. Elevation: app now requests CAP_STORAGE (0x0080) in addition to CAP_WINDOW
    const elevated_caps: u64 = 0x0090; // CAP_WINDOW | CAP_STORAGE
    const elev_check = table.checkConsent(app, elevated_caps);
    // Must return null (re-prompt required for elevation!)
    try std.testing.expect(elev_check == null);

    // 3. User grants elevated caps
    try table.recordGrant(app, elevated_caps, .allow_always);
    try std.testing.expect(table.checkConsent(app, elevated_caps).? == true);

    // 4. Revocation
    try std.testing.expect(table.revoke(app));
    // After revocation, consent is cleared
    try std.testing.expect(table.checkConsent(app, elevated_caps) == null);
}

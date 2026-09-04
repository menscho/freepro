// src/ui/views_providers.zig — Provider & key management view-model (Wave1-Task09).
//
// What this file owns: per-provider cards (name, base URL, prefix tag,
// description, `H / T Keys Healthy` progress), the bulk-import multiline box
// (one key per line, trimmed, blank-skipped, order-preserving dedupe, 10+ at
// once), key rows (masked key, Green/Yellow/Red/Gray badge,
// disable/delete/test-ping actions), and the custom headers editor table
// (add/edit/remove rows, prefilled OpenCode headers).
//
// Contracts matched (src/models.zig):
//   models.Key          { key, state, last_used, cooldown_until,
//                         consecutive_errors, enabled } (strings []const u8)
//   models.KeyState     { Active, CoolingDown, Dead }
//   models.CustomHeader { key, value } with clone()/deinit()
//   models.Provider     { display_name, base_url, prefix, description,
//                         keys: []Key, headers: []CustomHeader }
//   models.opencode_prefix / models.kilo_prefix, models.defaultOpenCodeHeaders()
//
// Ownership: models slices are plain allocator-owned slices (NOT ArrayLists).
// Growth/removal here always allocates a new slice, moves entries over, and
// frees the old slice — the same discipline as models' own clone()/deinit().
// Callers must therefore pass providers whose keys/headers slices are
// allocator-owned (as produced by models' preset constructors, parse(), or
// clone()); this is already required by models.Provider.deinit(), so these
// helpers impose no new invariant.
//
// GUI integration: std-only, no DVUI/httpz import. ProvidersView holds the
// ephemeral UI state (selection, bulk textbox bytes, pending test-ping,
// header edit drafts); provider data stays borrowed from ProxyConfig so the
// config owner keeps sole ownership. The GUI owner calls
// applyBulkToSelected() / requestPing() / begin+commit/cancelHeaderEdit()
// from button handlers and binds rows, badges, and progress from the pure
// helpers. Test-ping execution (network) belongs to the proxy agent:
// requestPing() only snapshots indices, resolvePingKey() hands the key
// material back to the worker.
//
// Memory: ProvidersView owns bulk_text/draft_key/draft_value and frees them
// in deinit(). Parsed bulk strings are either moved into the provider's key
// pool or freed before returning; OOM paths never leak.

const std = @import("std");
const models = @import("../models.zig");

fn List(comptime T: type) type {
    return std.array_list.Managed(T);
}

pub const ViewError = error{
    IndexOutOfBounds,
    EmptyHeaderKey,
    NoProviderSelected,
};

// ---------------------------------------------------------------------------
// Badges + masking
// ---------------------------------------------------------------------------

pub const KeyBadge = enum {
    healthy,
    cooling_down,
    dead,
    disabled,

    pub fn label(self: KeyBadge) []const u8 {
        return switch (self) {
            .healthy => "Healthy",
            .cooling_down => "Cooldown",
            .dead => "Dead",
            .disabled => "Disabled",
        };
    }

    /// sRGB triple for status dots / badges in the native GUI.
    pub fn rgb(self: KeyBadge) [3]u8 {
        return switch (self) {
            .healthy => .{ 0x22, 0xc5, 0x5e },
            .cooling_down => .{ 0xe5, 0xb8, 0x08 },
            .dead => .{ 0xef, 0x44, 0x44 },
            .disabled => .{ 0x6b, 0x72, 0x80 },
        };
    }
};

pub fn badgeFor(key: *const models.Key) KeyBadge {
    if (!key.enabled) return .disabled;
    return switch (key.state) {
        .Active => .healthy,
        .CoolingDown => .cooling_down,
        .Dead => .dead,
    };
}

pub const MaskedKey = struct {
    buf: [16]u8 = [_]u8{0} ** 16,
    len: usize = 0,

    pub fn slice(self: *const MaskedKey) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Show just enough to identify a key: first 3 + "…" + last 2; short keys
/// reveal only the tail; empty keys render as "<empty>".
pub fn maskKey(raw: []const u8) MaskedKey {
    var out = MaskedKey{};
    const ell = "…";
    if (raw.len == 0) {
        const tag = "<empty>";
        @memcpy(out.buf[0..tag.len], tag);
        out.len = tag.len;
        return out;
    }
    if (raw.len <= 8) {
        const tail_len = @min(4, raw.len);
        @memcpy(out.buf[0..ell.len], ell);
        @memcpy(out.buf[ell.len..][0..tail_len], raw[raw.len - tail_len ..]);
        out.len = ell.len + tail_len;
    } else {
        @memcpy(out.buf[0..3], raw[0..3]);
        @memcpy(out.buf[3..][0..ell.len], ell);
        @memcpy(out.buf[3 + ell.len ..][0..2], raw[raw.len - 2 ..]);
        out.len = 3 + ell.len + 2;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Health summary + progress
// ---------------------------------------------------------------------------

pub const HealthSummary = struct {
    healthy: usize = 0,
    total: usize = 0,

    pub fn percent(self: HealthSummary) u8 {
        if (self.total == 0) return 0;
        return @intCast((self.healthy * 100) / self.total);
    }
};

/// Instantaneous state health: enabled and Active. (The rotator's
/// usableKeyCount() is additionally time-aware about cooling expiry; the
/// dashboard card intentionally shows the stricter snapshot.)
pub fn summarizeKeys(keys: []const models.Key) HealthSummary {
    var summary = HealthSummary{ .total = keys.len };
    for (keys) |*key| {
        if (key.enabled and key.state == .Active) summary.healthy += 1;
    }
    return summary;
}

pub fn summarizeProvider(provider: *const models.Provider) HealthSummary {
    return summarizeKeys(provider.keys);
}

/// ASCII progress bar, e.g. `[####------] 40%`. Width is bar cells only.
pub fn writeProgressBar(writer: anytype, summary: HealthSummary, width: usize) !void {
    const filled = if (summary.total == 0) 0 else (summary.healthy * width) / summary.total;
    try writer.writeByte('[');
    var i: usize = 0;
    while (i < width) : (i += 1) {
        try writer.writeByte(if (i < filled) '#' else '-');
    }
    try writer.print("] {d}%", .{summary.percent()});
}

// ---------------------------------------------------------------------------
// Bulk import
// ---------------------------------------------------------------------------

/// Split pasted text on newlines, trim surrounding whitespace, drop blank
/// lines, and dedupe exact matches preserving first-seen order. Returns
/// owned dupes; free with freeParsedKeys().
pub fn parseBulkKeys(allocator: std.mem.Allocator, text: []const u8) !List([]u8) {
    var out = List([]u8).init(allocator);
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit();
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    outer: while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen, trimmed)) continue :outer;
        }
        try out.append(try allocator.dupe(u8, trimmed));
    }
    return out;
}

pub fn freeParsedKeys(list: *List([]u8)) void {
    for (list.items) |s| list.allocator.free(s);
    list.deinit();
}

pub fn keyExists(provider: *const models.Provider, candidate: []const u8) bool {
    for (provider.keys) |*key| {
        if (std.mem.eql(u8, key.key, candidate)) return true;
    }
    return false;
}

/// Fresh pool entry: enabled, Active, zeroed counters/timestamps.
pub fn defaultKey(key_text: []const u8) models.Key {
    return .{
        .key = key_text,
        .state = .Active,
        .last_used = 0,
        .cooldown_until = 0,
        .consecutive_errors = 0,
        .enabled = true,
    };
}

/// Parse `text` and append keys not already in the pool. Returns the number
/// added; pastes of 10+ keys at once are the normal case. Never inserts a
/// duplicate of an existing pool key. Owns nothing on return.
pub fn addBulkKeys(allocator: std.mem.Allocator, provider: *models.Provider, text: []const u8) !usize {
    var parsed = try parseBulkKeys(allocator, text);
    defer parsed.deinit();

    // In-place filter: keep candidates missing from the pool (the batch is
    // already internally deduped by parseBulkKeys), freeing the rest.
    var fresh: usize = 0;
    for (parsed.items) |s| {
        if (keyExists(provider, s)) {
            allocator.free(s);
        } else {
            parsed.items[fresh] = s;
            fresh += 1;
        }
    }
    if (fresh == 0) return 0;

    const old = provider.keys;
    var grown = try allocator.alloc(models.Key, old.len + fresh);
    @memcpy(grown[0..old.len], old);
    for (parsed.items[0..fresh], 0..) |s, i| grown[old.len + i] = defaultKey(s);
    allocator.free(old);
    provider.keys = grown;
    return fresh;
}

// ---------------------------------------------------------------------------
// Key row actions
// ---------------------------------------------------------------------------

pub fn setKeyEnabled(provider: *models.Provider, index: usize, enabled: bool) ViewError!void {
    if (index >= provider.keys.len) return error.IndexOutOfBounds;
    provider.keys[index].enabled = enabled;
}

pub fn removeKeyAt(allocator: std.mem.Allocator, provider: *models.Provider, index: usize) !void {
    if (index >= provider.keys.len) return error.IndexOutOfBounds;
    const old = provider.keys;
    var next = try allocator.alloc(models.Key, old.len - 1);
    @memcpy(next[0..index], old[0..index]);
    @memcpy(next[index..], old[index + 1 ..]);
    allocator.free(old[index].key);
    allocator.free(old);
    provider.keys = next;
}

pub const PingStatus = enum {
    idle,
    requested,
    ok,
    failed,
};

/// Index snapshot for a test-ping. Carries no key material; the worker
/// resolves it via resolvePingKey() at ping time.
pub const PingTarget = struct {
    provider_index: usize,
    key_index: usize,
};

pub fn resolvePingKey(providers: []const models.Provider, target: PingTarget) ViewError![]const u8 {
    if (target.provider_index >= providers.len) return error.IndexOutOfBounds;
    const keys = providers[target.provider_index].keys;
    if (target.key_index >= keys.len) return error.IndexOutOfBounds;
    return keys[target.key_index].key;
}

// ---------------------------------------------------------------------------
// Custom headers editor
// ---------------------------------------------------------------------------

pub fn isOpenCodeProvider(provider: *const models.Provider) bool {
    return std.mem.eql(u8, provider.prefix, models.opencode_prefix);
}

/// Case-insensitive (HTTP semantics) header lookup returning the row index
/// for in-place edit/remove. Note models.Provider.findHeader() is the
/// case-sensitive value lookup; this is the editor's index lookup.
pub fn findHeaderIndex(provider: *const models.Provider, name: []const u8) ?usize {
    for (provider.headers, 0..) |*header, i| {
        if (std.ascii.eqlIgnoreCase(header.key, name)) return i;
    }
    return null;
}

fn appendHeader(allocator: std.mem.Allocator, provider: *models.Provider, header: models.CustomHeader) !void {
    const old = provider.headers;
    var grown = try allocator.alloc(models.CustomHeader, old.len + 1);
    @memcpy(grown[0..old.len], old);
    grown[old.len] = header;
    allocator.free(old);
    provider.headers = grown;
}

pub fn addHeader(allocator: std.mem.Allocator, provider: *models.Provider, k: []const u8, v: []const u8) !void {
    if (k.len == 0) return error.EmptyHeaderKey;
    var header = models.CustomHeader{
        .key = try allocator.dupe(u8, k),
        .value = try allocator.dupe(u8, v),
    };
    errdefer header.deinit(allocator);
    try appendHeader(allocator, provider, header);
}

pub fn setHeader(allocator: std.mem.Allocator, provider: *models.Provider, index: usize, k: []const u8, v: []const u8) !void {
    if (index >= provider.headers.len) return error.IndexOutOfBounds;
    if (k.len == 0) return error.EmptyHeaderKey;
    const header = &provider.headers[index];
    const new_key = try allocator.dupe(u8, k);
    errdefer allocator.free(new_key);
    const new_value = try allocator.dupe(u8, v);
    allocator.free(header.key);
    allocator.free(header.value);
    header.key = new_key;
    header.value = new_value;
}

pub fn removeHeaderAt(allocator: std.mem.Allocator, provider: *models.Provider, index: usize) !void {
    if (index >= provider.headers.len) return error.IndexOutOfBounds;
    const old = provider.headers;
    var next = try allocator.alloc(models.CustomHeader, old.len - 1);
    @memcpy(next[0..index], old[0..index]);
    @memcpy(next[index..], old[index + 1 ..]);
    allocator.free(old[index].key);
    allocator.free(old[index].value);
    allocator.free(old);
    provider.headers = next;
}

/// Insert any missing OpenCode preset headers (single source of truth:
/// models.defaultOpenCodeHeaders) without duplicating existing rows.
/// Returns the number of rows added.
pub fn ensureOpenCodeHeaders(allocator: std.mem.Allocator, provider: *models.Provider) !usize {
    const preset = try models.defaultOpenCodeHeaders(allocator);
    defer allocator.free(preset);
    var added: usize = 0;
    for (preset) |header| {
        if (findHeaderIndex(provider, header.key) != null) {
            var owned = header;
            owned.deinit(allocator);
            continue;
        }
        appendHeader(allocator, provider, header) catch |err| {
            var owned = header;
            owned.deinit(allocator);
            return err;
        };
        added += 1;
    }
    return added;
}

// ---------------------------------------------------------------------------
// View state
// ---------------------------------------------------------------------------

pub const ProvidersView = struct {
    allocator: std.mem.Allocator,
    selected: usize = 0,
    bulk_text: List(u8),
    pending_ping: ?PingTarget = null,
    ping_status: PingStatus = .idle,
    /// Header row under edit; equals headers.len means "new row".
    editing_header: ?usize = null,
    draft_key: List(u8),
    draft_value: List(u8),

    pub fn init(allocator: std.mem.Allocator) ProvidersView {
        return .{
            .allocator = allocator,
            .bulk_text = List(u8).init(allocator),
            .draft_key = List(u8).init(allocator),
            .draft_value = List(u8).init(allocator),
        };
    }

    pub fn deinit(self: *ProvidersView) void {
        self.bulk_text.deinit();
        self.draft_key.deinit();
        self.draft_value.deinit();
    }

    pub fn select(self: *ProvidersView, index: usize, provider_count: usize) void {
        self.selected = if (provider_count == 0) 0 else @min(index, provider_count - 1);
        self.editing_header = null;
        self.pending_ping = null;
        self.ping_status = .idle;
    }

    pub fn setBulkText(self: *ProvidersView, text: []const u8) !void {
        self.bulk_text.clearRetainingCapacity();
        try self.bulk_text.appendSlice(text);
    }

    pub fn clearBulk(self: *ProvidersView) void {
        self.bulk_text.clearRetainingCapacity();
    }

    /// Import the bulk textbox into the selected provider's pool. Clears
    /// the box when at least one key lands.
    pub fn applyBulkToSelected(self: *ProvidersView, providers: []models.Provider) !usize {
        if (self.selected >= providers.len) return error.NoProviderSelected;
        const added = try addBulkKeys(self.allocator, &providers[self.selected], self.bulk_text.items);
        if (added > 0) self.clearBulk();
        return added;
    }

    /// Snapshot a test-ping target; the worker executes it and reports back
    /// via markPingResult(). Only one ping is in flight per view.
    pub fn requestPing(self: *ProvidersView, providers: []const models.Provider, key_index: usize) ViewError!PingTarget {
        if (self.selected >= providers.len) return error.NoProviderSelected;
        if (key_index >= providers[self.selected].keys.len) return error.IndexOutOfBounds;
        const target = PingTarget{ .provider_index = self.selected, .key_index = key_index };
        self.pending_ping = target;
        self.ping_status = .requested;
        return target;
    }

    pub fn markPingResult(self: *ProvidersView, ok: bool) void {
        if (self.pending_ping == null) return;
        self.ping_status = if (ok) .ok else .failed;
    }

    pub fn clearPing(self: *ProvidersView) void {
        self.pending_ping = null;
        self.ping_status = .idle;
    }

    /// Load a header row (or a blank new row when index == headers.len)
    /// into the edit drafts.
    pub fn beginHeaderEdit(self: *ProvidersView, provider: *const models.Provider, index: usize) !void {
        if (index > provider.headers.len) return error.IndexOutOfBounds;
        self.draft_key.clearRetainingCapacity();
        self.draft_value.clearRetainingCapacity();
        if (index < provider.headers.len) {
            const header = provider.headers[index];
            try self.draft_key.appendSlice(header.key);
            try self.draft_value.appendSlice(header.value);
        }
        self.editing_header = index;
    }

    /// Commit drafts to the selected provider: set existing row or append.
    pub fn commitHeaderEdit(self: *ProvidersView, providers: []models.Provider) !void {
        const row = self.editing_header orelse return;
        if (self.selected >= providers.len) return error.NoProviderSelected;
        const provider = &providers[self.selected];
        if (row < provider.headers.len) {
            try setHeader(self.allocator, provider, row, self.draft_key.items, self.draft_value.items);
        } else if (row == provider.headers.len) {
            try addHeader(self.allocator, provider, self.draft_key.items, self.draft_value.items);
        } else {
            return error.IndexOutOfBounds;
        }
        self.editing_header = null;
    }

    pub fn cancelHeaderEdit(self: *ProvidersView) void {
        self.editing_header = null;
    }

    /// Headless snapshot: one card per provider with progress, key rows with
    /// masked keys + badges, headers table, and pending UI state.
    pub fn renderText(self: *const ProvidersView, writer: anytype, providers: []const models.Provider) !void {
        for (providers, 0..) |*provider, pi| {
            const summary = summarizeProvider(provider);
            try writer.print("{s} [{s}] {s}\n", .{
                if (pi == self.selected) ">" else " ",
                provider.prefix,
                provider.display_name,
            });
            try writer.print("  {s} — {s}\n", .{ provider.base_url, provider.description });
            try writer.print("  {d} / {d} Keys Healthy ", .{ summary.healthy, summary.total });
            try writeProgressBar(writer, summary, 20);
            try writer.writeAll("\n");
            for (provider.keys, 0..) |*key, ki| {
                const badge = badgeFor(key);
                const masked = maskKey(key.key);
                try writer.print("  key #{d} {s} [{s}] {s}\n", .{
                    ki + 1,
                    masked.slice(),
                    badge.label(),
                    if (key.enabled) "enabled" else "disabled",
                });
            }
            try writer.writeAll("  headers:\n");
            for (provider.headers, 0..) |*header, hi| {
                try writer.print("    #{d} {s}: {s}\n", .{ hi + 1, header.key, header.value });
            }
        }
        var bulk_lines: usize = 0;
        var bulk = std.mem.splitScalar(u8, self.bulk_text.items, '\n');
        while (bulk.next()) |_| bulk_lines += 1;
        try writer.print("bulk box: {d} bytes / {d} lines\n", .{ self.bulk_text.items.len, bulk_lines });
        if (self.pending_ping) |target| {
            try writer.print("ping: provider {d} key #{d} [{s}]\n", .{
                target.provider_index,
                target.key_index + 1,
                @tagName(self.ping_status),
            });
        }
    }
};

test "providers mask key vectors" {
    const t = std.testing;
    try t.expectEqualStrings("sk-…9f", maskKey("sk-abcdef9f").slice());
    try t.expectEqualStrings("…abcd", maskKey("abcd").slice());
    try t.expectEqualStrings("<empty>", maskKey("").slice());
    // Tail must not leak the head for short keys.
    try t.expect(std.mem.indexOf(u8, maskKey("secret12").slice(), "secret") == null);
}

test "providers bulk parse trims, skips blanks, dedupes in order" {
    const t = std.testing;
    var parsed = try parseBulkKeys(t.allocator, "  key1 \r\n\nkey2\nkey1\n\tkey3\r\nkey2\n");
    defer freeParsedKeys(&parsed);
    try t.expectEqual(@as(usize, 3), parsed.items.len);
    try t.expectEqualStrings("key1", parsed.items[0]);
    try t.expectEqualStrings("key2", parsed.items[1]);
    try t.expectEqualStrings("key3", parsed.items[2]);

    var empty = try parseBulkKeys(t.allocator, "\n  \r\n");
    defer freeParsedKeys(&empty);
    try t.expectEqual(@as(usize, 0), empty.items.len);
}

test "providers badges and health percent" {
    const t = std.testing;
    try t.expectEqualStrings("Healthy", KeyBadge.healthy.label());
    try t.expectEqualStrings("Cooldown", KeyBadge.cooling_down.label());
    try t.expectEqualStrings("Dead", KeyBadge.dead.label());
    try t.expectEqualStrings("Disabled", KeyBadge.disabled.label());
    try t.expectEqual(@as(u8, 0), (HealthSummary{}).percent());
    try t.expectEqual(@as(u8, 40), (HealthSummary{ .healthy = 2, .total = 5 }).percent());
}

test "providers progress bar exact rendering" {
    const t = std.testing;
    // writeProgressBar is duck-typed: pass &std.Io.Writer.Allocating(...).writer.
    var out = std.Io.Writer.Allocating.init(t.allocator);
    defer out.deinit();
    try writeProgressBar(&out.writer, HealthSummary{ .healthy = 8, .total = 10 }, 10);
    try t.expectEqualStrings("[########--] 80%", out.written());

    var out2 = std.Io.Writer.Allocating.init(t.allocator);
    defer out2.deinit();
    try writeProgressBar(&out2.writer, HealthSummary{}, 4);
    try t.expectEqualStrings("[----] 0%", out2.written());
}

fn makeTestProvider(allocator: std.mem.Allocator) !models.Provider {
    return .{
        .display_name = try allocator.dupe(u8, "Test Gateway"),
        .base_url = try allocator.dupe(u8, "https://example.com/v1/"),
        .prefix = try allocator.dupe(u8, "t/"),
        .description = try allocator.dupe(u8, "test provider"),
        .keys = try allocator.alloc(models.Key, 0),
        .headers = try allocator.alloc(models.CustomHeader, 0),
    };
}

test "providers bulk add, row actions, and headers against real models" {
    const t = std.testing;
    var provider = try makeTestProvider(t.allocator);
    defer provider.deinit(t.allocator);

    // 12 pasted lines, one blank, two dupes -> 10 fresh keys land at once.
    const added = try addBulkKeys(
        t.allocator,
        &provider,
        "k01\nk02\nk03\nk04\nk05\n\nk06\nk07\nk02\nk08\nk09\nk10\nk01\n",
    );
    try t.expectEqual(@as(usize, 10), added);
    try t.expectEqual(@as(usize, 10), provider.keys.len);

    // Re-import is a no-op (all dupes).
    try t.expectEqual(@as(usize, 0), try addBulkKeys(t.allocator, &provider, "k01\nk10\n"));

    // Row actions: disable one, kill one, delete one.
    try setKeyEnabled(&provider, 0, false);
    provider.keys[1].state = .CoolingDown;
    provider.keys[2].state = .Dead;
    try t.expectEqual(KeyBadge.disabled, badgeFor(&provider.keys[0]));
    try t.expectEqual(KeyBadge.cooling_down, badgeFor(&provider.keys[1]));
    try t.expectEqual(KeyBadge.dead, badgeFor(&provider.keys[2]));
    try t.expectEqual(KeyBadge.healthy, badgeFor(&provider.keys[3]));
    try t.expectEqual(@as(usize, 7), summarizeProvider(&provider).healthy);

    try removeKeyAt(t.allocator, &provider, 0);
    try t.expectEqual(@as(usize, 9), provider.keys.len);
    try t.expectEqualStrings("k02", provider.keys[0].key);
    try t.expectError(error.IndexOutOfBounds, setKeyEnabled(&provider, 99, true));

    // Headers editor: add, case-insensitive find, edit, remove.
    try addHeader(t.allocator, &provider, "X-Token", "abc");
    try t.expectEqual(@as(usize, 0), findHeaderIndex(&provider, "x-token").?);
    try setHeader(t.allocator, &provider, 0, "X-Token", "def");
    try t.expectEqualStrings("def", provider.headers[0].value);
    try t.expectError(error.EmptyHeaderKey, addHeader(t.allocator, &provider, "", "v"));
    try removeHeaderAt(t.allocator, &provider, 0);
    try t.expectEqual(@as(usize, 0), provider.headers.len);

    // OpenCode prefill is idempotent.
    try t.expectEqual(@as(usize, 5), try ensureOpenCodeHeaders(t.allocator, &provider));
    try t.expectEqual(@as(usize, 0), try ensureOpenCodeHeaders(t.allocator, &provider));
    try t.expectEqualStrings("opencode/1.18.26", provider.findHeader("User-Agent").?);
    try provider.validate();
}

test "providers view selection, bulk box, ping, and header drafts" {
    const t = std.testing;
    var providers = [_]models.Provider{
        try makeTestProvider(t.allocator),
        try makeTestProvider(t.allocator),
    };
    defer providers[0].deinit(t.allocator);
    defer providers[1].deinit(t.allocator);

    var view = ProvidersView.init(t.allocator);
    defer view.deinit();

    view.select(5, providers.len); // clamps to last provider
    try t.expectEqual(@as(usize, 1), view.selected);
    try t.expectError(error.NoProviderSelected, view.applyBulkToSelected(&[_]models.Provider{}));

    try view.setBulkText("a1\na2\na3\n");
    try t.expectEqual(@as(usize, 3), try view.applyBulkToSelected(&providers));
    try t.expectEqual(@as(usize, 0), view.bulk_text.items.len); // cleared on success
    try t.expectEqual(@as(usize, 3), providers[1].keys.len);
    try t.expectEqual(@as(usize, 0), providers[0].keys.len);

    const target = try view.requestPing(&providers, 2);
    try t.expectEqual(@as(usize, 1), target.provider_index);
    try t.expectEqualStrings("a3", try resolvePingKey(&providers, target));
    view.markPingResult(true);
    try t.expectEqual(PingStatus.ok, view.ping_status);
    try t.expectError(error.IndexOutOfBounds, view.requestPing(&providers, 9));

    // Header drafts: new row append, then edit of row 0.
    view.select(1, providers.len);
    try view.beginHeaderEdit(&providers[1], providers[1].headers.len);
    try view.draft_key.appendSlice("X-New");
    try view.draft_value.appendSlice("1");
    try view.commitHeaderEdit(&providers);
    try t.expectEqualStrings("1", providers[1].findHeader("X-New").?);
    try view.beginHeaderEdit(&providers[1], 0);
    try view.draft_value.appendSlice("-edited");
    try view.commitHeaderEdit(&providers);
    try t.expectEqualStrings("1-edited", providers[1].findHeader("X-New").?);
    view.cancelHeaderEdit();

    var out = std.Io.Writer.Allocating.init(t.allocator);
    defer out.deinit();
    try view.renderText(&out.writer, &providers);
    const text = out.written();
    try t.expect(std.mem.indexOf(u8, text, "3 / 3 Keys Healthy") != null);
    try t.expect(std.mem.indexOf(u8, text, "[Healthy]") != null);
}

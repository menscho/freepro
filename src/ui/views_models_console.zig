// src/ui/views_models_console.zig — Model Explorer + Live Request Console +
// Settings view-models (Wave1-Task10).
//
// What this file owns:
//   * Model Explorer table: Model Name (with provider prefix), Target
//     Provider, Upstream Name, Route Status, plus the search/filter box state
//     over the merged provider catalog.
//   * Live Request Console: scrolling tail over logger.Logger (color-coded
//     renderers, level filter, follow/pause).
//   * Settings panel: auto-start checkbox state, cooldown-secs stepper,
//     timeout-ms stepper, exact-entry text drafts, apply-to-config with
//     validation, and save/dirty tracking.
//
// Contracts matched (all owned by other agents, imported relatively):
//   models.Provider    { display_name, base_url, prefix, description, keys, headers }
//   models.Key         { key, state, last_used, cooldown_until, consecutive_errors, enabled }
//   models.KeyState    { Active, CoolingDown, Dead }
//   models.ProxyConfig { port, providers, auto_start, cooldown_secs, timeout_ms }
//   logger.Logger / logger.Subscriber / logger.LogLine / logger.Level /
//     logger.formatTimeOfDay                        (src/logger.zig)
//
// Note on list shapes: models.Provider.keys is a plain []Key slice (see
// src/models.zig), so this file indexes slices directly. It deliberately does
// NOT use `.items`, which only exists on ArrayList-style lists.
//
// GUI integration: std-only on purpose — no DVUI/httpz import — so the build
// never breaks on a GUI dependency. main.zig plugs renderModelsView() and
// renderConsoleSettings() into App.views; those adapters bind the state below
// to Ui primitives (label/button/textBox/dot). renderText()/renderAnsi() are
// the headless text renderers used by tests, the operator console, and any
// fallback terminal.
//
// Threading: the proxy thread only ever touches logger.Logger and
// metrics.Metrics (both internally synchronized). ModelsView / ConsoleView /
// SettingsState are GUI-thread owned; mutate them on one thread only.
//
// Memory: ModelsView owns its entries' strings and frees them in deinit().
// The provider/config data stays borrowed. ConsoleView copies log lines into
// inline logger.LogLine buffers (no allocation after init beyond list growth).

const std = @import("std");
const models = @import("../models.zig");
const logger = @import("../logger.zig");

fn List(comptime T: type) type {
    return std.array_list.Managed(T);
}

// ---------------------------------------------------------------------------
// Route status
// ---------------------------------------------------------------------------

/// Health of one catalog row as shown in the Route Status column.
pub const RouteStatus = enum {
    unknown,
    healthy,
    cooling_down,
    dead,

    pub fn label(self: RouteStatus) []const u8 {
        return switch (self) {
            .unknown => "Unknown",
            .healthy => "Healthy",
            .cooling_down => "Cooldown",
            .dead => "Dead",
        };
    }

    /// sRGB triple for status dots / badges in the native GUI.
    pub fn rgb(self: RouteStatus) [3]u8 {
        return switch (self) {
            .unknown => .{ 0x6b, 0x72, 0x80 },
            .healthy => .{ 0x22, 0xc5, 0x5e },
            .cooling_down => .{ 0xe5, 0xb8, 0x08 },
            .dead => .{ 0xef, 0x44, 0x44 },
        };
    }
};

/// Derive one provider's route status from its key pool:
/// Healthy when at least one key is enabled and Active; Cooldown when keys
/// exist and some are enabled but none is currently usable; Dead when every
/// key is disabled or Dead; Unknown when the pool is empty.
pub fn statusForProvider(provider: *const models.Provider) RouteStatus {
    if (provider.keys.len == 0) return .unknown;
    var usable: usize = 0;
    var restorable: usize = 0;
    for (provider.keys) |*key| {
        if (!key.enabled) continue;
        if (key.state == .Active) {
            usable += 1;
        } else if (key.state == .CoolingDown) {
            restorable += 1;
        }
    }
    if (usable > 0) return .healthy;
    if (restorable > 0) return .cooling_down;
    return .dead;
}

// ---------------------------------------------------------------------------
// Model catalog
// ---------------------------------------------------------------------------

/// One row of the merged catalog: the client-facing prefixed id, which
/// provider serves it, the upstream id (prefix stripped), and route health.
pub const ModelEntry = struct {
    prefixed_name: []u8,
    provider_display: []u8,
    upstream_name: []u8,
    prefix: []u8,
    status: RouteStatus = .unknown,

    pub fn deinit(self: *ModelEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.prefixed_name);
        allocator.free(self.provider_display);
        allocator.free(self.upstream_name);
        allocator.free(self.prefix);
        self.* = undefined;
    }
};

pub const StatusFilter = enum {
    all,
    healthy,
    cooling_down,
    dead,
    unknown,

    pub fn label(self: StatusFilter) []const u8 {
        return switch (self) {
            .all => "All",
            .healthy => "Healthy",
            .cooling_down => "Cooldown",
            .dead => "Dead",
            .unknown => "Unknown",
        };
    }

    pub const all_filters: [5]StatusFilter = .{ .all, .healthy, .cooling_down, .dead, .unknown };
};

pub const max_query_len: usize = 256;
/// Maximum rows the text renderer prints per call (GUI adapters page too).
pub const max_text_rows: usize = 200;

pub const ModelsView = struct {
    allocator: std.mem.Allocator,
    entries: List(ModelEntry),
    query_buf: [max_query_len]u8 = [_]u8{0} ** max_query_len,
    query_len: usize = 0,
    filter: StatusFilter = .all,
    /// Cached indices into entries, filtered + sorted by prefixed name.
    /// Rebuilt by refresh()/setQuery()/setFilter().
    visible: List(usize),

    pub fn init(allocator: std.mem.Allocator) ModelsView {
        return .{
            .allocator = allocator,
            .entries = List(ModelEntry).init(allocator),
            .visible = List(usize).init(allocator),
        };
    }

    pub fn deinit(self: *ModelsView) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit();
        self.visible.deinit();
    }

    pub fn query(self: *const ModelsView) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    /// Replace the search text (truncated to max_query_len) and refilter.
    pub fn setQuery(self: *ModelsView, text: []const u8) !void {
        const n = @min(text.len, self.query_buf.len);
        @memcpy(self.query_buf[0..n], text[0..n]);
        self.query_len = n;
        try self.rebuildVisible();
    }

    pub fn clearQuery(self: *ModelsView) !void {
        self.query_len = 0;
        try self.rebuildVisible();
    }

    pub fn setFilter(self: *ModelsView, filter: StatusFilter) !void {
        self.filter = filter;
        try self.rebuildVisible();
    }

    pub fn findEntry(self: *const ModelsView, prefixed_name: []const u8) ?usize {
        for (self.entries.items, 0..) |*entry, i| {
            if (std.mem.eql(u8, entry.prefixed_name, prefixed_name)) return i;
        }
        return null;
    }

    /// Insert a row or refresh an existing one (display/upstream/prefix may
    /// change when a provider is reconfigured). Statuses are always derived
    /// afterwards by refresh(), so upsert takes none.
    pub fn upsert(
        self: *ModelsView,
        prefixed_name: []const u8,
        provider_display: []const u8,
        upstream_name: []const u8,
        prefix: []const u8,
    ) !void {
        if (self.findEntry(prefixed_name)) |i| {
            const entry = &self.entries.items[i];
            try self.replaceString(&entry.provider_display, provider_display);
            try self.replaceString(&entry.upstream_name, upstream_name);
            try self.replaceString(&entry.prefix, prefix);
            return;
        }
        const entry = ModelEntry{
            .prefixed_name = try self.allocator.dupe(u8, prefixed_name),
            .provider_display = try self.allocator.dupe(u8, provider_display),
            .upstream_name = try self.allocator.dupe(u8, upstream_name),
            .prefix = try self.allocator.dupe(u8, prefix),
        };
        try self.entries.append(entry);
    }

    fn replaceString(self: *ModelsView, slot: *[]u8, value: []const u8) !void {
        if (std.mem.eql(u8, slot.*, value)) return;
        const owned = try self.allocator.dupe(u8, value);
        self.allocator.free(slot.*);
        slot.* = owned;
    }

    /// Feed one provider's /v1/models aggregation into the catalog. Called by
    /// the proxy agent whenever it merges upstream model lists; new rows start
    /// Unknown until the next refresh() derives their status from key health.
    pub fn setModels(
        self: *ModelsView,
        prefix: []const u8,
        provider_display: []const u8,
        upstream_names: []const []const u8,
    ) !void {
        for (upstream_names) |upstream| {
            const prefixed = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, upstream });
            defer self.allocator.free(prefixed);
            try self.upsert(prefixed, provider_display, upstream, prefix);
        }
    }

    /// Reconcile with the borrowed provider list: drop rows whose prefix no
    /// longer exists, refresh display names + statuses, and rebuild the
    /// visible cache. Call once per GUI frame (or after config edits).
    pub fn refresh(self: *ModelsView, providers: []const models.Provider) !void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = &self.entries.items[i];
            var known: ?*const models.Provider = null;
            for (providers) |*provider| {
                if (std.mem.eql(u8, provider.prefix, entry.prefix)) {
                    known = provider;
                    break;
                }
            }
            if (known) |provider| {
                try self.replaceString(&entry.provider_display, provider.display_name);
                entry.status = statusForProvider(provider);
                i += 1;
            } else {
                var dead = self.entries.orderedRemove(i);
                dead.deinit(self.allocator);
            }
        }
        try self.rebuildVisible();
    }

    /// True when the row passes the status filter and the search box matches
    /// the prefixed name, upstream name, or provider display name
    /// (case-insensitive substring).
    pub fn matches(self: *const ModelsView, entry: *const ModelEntry) bool {
        switch (self.filter) {
            .all => {},
            .healthy => if (entry.status != .healthy) return false,
            .cooling_down => if (entry.status != .cooling_down) return false,
            .dead => if (entry.status != .dead) return false,
            .unknown => if (entry.status != .unknown) return false,
        }
        const q = self.query();
        if (q.len == 0) return true;
        return containsInsensitive(entry.prefixed_name, q) or
            containsInsensitive(entry.upstream_name, q) or
            containsInsensitive(entry.provider_display, q);
    }

    fn rebuildVisible(self: *ModelsView) !void {
        self.visible.clearRetainingCapacity();
        for (self.entries.items, 0..) |*entry, index| {
            if (self.matches(entry)) try self.visible.append(index);
        }
        std.mem.sort(usize, self.visible.items, self.entries.items, entryLessThan);
    }

    /// Headless snapshot: filter summary plus the table, newest sort first by
    /// prefixed name. Prints at most max_text_rows rows.
    pub fn renderText(self: *const ModelsView, writer: anytype) !void {
        try writer.print("models: {d} shown / {d} indexed", .{ self.visible.items.len, self.entries.items.len });
        if (self.query_len > 0) try writer.print("  search: \"{s}\"", .{self.query()});
        if (self.filter != .all) try writer.print("  filter: {s}", .{self.filter.label()});
        try writer.writeAll("\n");
        if (self.entries.items.len == 0) {
            try writer.writeAll("(catalog empty - model lists appear as providers report /v1/models)\n");
            return;
        }
        if (self.visible.items.len == 0) {
            try writer.writeAll("(no models match the current search/filter)\n");
            return;
        }
        try writer.writeAll("Model Name                       | Target Provider    | Upstream Name              | Status\n");
        try writer.writeAll("-------------------------------+--------------------+----------------------------+--------\n");
        const n = @min(self.visible.items.len, max_text_rows);
        for (self.visible.items[0..n]) |index| {
            const entry = &self.entries.items[index];
            try writeCell(writer, entry.prefixed_name, 30);
            try writer.writeAll(" | ");
            try writeCell(writer, entry.provider_display, 18);
            try writer.writeAll(" | ");
            try writeCell(writer, entry.upstream_name, 26);
            try writer.writeAll(" | ");
            try writer.writeAll(entry.status.label());
            try writer.writeAll("\n");
        }
        if (self.visible.items.len > n) {
            try writer.print("... +{d} more\n", .{self.visible.items.len - n});
        }
    }
};

fn entryLessThan(entries: []ModelEntry, a: usize, b: usize) bool {
    return std.mem.order(u8, entries[a].prefixed_name, entries[b].prefixed_name) == .lt;
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var hit = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                hit = false;
                break;
            }
        }
        if (hit) return true;
    }
    return false;
}

fn writeCell(writer: anytype, text: []const u8, width: usize) !void {
    if (text.len >= width) {
        if (width > 3) {
            try writer.writeAll(text[0 .. width - 3]);
            try writer.writeAll("...");
        } else {
            try writer.writeAll(text[0..@min(text.len, width)]);
        }
        return;
    }
    try writer.writeAll(text);
    var i: usize = text.len;
    while (i < width) : (i += 1) try writer.writeByte(' ');
}

// ---------------------------------------------------------------------------
// Live request console
// ---------------------------------------------------------------------------

/// Rows retained in the on-screen tail window.
pub const tail_window: usize = 200;
/// Lines pulled from the logger ring per poll() call.
pub const poll_batch: usize = 64;

pub const ConsoleView = struct {
    feed: logger.Subscriber,
    tail: List(logger.LogLine),
    /// When false, poll() skips draining so the view freezes; backlog
    /// accumulates in the logger ring and is picked up on resume (entries
    /// overwritten while paused are skipped, per Subscriber semantics).
    follow: bool = true,
    min_level: logger.Level = .info,

    pub fn init(allocator: std.mem.Allocator, log: *logger.Logger) ConsoleView {
        return .{
            .feed = log.subscriber(),
            .tail = List(logger.LogLine).init(allocator),
        };
    }

    pub fn deinit(self: *ConsoleView) void {
        self.tail.deinit();
    }

    /// Restart the visible tail from the live end, ignoring backlog (e.g. on
    /// view open).
    pub fn skipBacklog(self: *ConsoleView) void {
        self.feed.skipBacklog();
        self.tail.clearRetainingCapacity();
    }

    pub fn setFollow(self: *ConsoleView, follow: bool) void {
        self.follow = follow;
    }

    pub fn setMinLevel(self: *ConsoleView, level: logger.Level) void {
        self.min_level = level;
    }

    pub fn clear(self: *ConsoleView) void {
        self.tail.clearRetainingCapacity();
    }

    fn levelRank(level: logger.Level) u8 {
        return switch (level) {
            .info => 0,
            .request => 1,
            .failover => 2,
            .warn => 3,
            .err => 4,
        };
    }

    /// Pull newly arrived lines into the tail window. Call once per GUI frame.
    pub fn poll(self: *ConsoleView) void {
        if (!self.follow) return;
        var batch: [poll_batch]logger.LogLine = undefined;
        const n = self.feed.poll(&batch);
        for (batch[0..n]) |line| {
            if (levelRank(line.level) < levelRank(self.min_level)) continue;
            if (self.tail.items.len >= tail_window) _ = self.tail.orderedRemove(0);
            self.tail.append(line) catch break;
        }
    }

    /// Plain snapshot: `HH:MM:SS [LEVEL] message` per line, oldest first.
    pub fn renderText(self: *const ConsoleView, writer: anytype) !void {
        if (self.tail.items.len == 0) {
            try writer.writeAll("(console empty - request lines appear here)\n");
            return;
        }
        for (self.tail.items) |*line| {
            var clock: [8]u8 = undefined;
            const stamp = logger.formatTimeOfDay(line.timestamp_ms, &clock);
            try writer.print("{s} [{s}] {s}\n", .{ stamp, line.level.tag(), line.text() });
        }
    }

    /// Color-coded snapshot for ANSI terminals: one SGR color per level.
    pub fn renderAnsi(self: *const ConsoleView, writer: anytype) !void {
        if (self.tail.items.len == 0) {
            try writer.writeAll("(console empty - request lines appear here)\n");
            return;
        }
        for (self.tail.items) |*line| {
            var clock: [8]u8 = undefined;
            const stamp = logger.formatTimeOfDay(line.timestamp_ms, &clock);
            try writer.print("{s}{s} [{s}] {s}\x1b[0m\n", .{
                levelAnsi(line.level),
                stamp,
                line.level.tag(),
                line.text(),
            });
        }
    }
};

fn levelAnsi(level: logger.Level) []const u8 {
    return switch (level) {
        .info => "\x1b[90m",
        .request => "\x1b[36m",
        .failover => "\x1b[33m",
        .warn => "\x1b[33;1m",
        .err => "\x1b[31m",
    };
}

// ---------------------------------------------------------------------------
// Settings panel
// ---------------------------------------------------------------------------

pub const min_cooldown_secs: u64 = 5;
pub const max_cooldown_secs: u64 = 3_600;
pub const cooldown_step_secs: u64 = 5;
pub const min_timeout_ms: u32 = 1_000;
pub const max_timeout_ms: u32 = 300_000;
pub const timeout_step_ms: u32 = 1_000;

/// Edit state for the Settings panel. The ProxyConfig stays the source of
/// truth; this struct holds checkbox/stepper state plus exact-entry text
/// drafts. dirty tracks unsaved changes for the save-to-config button.
pub const SettingsState = struct {
    auto_start: bool = false,
    cooldown_secs: u64 = models.default_cooldown_secs,
    timeout_ms: u32 = models.default_timeout_ms,
    dirty: bool = false,
    cooldown_text: [8]u8 = [_]u8{0} ** 8,
    cooldown_len: usize = 0,
    timeout_text: [8]u8 = [_]u8{0} ** 8,
    timeout_len: usize = 0,

    pub fn initFromConfig(cfg: *const models.ProxyConfig) SettingsState {
        var self = SettingsState{};
        self.syncFromConfig(cfg);
        return self;
    }

    /// Copy config values into the panel and clear dirty.
    pub fn syncFromConfig(self: *SettingsState, cfg: *const models.ProxyConfig) void {
        self.auto_start = cfg.auto_start;
        self.cooldown_secs = std.math.clamp(cfg.cooldown_secs, min_cooldown_secs, max_cooldown_secs);
        self.timeout_ms = std.math.clamp(cfg.timeout_ms, min_timeout_ms, max_timeout_ms);
        self.syncText();
        self.dirty = false;
    }

    /// Mark the panel dirty without changing values (used after edits that
    /// go straight into the config, e.g. the operator-console commands).
    pub fn markDirty(self: *SettingsState) void {
        self.dirty = true;
    }

    pub fn markClean(self: *SettingsState) void {
        self.dirty = false;
    }

    fn syncText(self: *SettingsState) void {
        const cd = std.fmt.bufPrint(self.cooldown_text[0..], "{d}", .{self.cooldown_secs}) catch "60";
        self.cooldown_len = cd.len;
        const to = std.fmt.bufPrint(self.timeout_text[0..], "{d}", .{self.timeout_ms}) catch "30000";
        self.timeout_len = to.len;
    }

    pub fn toggleAutoStart(self: *SettingsState) void {
        self.auto_start = !self.auto_start;
        self.dirty = true;
    }

    /// Move the cooldown stepper by delta_steps (usually +/-1). Clamps into
    /// range and always resyncs the text draft.
    pub fn stepCooldown(self: *SettingsState, delta_steps: i64) void {
        const next: i128 = @as(i128, @intCast(self.cooldown_secs)) +
            @as(i128, @intCast(delta_steps)) * @as(i128, @intCast(cooldown_step_secs));
        const clamped = std.math.clamp(next, @as(i128, min_cooldown_secs), @as(i128, max_cooldown_secs));
        self.cooldown_secs = @intCast(clamped);
        self.syncText();
        self.dirty = true;
    }

    pub fn stepTimeout(self: *SettingsState, delta_steps: i64) void {
        const next: i128 = @as(i128, @intCast(self.timeout_ms)) +
            @as(i128, @intCast(delta_steps)) * @as(i128, @intCast(timeout_step_ms));
        const clamped = std.math.clamp(next, @as(i128, min_timeout_ms), @as(i128, max_timeout_ms));
        self.timeout_ms = @intCast(clamped);
        self.syncText();
        self.dirty = true;
    }

    /// Commit the cooldown text draft. Invalid input restores the draft from
    /// the current value and returns models.ValidateError.InvalidCooldown.
    pub fn commitCooldownText(self: *SettingsState) models.ValidateError!void {
        const raw = self.cooldown_text[0..self.cooldown_len];
        const value = std.fmt.parseInt(u64, raw, 10) catch {
            self.syncText();
            return models.ValidateError.InvalidCooldown;
        };
        if (value < min_cooldown_secs or value > max_cooldown_secs) {
            self.syncText();
            return models.ValidateError.InvalidCooldown;
        }
        self.cooldown_secs = value;
        self.syncText();
        self.dirty = true;
    }

    /// Commit the timeout text draft. Invalid input restores the draft and
    /// returns models.ValidateError.InvalidTimeout.
    pub fn commitTimeoutText(self: *SettingsState) models.ValidateError!void {
        const raw = self.timeout_text[0..self.timeout_len];
        const value = std.fmt.parseInt(u32, raw, 10) catch {
            self.syncText();
            return models.ValidateError.InvalidTimeout;
        };
        if (value < min_timeout_ms or value > max_timeout_ms) {
            self.syncText();
            return models.ValidateError.InvalidTimeout;
        }
        self.timeout_ms = value;
        self.syncText();
        self.dirty = true;
    }

    /// Apply the panel values onto the config after validating the whole
    /// document. The config is untouched when validation fails.
    pub fn applyToConfig(self: *const SettingsState, cfg: *models.ProxyConfig) models.ValidateError!void {
        var next = cfg.*;
        next.auto_start = self.auto_start;
        next.cooldown_secs = self.cooldown_secs;
        next.timeout_ms = self.timeout_ms;
        try next.validate();
        cfg.* = next;
    }

    /// Headless snapshot of the panel.
    pub fn renderText(self: *const SettingsState, writer: anytype) !void {
        try writer.print("settings: [{s}] auto-start proxy on launch\n", .{if (self.auto_start) "x" else " "});
        try writer.print(
            "cooldown: {d}s (range {d}..{d}, step {d})  [-] [{s}] [+]\n",
            .{ self.cooldown_secs, min_cooldown_secs, max_cooldown_secs, cooldown_step_secs, self.cooldown_text[0..self.cooldown_len] },
        );
        try writer.print(
            "timeout:  {d}ms (range {d}..{d}, step {d})  [-] [{s}] [+]\n",
            .{ self.timeout_ms, min_timeout_ms, max_timeout_ms, timeout_step_ms, self.timeout_text[0..self.timeout_len] },
        );
        try writer.writeAll(if (self.dirty) "state: unsaved changes — press Save to config\n" else "state: in sync with config\n");
    }
};

// ---------------------------------------------------------------------------
// Unit tests (the project ships embedded tests in every module)
// ---------------------------------------------------------------------------

test "route status derives from key pool health" {
    const t = std.testing;
    var empty_keys = [_]models.Key{};
    var active = [_]models.Key{.{ .key = "k1" }};
    var cooling = [_]models.Key{.{ .key = "k1", .state = .CoolingDown, .cooldown_until = 9999 }};
    var dead = [_]models.Key{.{ .key = "k1", .state = .Dead }};
    var disabled = [_]models.Key{.{ .key = "k1", .enabled = false }};
    var mixed = [_]models.Key{
        .{ .key = "k1", .state = .Dead },
        .{ .key = "k2", .state = .CoolingDown, .cooldown_until = 9999 },
    };

    const p_empty = models.Provider{
        .display_name = "E",
        .base_url = "https://x.example/",
        .prefix = "e/",
        .description = "",
        .keys = &empty_keys,
        .headers = &[_]models.CustomHeader{},
    };
    var p_active = models.Provider{
        .display_name = "A",
        .base_url = "https://x.example/",
        .prefix = "a/",
        .description = "",
        .keys = &active,
        .headers = &[_]models.CustomHeader{},
    };
    var p_cooling = models.Provider{
        .display_name = "C",
        .base_url = "https://x.example/",
        .prefix = "c/",
        .description = "",
        .keys = &cooling,
        .headers = &[_]models.CustomHeader{},
    };
    var p_dead = models.Provider{
        .display_name = "D",
        .base_url = "https://x.example/",
        .prefix = "d/",
        .description = "",
        .keys = &dead,
        .headers = &[_]models.CustomHeader{},
    };
    var p_disabled = models.Provider{
        .display_name = "X",
        .base_url = "https://x.example/",
        .prefix = "x/",
        .description = "",
        .keys = &disabled,
        .headers = &[_]models.CustomHeader{},
    };
    var p_mixed = models.Provider{
        .display_name = "M",
        .base_url = "https://x.example/",
        .prefix = "m/",
        .description = "",
        .keys = &mixed,
        .headers = &[_]models.CustomHeader{},
    };

    try t.expectEqual(RouteStatus.unknown, statusForProvider(&p_empty));
    try t.expectEqual(RouteStatus.healthy, statusForProvider(&p_active));
    try t.expectEqual(RouteStatus.cooling_down, statusForProvider(&p_cooling));
    try t.expectEqual(RouteStatus.dead, statusForProvider(&p_dead));
    try t.expectEqual(RouteStatus.dead, statusForProvider(&p_disabled));
    try t.expectEqual(RouteStatus.cooling_down, statusForProvider(&p_mixed));
    try t.expectEqualStrings("Cooldown", RouteStatus.cooling_down.label());
}

test "catalog upsert dedupes, refresh prunes and derives status" {
    const t = std.testing;
    var view = ModelsView.init(t.allocator);
    defer view.deinit();

    try view.upsert("oc/alpha", "OpenCode Zen", "alpha", "oc/");
    try view.upsert("oc/alpha", "OpenCode Zen v2", "alpha", "oc/");
    try view.upsert("kilo/beta", "Kilo Gateway", "beta", "kilo/");
    try t.expectEqual(@as(usize, 2), view.entries.items.len);
    try t.expectEqualStrings("OpenCode Zen v2", view.entries.items[0].provider_display);

    var oc_keys = [_]models.Key{.{ .key = "k1" }};
    var providers = [_]models.Provider{
        .{
            .display_name = "OpenCode Zen",
            .base_url = "https://opencode.ai/zen/v1/",
            .prefix = "oc/",
            .description = "",
            .keys = &oc_keys,
            .headers = &[_]models.CustomHeader{},
        },
    };
    try view.refresh(&providers);
    // kilo/ gone (prefix unknown), oc row re-derived as healthy.
    try t.expectEqual(@as(usize, 1), view.entries.items.len);
    try t.expectEqualStrings("OpenCode Zen", view.entries.items[0].provider_display);
    try t.expectEqual(RouteStatus.healthy, view.entries.items[0].status);
    try t.expectEqual(@as(usize, 1), view.visible.items.len);
}

test "catalog search matches three fields case-insensitively and sorts" {
    const t = std.testing;
    var view = ModelsView.init(t.allocator);
    defer view.deinit();

    try view.upsert("oc/zulu", "OpenCode Zen", "zulu", "oc/");
    try view.upsert("oc/alpha", "OpenCode Zen", "alpha", "oc/");
    try view.upsert("kilo/beta", "Kilo Gateway", "beta", "kilo/");
    try view.refresh(&[_]models.Provider{});
    try t.expectEqual(@as(usize, 0), view.entries.items.len); // all pruned

    try view.upsert("oc/zulu", "OpenCode Zen", "zulu", "oc/");
    try view.upsert("oc/alpha", "OpenCode Zen", "alpha", "oc/");
    try view.upsert("kilo/beta", "Kilo Gateway", "beta", "kilo/");
    // Sorted by prefixed name without any query.
    try view.setQuery("");
    try t.expectEqual(@as(usize, 3), view.visible.items.len);
    try t.expectEqualStrings("kilo/beta", view.entries.items[view.visible.items[0]].prefixed_name);
    try t.expectEqualStrings("oc/alpha", view.entries.items[view.visible.items[1]].prefixed_name);

    try view.setQuery("ALPHA");
    try t.expectEqual(@as(usize, 1), view.visible.items.len);
    try view.setQuery("kilo");
    try t.expectEqual(@as(usize, 1), view.visible.items.len);
    try view.setQuery("gateway");
    try t.expectEqual(@as(usize, 1), view.visible.items.len);
    try view.setQuery("no-such-model");
    try t.expectEqual(@as(usize, 0), view.visible.items.len);

    // Status filter over derived rows.
    var oc_keys = [_]models.Key{.{ .key = "k1" }};
    var providers = [_]models.Provider{
        .{
            .display_name = "OpenCode Zen",
            .base_url = "https://opencode.ai/zen/v1/",
            .prefix = "oc/",
            .description = "",
            .keys = &oc_keys,
            .headers = &[_]models.CustomHeader{},
        },
        .{
            .display_name = "Kilo Gateway",
            .base_url = "https://api.kilo.ai/api/gateway",
            .prefix = "kilo/",
            .description = "",
            .keys = &[_]models.Key{},
            .headers = &[_]models.CustomHeader{},
        },
    };
    try view.setQuery("");
    try view.setFilter(.healthy);
    try view.refresh(&providers);
    try t.expectEqual(@as(usize, 2), view.visible.items.len);
    try view.setFilter(.unknown);
    try t.expectEqual(@as(usize, 1), view.visible.items.len);
    try t.expectEqualStrings("kilo/beta", view.entries.items[view.visible.items[0]].prefixed_name);
}

test "catalog setModels builds prefixed rows and renders text" {
    const t = std.testing;
    var view = ModelsView.init(t.allocator);
    defer view.deinit();

    const names = [_][]const u8{ "gpt-4o", "claude-3-5-sonnet" };
    try view.setModels("oc/", "OpenCode Zen", &names);
    try t.expectEqual(@as(usize, 2), view.entries.items.len);
    try t.expectEqualStrings("oc/gpt-4o", view.entries.items[0].prefixed_name);
    try t.expectEqualStrings("gpt-4o", view.entries.items[0].upstream_name);

    // Feeding the same list again must not duplicate rows.
    try view.setModels("oc/", "OpenCode Zen", &names);
    try t.expectEqual(@as(usize, 2), view.entries.items.len);

    var raw: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&raw);
    try view.refresh(&[_]models.Provider{});
    try view.renderText(&fbs);
    try t.expect(std.mem.indexOf(u8, fbs.buffered(), "(catalog empty") != null);

    var raw2: [2048]u8 = undefined;
    var fbs2 = std.Io.Writer.fixed(&raw2);
    try view.setModels("oc/", "OpenCode Zen", &names);
    try view.setQuery("");
    try view.renderText(&fbs2);
    try t.expect(std.mem.indexOf(u8, fbs2.buffered(), "oc/gpt-4o") != null);
    try t.expect(std.mem.indexOf(u8, fbs2.buffered(), "Target Provider") != null);
}

test "console polls, filters levels, pauses, and renders color" {
    const t = std.testing;
    var log = logger.Logger.init();
    var view = ConsoleView.init(t.allocator, &log);
    defer view.deinit();

    log.info("boot", .{});
    log.logRequest("POST", "/v1/chat/completions", 200, 12);
    log.failover(2, 429, 3);
    log.err("boom", .{});
    view.poll();
    try t.expectEqual(@as(usize, 4), view.tail.items.len);

    view.setMinLevel(.warn);
    view.clear();
    view.skipBacklog();
    log.info("quiet", .{});
    log.err("loud", .{});
    view.poll();
    try t.expectEqual(@as(usize, 1), view.tail.items.len);
    try t.expectEqualStrings("loud", view.tail.items[0].text());

    // Pause freezes the tail; resume picks up only what survived the ring.
    view.setFollow(false);
    log.err("while-paused", .{});
    log.failover(5, 503, 6);
    view.poll();
    try t.expectEqual(@as(usize, 1), view.tail.items.len);
    view.setFollow(true);
    view.setMinLevel(.info);
    view.poll();
    try t.expectEqual(@as(usize, 3), view.tail.items.len);

    var raw: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&raw);
    try view.renderText(&fbs);
    try t.expect(std.mem.indexOf(u8, fbs.buffered(), "[FAILOVER]") != null);
    var raw_ansi: [2048]u8 = undefined;
    var fbs_ansi = std.Io.Writer.fixed(&raw_ansi);
    try view.renderAnsi(&fbs_ansi);
    try t.expect(std.mem.indexOf(u8, fbs_ansi.buffered(), "\x1b[") != null);
    try t.expect(std.mem.indexOf(u8, fbs_ansi.buffered(), "\x1b[0m") != null);
}

test "settings steppers clamp, drafts validate, apply round-trips" {
    const t = std.testing;
    var providers = [_]models.Provider{};
    var cfg = models.ProxyConfig{
        .port = 8080,
        .providers = &providers,
        .auto_start = false,
        .cooldown_secs = 60,
        .timeout_ms = 30_000,
    };
    var s = SettingsState.initFromConfig(&cfg);
    try t.expect(!s.dirty);

    s.stepCooldown(-100);
    try t.expectEqual(min_cooldown_secs, s.cooldown_secs);
    s.stepCooldown(10_000);
    try t.expectEqual(max_cooldown_secs, s.cooldown_secs);
    s.stepTimeout(-1_000_000);
    try t.expectEqual(min_timeout_ms, s.timeout_ms);
    s.stepTimeout(1_000_000);
    try t.expectEqual(max_timeout_ms, s.timeout_ms);
    try t.expect(s.dirty);

    // Invalid drafts restore the text and report an error.
    @memcpy(s.cooldown_text[0..3], "abc");
    s.cooldown_len = 3;
    try t.expectError(models.ValidateError.InvalidCooldown, s.commitCooldownText());
    try t.expectEqualStrings("3600", s.cooldown_text[0..s.cooldown_len]);

    const ok_cd = try std.fmt.bufPrint(s.cooldown_text[0..], "{d}", .{@as(u64, 90)});
    s.cooldown_len = ok_cd.len;
    try s.commitCooldownText();
    try t.expectEqual(@as(u64, 90), s.cooldown_secs);

    const ok_to = try std.fmt.bufPrint(s.timeout_text[0..], "{d}", .{@as(u32, 45_000)});
    s.timeout_len = ok_to.len;
    try s.commitTimeoutText();
    try t.expectEqual(@as(u32, 45_000), s.timeout_ms);

    s.toggleAutoStart();
    try s.applyToConfig(&cfg);
    try t.expect(cfg.auto_start);
    try t.expectEqual(@as(u64, 90), cfg.cooldown_secs);
    try t.expectEqual(@as(u32, 45_000), cfg.timeout_ms);
    try cfg.validate();

    s.markClean();
    s.syncFromConfig(&cfg);
    try t.expect(!s.dirty);
    try t.expectEqual(@as(u64, 90), s.cooldown_secs);

    var raw: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&raw);
    try s.renderText(&fbs);
    try t.expect(std.mem.indexOf(u8, fbs.buffered(), "auto-start") != null);
    try t.expect(std.mem.indexOf(u8, fbs.buffered(), "in sync") != null);
}

// src/ui/views_dashboard.zig — Dashboard overview (Home) view-model (Wave1-Task09).
//
// What this file owns: the five metric cards (Active Providers, Keys Loaded,
// Healthy Keys, In-Flight, Total Served), the live traffic sparkline sourced
// from the metrics latency ring, the activity feed window sourced from the
// logger ring, and the top-bar server state (running flag, port, base URL).
//
// Contracts matched:
//   models.Provider { display_name, base_url, prefix, description,
//                     keys: []Key, headers: []CustomHeader } (plain slices)
//   models.Key      { key, state, last_used, cooldown_until, consecutive_errors, enabled }
//   models.KeyState { Active, CoolingDown, Dead }
//   metrics.Metrics { snapshot(), sparkline() }    (src/metrics.zig)
//   logger.Logger   { subscriber() }, logger.Subscriber.poll(), LogLine.text(),
//                   logger.formatTimeOfDay()        (src/logger.zig)
//
// GUI integration: this file is std-only on purpose — no DVUI/httpz import —
// so the build never breaks on a GUI dependency. It exposes plain data
// (DashboardStats, [5]MetricCard, normalized sparkline samples, LogLine rows)
// plus a headless text renderer (renderText) used by tests and any fallback
// console. The GUI owner calls DashboardView.refresh() once per frame and
// draws from stats / cards / spark / recent with native widgets.
//
// Threading: refresh() borrows *metrics.Metrics and *logger.Logger (both are
// internally synchronized). DashboardView itself is not thread-safe; only
// touch it from the GUI thread.
//
// Memory: DashboardView owns `recent` (copied LogLine rows, inline buffers)
// and frees it in deinit(). Providers, Metrics, and Logger stay borrowed.

const std = @import("std");
const models = @import("../models.zig");
const metrics = @import("../metrics.zig");
const logger = @import("../logger.zig");

fn List(comptime T: type) type {
    return std.array_list.Managed(T);
}

/// Samples kept for the traffic sparkline (oldest first).
pub const spark_width: usize = 64;
/// Activity rows kept visible in the dashboard feed window.
pub const feed_window: usize = 30;

/// Block glyphs for text-mode sparkline rendering, index 0..7.
pub const bar_glyphs: [8][]const u8 = .{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

/// Map a normalized 0..1 sample to a glyph index 0..7.
pub fn barIndex(value_0_to_1: f32) usize {
    const clamped = std.math.clamp(value_0_to_1, 0, 1);
    return @min(7, @as(usize, @intFromFloat(clamped * 8)));
}

pub const MetricKind = enum {
    active_providers,
    keys_loaded,
    healthy_keys,
    in_flight,
    total_served,
};

pub const MetricCard = struct {
    kind: MetricKind,
    title: []const u8,
    value: u64,
    hint: []const u8,

    pub fn titleOf(kind: MetricKind) []const u8 {
        return switch (kind) {
            .active_providers => "Active Providers",
            .keys_loaded => "Keys Loaded",
            .healthy_keys => "Healthy Keys",
            .in_flight => "In-Flight",
            .total_served => "Total Served",
        };
    }

    pub fn hintOf(kind: MetricKind) []const u8 {
        return switch (kind) {
            .active_providers => "providers with a usable key",
            .keys_loaded => "keys across all providers",
            .healthy_keys => "enabled and ready to serve",
            .in_flight => "requests being proxied now",
            .total_served => "requests since launch",
        };
    }
};

pub const DashboardStats = struct {
    active_providers: usize = 0,
    keys_loaded: usize = 0,
    healthy_keys: usize = 0,
    in_flight: u64 = 0,
    total_served: u64 = 0,
    total_errors: u64 = 0,
    total_failovers: u64 = 0,
    avg_latency_ms: f64 = 0,

    /// The five dashboard cards in display order for native-widget binding.
    pub fn cards(self: *const DashboardStats) [5]MetricCard {
        return .{
            .{
                .kind = .active_providers,
                .title = MetricCard.titleOf(.active_providers),
                .value = self.active_providers,
                .hint = MetricCard.hintOf(.active_providers),
            },
            .{
                .kind = .keys_loaded,
                .title = MetricCard.titleOf(.keys_loaded),
                .value = self.keys_loaded,
                .hint = MetricCard.hintOf(.keys_loaded),
            },
            .{
                .kind = .healthy_keys,
                .title = MetricCard.titleOf(.healthy_keys),
                .value = self.healthy_keys,
                .hint = MetricCard.hintOf(.healthy_keys),
            },
            .{
                .kind = .in_flight,
                .title = MetricCard.titleOf(.in_flight),
                .value = self.in_flight,
                .hint = MetricCard.hintOf(.in_flight),
            },
            .{
                .kind = .total_served,
                .title = MetricCard.titleOf(.total_served),
                .value = self.total_served,
                .hint = MetricCard.hintOf(.total_served),
            },
        };
    }
};

/// A key counts toward Healthy Keys only when enabled and Active.
pub fn isUsableKey(key: *const models.Key) bool {
    return key.enabled and key.state == .Active;
}

/// Fold provider key pools plus a metrics snapshot into dashboard counters.
/// A provider counts as active when it holds at least one usable key.
pub fn collectStats(providers: []const models.Provider, snap: *const metrics.Snapshot) DashboardStats {
    var stats = DashboardStats{
        .in_flight = snap.active_inflight,
        .total_served = snap.total_requests,
        .total_errors = snap.total_errors,
        .total_failovers = snap.total_failovers,
        .avg_latency_ms = snap.avg_latency_ms,
    };
    for (providers) |*provider| {
        var usable: usize = 0;
        for (provider.keys) |*key| {
            stats.keys_loaded += 1;
            if (isUsableKey(key)) {
                stats.healthy_keys += 1;
                usable += 1;
            }
        }
        if (usable > 0) stats.active_providers += 1;
    }
    return stats;
}

pub const DashboardView = struct {
    allocator: std.mem.Allocator,
    stats: DashboardStats = .{},
    feed: logger.Subscriber,
    recent: List(logger.LogLine),
    spark: [spark_width]f32 = [_]f32{0} ** spark_width,
    spark_len: usize = 0,
    server_running: bool = false,
    port: u16 = 8080,
    prev_total: u64 = 0,
    served_delta: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, log: *logger.Logger, port: u16) DashboardView {
        return .{
            .allocator = allocator,
            .feed = log.subscriber(),
            .recent = List(logger.LogLine).init(allocator),
            .port = port,
        };
    }

    pub fn deinit(self: *DashboardView) void {
        self.recent.deinit();
    }

    /// Drop backlog and restart the visible feed from the live tail.
    /// Call when the dashboard view opens.
    pub fn skipBacklog(self: *DashboardView) void {
        self.feed.skipBacklog();
        self.recent.clearRetainingCapacity();
    }

    /// Pull fresh counters, sparkline samples, and log lines. Call once per
    /// GUI frame with the borrowed provider list and metrics instance.
    pub fn refresh(self: *DashboardView, providers: []const models.Provider, m: *metrics.Metrics) void {
        const snap = m.snapshot();
        self.stats = collectStats(providers, &snap);
        self.served_delta = snap.total_requests -| self.prev_total;
        self.prev_total = snap.total_requests;
        self.spark_len = m.sparkline(&self.spark);

        var batch: [feed_window]logger.LogLine = undefined;
        const n = self.feed.poll(&batch);
        for (batch[0..n]) |line| {
            if (self.recent.items.len >= feed_window) _ = self.recent.orderedRemove(0);
            self.recent.append(line) catch break;
        }
    }

    /// Owned base URL for the top-bar "Copy Base URL" button. Caller frees.
    pub fn copyBaseUrl(self: *const DashboardView, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1", .{self.port});
    }

    /// Headless snapshot: top bar, five cards, sparkline, activity feed.
    pub fn renderText(self: *const DashboardView, writer: anytype) !void {
        if (self.server_running) {
            try writer.print("server: RUNNING on 127.0.0.1:{d} (+{d} since last refresh)\n", .{ self.port, self.served_delta });
        } else {
            try writer.print("server: STOPPED (port {d})\n", .{self.port});
        }
        for (self.stats.cards()) |card| {
            try writer.print("[{s}] {d} - {s}\n", .{ card.title, card.value, card.hint });
        }
        try writer.writeAll("traffic: ");
        if (self.spark_len == 0) {
            try writer.writeAll("(no samples yet)");
        } else {
            for (self.spark[0..self.spark_len]) |sample| {
                try writer.writeAll(bar_glyphs[barIndex(sample)]);
            }
            try writer.print("  avg {d:.1}ms, errors {d}, failovers {d}", .{
                self.stats.avg_latency_ms,
                self.stats.total_errors,
                self.stats.total_failovers,
            });
        }
        try writer.writeAll("\n--- activity ---\n");
        if (self.recent.items.len == 0) {
            try writer.writeAll("(feed empty)\n");
        } else {
            for (self.recent.items) |*line| {
                var clock: [8]u8 = undefined;
                const stamp = logger.formatTimeOfDay(line.timestamp_ms, &clock);
                try writer.print("{s} [{s}] {s}\n", .{ stamp, line.level.tag(), line.text() });
            }
        }
    }
};

test "dashboard bar index boundaries" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 0), barIndex(0));
    try t.expectEqual(@as(usize, 0), barIndex(-1));
    try t.expectEqual(@as(usize, 7), barIndex(1));
    try t.expectEqual(@as(usize, 7), barIndex(99));
    try t.expectEqual(@as(usize, 4), barIndex(0.5));
    try t.expectEqual(@as(usize, 8), bar_glyphs.len);
}

test "dashboard cards carry the five spec titles in order" {
    const t = std.testing;
    var stats = DashboardStats{
        .active_providers = 2,
        .keys_loaded = 10,
        .healthy_keys = 8,
        .in_flight = 3,
        .total_served = 42,
    };
    const cards_view = stats.cards();
    try t.expectEqual(@as(usize, 5), cards_view.len);
    try t.expectEqualStrings("Active Providers", cards_view[0].title);
    try t.expectEqualStrings("Keys Loaded", cards_view[1].title);
    try t.expectEqualStrings("Healthy Keys", cards_view[2].title);
    try t.expectEqualStrings("In-Flight", cards_view[3].title);
    try t.expectEqualStrings("Total Served", cards_view[4].title);
    try t.expectEqual(@as(u64, 2), cards_view[0].value);
    try t.expectEqual(@as(u64, 42), cards_view[4].value);
}

test "dashboard refresh with empty providers renders text" {
    const t = std.testing;
    var log = logger.Logger.init();
    var m = metrics.Metrics.init();
    m.record(null, 120, 200);
    log.logRequest("POST", "/v1/chat/completions", 200, 120);

    var view = DashboardView.init(t.allocator, &log, 8080);
    defer view.deinit();
    view.server_running = true;
    view.refresh(&[_]models.Provider{}, &m);

    try t.expectEqual(@as(u64, 1), view.stats.total_served);
    try t.expectEqual(@as(usize, 1), view.spark_len);
    try t.expectEqual(@as(usize, 1), view.recent.items.len);

    // renderText is duck-typed: pass &std.Io.Writer.Allocating(...).writer.
    var out = std.Io.Writer.Allocating.init(t.allocator);
    defer out.deinit();
    try view.renderText(&out.writer);
    const text = out.written();
    try t.expect(text.len > 0);
    try t.expect(std.mem.indexOf(u8, text, "RUNNING on 127.0.0.1:8080") != null);
    try t.expect(std.mem.indexOf(u8, text, "[Healthy Keys] 0") != null);

    const url = try view.copyBaseUrl(t.allocator);
    defer t.allocator.free(url);
    try t.expectEqualStrings("http://127.0.0.1:8080/v1", url);
}

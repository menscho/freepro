// src/metrics.zig — request counters, per-provider tallies, latency ring + sparkline.
//
// std only (no httpz/DVUI dependency). Thread-safe: totals are atomics, the
// latency ring and per-provider counts are guarded by a mutex. Designed to be
// owned by main.zig (e.g. `var metrics = Metrics.init();`) and shared by
// reference with the proxy workers and the UI dashboard.
//
// Integration: proxy calls begin() before dispatch and end() after upstream
// responds; UI polls snapshot() and sparkline() each frame. Rotator calls
// noteFailover() whenever it rotates keys.

const std = @import("std");
const models = @import("models.zig");

/// Mutual exclusion for the latency ring and per-provider counts. Prefers the
/// blocking OS mutex where the standard library provides one
/// (`std.Thread.Mutex` on Zig <= 0.15) and falls back to a yield-spinning
/// lock on toolchains that removed it (0.16 only ships the
/// `std.atomic.Mutex` spinlock). Critical sections are tiny and never block
/// on I/O while held, so a spin is only ever brief.
const Mutex = if (@hasDecl(std.Thread, "Mutex"))
    std.Thread.Mutex
else
    struct {
        inner: std.atomic.Mutex = .unlocked,

        pub fn lock(self: *@This()) void {
            while (!self.inner.tryLock()) {
                std.Thread.yield() catch {};
            }
        }

        pub fn unlock(self: *@This()) void {
            self.inner.unlock();
        }
    };

pub const max_providers: usize = 16;
pub const latency_cap: usize = 120;

pub const Snapshot = struct {
    total_requests: u64,
    active_inflight: u64,
    total_errors: u64,
    total_failovers: u64,
    provider_count: usize,
    per_provider: [max_providers]u64,
    samples: usize,
    avg_latency_ms: f64,
    max_latency_ms: u64,
    last_latency_ms: u64,
};

pub const usage_days_cap: usize = 30;

/// One UTC day of token usage (live, mutex-guarded side of metrics).
pub const UsageDay = struct {
    day: u32 = 0,
    input: u64 = 0,
    output: u64 = 0,
    cached: u64 = 0,
    requests: u64 = 0,
};

pub const UsageSnapshot = struct {
    total_in: u64,
    total_out: u64,
    total_cached: u64,
    total_requests: u64,
    days: []UsageDay, // slice into metrics-owned storage; copy out fast
};

pub const usage_models_cap = 128;
const ModelBucket = struct {
    name: [256]u8 = @splat(0),
    name_len: usize = 0,
    input: u64 = 0,
    output: u64 = 0,
    cached: u64 = 0,
    requests: u64 = 0,
    days: [usage_days_cap]UsageDay = @splat(.{}),
};

fn addDay(days: []UsageDay, value: UsageDay) void {
    var slot: usize = 0;
    for (days, 0..) |d, i| {
        if (d.requests != 0 and d.day == value.day) {
            slot = i;
            break;
        }
        if (d.requests == 0 or d.day < days[slot].day) slot = i;
    }
    if (days[slot].day != value.day) days[slot] = .{ .day = value.day };
    days[slot].input += value.input;
    days[slot].output += value.output;
    days[slot].cached += value.cached;
    days[slot].requests += value.requests;
}

pub const Metrics = struct {
    total_requests: std.atomic.Value(u64),
    active_inflight: std.atomic.Value(u64),
    total_errors: std.atomic.Value(u64),
    total_failovers: std.atomic.Value(u64),
    mu: Mutex,
    provider_count: usize,
    per_provider: [max_providers]u64,
    // Lifetime token totals (atomic: hot path).
    usage_in: std.atomic.Value(u64),
    usage_out: std.atomic.Value(u64),
    usage_cached: std.atomic.Value(u64),
    usage_requests: std.atomic.Value(u64),
    // Per-UTC-day buckets, ring of the last usage_days_cap days.
    usage_days: [usage_days_cap]UsageDay = [_]UsageDay{.{}} ** usage_days_cap,
    usage_day_head: usize = 0,
    model_buckets: [usage_models_cap]ModelBucket = @splat(.{}),
    model_count: usize = 0,
    latencies: [latency_cap]u64,
    lat_head: usize,
    lat_len: usize,

    pub fn init() Metrics {
        return .{
            .total_requests = std.atomic.Value(u64).init(0),
            .active_inflight = std.atomic.Value(u64).init(0),
            .total_errors = std.atomic.Value(u64).init(0),
            .total_failovers = std.atomic.Value(u64).init(0),
            .usage_in = std.atomic.Value(u64).init(0),
            .usage_out = std.atomic.Value(u64).init(0),
            .usage_cached = std.atomic.Value(u64).init(0),
            .usage_requests = std.atomic.Value(u64).init(0),
            .mu = .{},
            .provider_count = 0,
            .per_provider = [_]u64{0} ** max_providers,
            .latencies = [_]u64{0} ** latency_cap,
            .lat_head = 0,
            .lat_len = 0,
        };
    }

    /// Optional shared instance for apps that prefer a global over plumbing.
    pub var global: Metrics = Metrics.init();

    /// Clamp how many per-provider slots are considered live (index < n).
    pub fn setProviderCount(self: *Metrics, n: usize) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.provider_count = @min(n, max_providers);
    }

    /// Mark the start of one proxied request. Always pair with end().
    pub fn begin(self: *Metrics) void {
        _ = self.total_requests.fetchAdd(1, .monotonic);
        _ = self.active_inflight.fetchAdd(1, .monotonic);
    }

    /// Mark the end of one proxied request. provider_idx may be null when the
    /// request never routed (e.g. unknown prefix). Status >= 400 counts as error.
    pub fn end(self: *Metrics, provider_idx: ?usize, latency_ms: u64, status: u16) void {
        _ = self.active_inflight.fetchSub(1, .monotonic);
        if (status >= 400) _ = self.total_errors.fetchAdd(1, .monotonic);

        self.mu.lock();
        defer self.mu.unlock();
        if (provider_idx) |idx| {
            if (idx < max_providers) {
                self.per_provider[idx] += 1;
                if (idx >= self.provider_count and self.provider_count < max_providers) {
                    self.provider_count = idx + 1;
                }
            }
        }
        self.latencies[self.lat_head] = latency_ms;
        self.lat_head = (self.lat_head + 1) % latency_cap;
        if (self.lat_len < latency_cap) self.lat_len += 1;
    }

    /// Record token usage from one completed request. Thread-safe; the day
    /// bucket is keyed on days-since-epoch so UTC rollover starts a new slot.
    pub fn recordUsage(self: *Metrics, input: u64, output: u64, cached: u64, day: u32) void {
        _ = self.usage_in.fetchAdd(input, .monotonic);
        _ = self.usage_out.fetchAdd(output, .monotonic);
        _ = self.usage_cached.fetchAdd(cached, .monotonic);
        _ = self.usage_requests.fetchAdd(1, .monotonic);
        self.mu.lock();
        defer self.mu.unlock();
        // Find or create the bucket for this day.
        var slot: ?usize = null;
        var i: usize = 0;
        while (i < usage_days_cap) : (i += 1) {
            if (self.usage_days[i].day == day and self.usage_days[i].requests != 0) {
                slot = i;
                break;
            }
        }
        if (slot == null) {
            // Reuse an empty slot or evict the oldest.
            var oldest: usize = self.usage_day_head;
            var oldest_day: u32 = std.math.maxInt(u32);
            i = 0;
            while (i < usage_days_cap) : (i += 1) {
                if (self.usage_days[i].requests == 0) {
                    slot = i;
                    break;
                }
                if (self.usage_days[i].day < oldest_day) {
                    oldest_day = self.usage_days[i].day;
                    oldest = i;
                }
            }
            if (slot == null) slot = oldest;
            self.usage_days[slot.?] = .{ .day = day };
        }
        const b = &self.usage_days[slot.?];
        b.input += input;
        b.output += output;
        b.cached += cached;
        b.requests += 1;
    }

    /// Usage totals plus the non-empty day buckets (oldest first). Caller
    /// provides a destination buffer of at least usage_days_cap entries.
    pub fn usageSnapshot(self: *Metrics, days_out: []UsageDay) UsageSnapshot {
        self.mu.lock();
        defer self.mu.unlock();
        var n: usize = 0;
        var i: usize = 0;
        while (i < usage_days_cap) : (i += 1) {
            if (self.usage_days[i].requests != 0) {
                if (n == days_out.len) break;
                days_out[n] = self.usage_days[i];
                n += 1;
            }
        }
        // Oldest first.
        std.mem.sort(UsageDay, days_out[0..n], {}, struct {
            fn lt(_: void, a: UsageDay, b: UsageDay) bool {
                return a.day < b.day;
            }
        }.lt);
        return .{
            .total_in = self.usage_in.load(.monotonic),
            .total_out = self.usage_out.load(.monotonic),
            .total_cached = self.usage_cached.load(.monotonic),
            .total_requests = self.usage_requests.load(.monotonic),
            .days = days_out[0..n],
        };
    }

    /// Seed totals + day buckets from a persisted config (startup path).
    /// Live counters continue from these values.
    pub fn restoreUsage(
        self: *Metrics,
        total_in: u64,
        total_out: u64,
        total_cached: u64,
        total_requests: u64,
        days: []const @import("models.zig").UsageDay,
    ) void {
        _ = self.usage_in.store(total_in, .monotonic);
        _ = self.usage_out.store(total_out, .monotonic);
        _ = self.usage_cached.store(total_cached, .monotonic);
        _ = self.usage_requests.store(total_requests, .monotonic);
        self.mu.lock();
        defer self.mu.unlock();
        const n = @min(days.len, usage_days_cap);
        for (days[0..n], 0..) |d, i| {
            self.usage_days[i] = .{ .day = d.day, .input = d.input, .output = d.output, .cached = d.cached, .requests = d.requests };
        }
    }

    pub fn recordModelUsage(self: *Metrics, model: []const u8, input: u64, output: u64, cached: u64, day: u32) void {
        self.recordUsage(input, output, cached, day);
        self.mu.lock();
        defer self.mu.unlock();
        const slot = self.modelSlot(model);
        const m = &self.model_buckets[slot];
        m.input += input;
        m.output += output;
        m.cached += cached;
        m.requests += 1;
        addDay(&m.days, .{ .day = day, .input = input, .output = output, .cached = cached, .requests = 1 });
    }

    fn modelSlot(self: *Metrics, name: []const u8) usize {
        for (self.model_buckets[0..self.model_count], 0..) |m, i| {
            if (std.mem.eql(u8, m.name[0..m.name_len], name)) return i;
        }
        const overflow = name.len > 256 or self.model_count >= usage_models_cap - 1 or std.mem.eql(u8, name, "__other_models__");
        const actual = if (overflow) "__other_models__" else name;
        const index = if (overflow) usage_models_cap - 1 else self.model_count;
        if (!overflow) self.model_count += 1;
        const m = &self.model_buckets[index];
        @memcpy(m.name[0..actual.len], actual);
        m.name_len = actual.len;
        return index;
    }

    pub fn modelUsageSnapshot(self: *Metrics, a: std.mem.Allocator) ![]models.UsageModel {
        self.mu.lock();
        defer self.mu.unlock();
        var out: std.ArrayList(models.UsageModel) = .empty;
        errdefer {
            for (out.items) |*m| m.deinit(a);
            out.deinit(a);
        }
        for (self.model_buckets) |m| {
            if (m.requests == 0) continue;
            var days: std.ArrayList(models.UsageDay) = .empty;
            errdefer days.deinit(a);
            for (m.days) |d| {
                if (d.requests != 0) try days.append(a, .{ .day = d.day, .input = d.input, .output = d.output, .cached = d.cached, .requests = d.requests });
            }
            const name = try a.dupe(u8, m.name[0..m.name_len]);
            errdefer a.free(name);
            const owned_days = try days.toOwnedSlice(a);
            errdefer a.free(owned_days);
            try out.append(a, .{ .model = name, .input = m.input, .output = m.output, .cached = m.cached, .requests = m.requests, .days = owned_days });
        }
        return out.toOwnedSlice(a);
    }

    pub fn syncConfig(self: *Metrics, a: std.mem.Allocator, cfg: *models.ProxyConfig) !void {
        const model_usage = try self.modelUsageSnapshot(a);
        errdefer {
            for (model_usage) |*m| m.deinit(a);
            a.free(model_usage);
        }
        var buf: [usage_days_cap]UsageDay = undefined;
        const snap = self.usageSnapshot(&buf);
        const days = try a.alloc(models.UsageDay, snap.days.len);
        for (snap.days, 0..) |d, i| days[i] = .{ .day = d.day, .input = d.input, .output = d.output, .cached = d.cached, .requests = d.requests };
        for (cfg.usage_models) |*m| m.deinit(a);
        if (cfg.usage_models.len != 0) a.free(cfg.usage_models);
        if (cfg.usage_days.len != 0) a.free(cfg.usage_days);
        cfg.usage_models = model_usage;
        cfg.usage_days = days;
        cfg.usage_in = snap.total_in;
        cfg.usage_out = snap.total_out;
        cfg.usage_cached = snap.total_cached;
        cfg.usage_requests = snap.total_requests;
    }

    pub fn restoreConfig(self: *Metrics, cfg: models.ProxyConfig) void {
        self.restoreUsage(cfg.usage_in, cfg.usage_out, cfg.usage_cached, cfg.usage_requests, cfg.usage_days);
        self.mu.lock();
        defer self.mu.unlock();
        self.model_count = 0;
        self.model_buckets = @splat(.{});
        for (cfg.usage_models) |saved| {
            const m = &self.model_buckets[self.modelSlot(saved.model)];
            m.input += saved.input;
            m.output += saved.output;
            m.cached += saved.cached;
            m.requests += saved.requests;
            for (saved.days) |d| addDay(&m.days, .{ .day = d.day, .input = d.input, .output = d.output, .cached = d.cached, .requests = d.requests });
        }
    }

    /// Convenience for non-streamed bookkeeping: begin + end in one call.
    pub fn record(self: *Metrics, provider_idx: ?usize, latency_ms: u64, status: u16) void {
        self.begin();
        self.end(provider_idx, latency_ms, status);
    }

    /// Called by the rotator every time it swaps to a new key mid-request.
    pub fn noteFailover(self: *Metrics) void {
        _ = self.total_failovers.fetchAdd(1, .monotonic);
    }

    pub fn total(self: *Metrics) u64 {
        return self.total_requests.load(.monotonic);
    }

    pub fn inflight(self: *Metrics) u64 {
        return self.active_inflight.load(.monotonic);
    }

    pub fn snapshot(self: *Metrics) Snapshot {
        self.mu.lock();
        defer self.mu.unlock();
        var sum: u64 = 0;
        var max: u64 = 0;
        for (0..self.lat_len) |i| {
            const v = self.latencies[(self.lat_head + latency_cap - self.lat_len + i) % latency_cap];
            sum += v;
            if (v > max) max = v;
        }
        const last: u64 = if (self.lat_len == 0)
            0
        else
            self.latencies[(self.lat_head + latency_cap - 1) % latency_cap];
        return .{
            .total_requests = self.total_requests.load(.monotonic),
            .active_inflight = self.active_inflight.load(.monotonic),
            .total_errors = self.total_errors.load(.monotonic),
            .total_failovers = self.total_failovers.load(.monotonic),
            .provider_count = self.provider_count,
            .per_provider = self.per_provider,
            .samples = self.lat_len,
            .avg_latency_ms = if (self.lat_len == 0) 0 else @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(self.lat_len)),
            .max_latency_ms = max,
            .last_latency_ms = last,
        };
    }

    /// Copy raw latency samples (ms), oldest first. Returns samples written.
    pub fn copyLatencies(self: *Metrics, out: []u64) usize {
        self.mu.lock();
        defer self.mu.unlock();
        const n = @min(out.len, self.lat_len);
        for (0..n) |i| {
            out[i] = self.latencies[(self.lat_head + latency_cap - self.lat_len + i) % latency_cap];
        }
        return n;
    }

    /// Fill `out` with normalized 0..1 values (oldest first) for sparkline
    /// rendering; each sample is divided by the window max (flat 0.5 when empty
    /// or all-zero). Returns samples written.
    pub fn sparkline(self: *Metrics, out: []f32) usize {
        self.mu.lock();
        defer self.mu.unlock();
        const n = @min(out.len, self.lat_len);
        if (n == 0) return 0;
        var max: u64 = 0;
        for (0..self.lat_len) |i| {
            const v = self.latencies[(self.lat_head + latency_cap - self.lat_len + i) % latency_cap];
            if (v > max) max = v;
        }
        if (max == 0) {
            @memset(out[0..n], 0.5);
            return n;
        }
        const fmax: f32 = @floatFromInt(max);
        for (0..n) |i| {
            const v: f32 = @floatFromInt(self.latencies[(self.lat_head + latency_cap - self.lat_len + i) % latency_cap]);
            out[i] = v / fmax;
        }
        return n;
    }

    pub fn reset(self: *Metrics) void {
        self.total_requests.store(0, .monotonic);
        self.active_inflight.store(0, .monotonic);
        self.total_errors.store(0, .monotonic);
        self.total_failovers.store(0, .monotonic);
        self.mu.lock();
        defer self.mu.unlock();
        self.provider_count = 0;
        @memset(&self.per_provider, 0);
        @memset(&self.latencies, 0);
        self.lat_head = 0;
        self.lat_len = 0;
    }
};

test "metrics record + snapshot + sparkline" {
    var m = Metrics.init();
    m.setProviderCount(2);
    m.record(0, 100, 200);
    m.record(1, 300, 429);
    m.noteFailover();
    const s = m.snapshot();
    try std.testing.expectEqual(@as(u64, 2), s.total_requests);
    try std.testing.expectEqual(@as(u64, 0), s.active_inflight);
    try std.testing.expectEqual(@as(u64, 1), s.total_errors);
    try std.testing.expectEqual(@as(u64, 1), s.total_failovers);
    try std.testing.expectEqual(@as(u64, 1), s.per_provider[0]);
    try std.testing.expectEqual(@as(u64, 1), s.per_provider[1]);
    try std.testing.expectEqual(@as(usize, 2), s.samples);
    try std.testing.expectEqual(@as(f64, 200.0), s.avg_latency_ms);
    try std.testing.expectEqual(@as(u64, 300), s.max_latency_ms);

    var out: [8]f32 = undefined;
    const n = m.sparkline(&out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0 / 300.0), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[1], 1e-5);

    m.begin();
    try std.testing.expectEqual(@as(u64, 1), m.inflight());
    m.end(null, 50, 200);
    try std.testing.expectEqual(@as(u64, 0), m.inflight());
    try std.testing.expectEqual(@as(u64, 3), m.total());

    m.reset();
    try std.testing.expectEqual(@as(u64, 0), m.snapshot().total_requests);
}

test "model usage keeps 30 daily buckets and lifetime totals across save and restore" {
    const a = std.testing.allocator;
    var m = Metrics.init();
    for (1..36) |d| m.recordModelUsage("oc/muse", 100, 20, 40, @intCast(d));
    m.recordModelUsage("other/muse", 200, 50, 75, 35);
    var cfg: models.ProxyConfig = .{};
    defer cfg.deinit(a);
    try m.syncConfig(a, &cfg);
    try std.testing.expectEqual(@as(u64, 3700), cfg.usage_in);
    try std.testing.expectEqual(@as(u64, 750), cfg.usage_out);
    try std.testing.expectEqual(@as(usize, 30), cfg.usage_days.len);
    try std.testing.expectEqual(@as(usize, 2), cfg.usage_models.len);
    try std.testing.expectEqual(@as(usize, 30), cfg.usage_models[0].days.len);
    for (cfg.usage_models[0].days) |day| try std.testing.expect(day.day >= 6);
    var copy = try cfg.clone(a);
    defer copy.deinit(a);
    var restored = Metrics.init();
    restored.restoreConfig(copy);
    restored.recordModelUsage("oc/muse", 7, 3, 2, 35);
    try restored.syncConfig(a, &copy);
    try std.testing.expectEqual(@as(u64, 3707), copy.usage_in);
    try std.testing.expectEqual(@as(u64, 3507), copy.usage_models[0].input);
    try std.testing.expectEqual(@as(u64, 36), copy.usage_models[0].requests);
    var tiny: [1]UsageDay = undefined;
    try std.testing.expectEqual(@as(usize, 1), restored.usageSnapshot(&tiny).days.len);
}

test "legacy token totals survive new model attribution" {
    const a = std.testing.allocator;
    var m = Metrics.init();
    m.restoreConfig(.{ .usage_in = 900, .usage_out = 100, .usage_requests = 10 });
    m.recordModelUsage("oc/new", 40, 10, 15, 30000);
    var cfg: models.ProxyConfig = .{};
    defer cfg.deinit(a);
    try m.syncConfig(a, &cfg);
    try std.testing.expectEqual(@as(u64, 940), cfg.usage_in);
    try std.testing.expectEqual(@as(u64, 40), cfg.usage_models[0].input);
    try std.testing.expectEqual(@as(u64, 11), cfg.usage_requests);
}

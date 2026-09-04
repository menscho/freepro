// src/rotator.zig — Thread-safe API-key pool: round-robin rotation with
// failure backoff (429 / 401 / 403 / timeout) for the freepro local proxy.
//
// Concurrency model: the rotator borrows a shared `models.ProxyConfig` and
// mutates key health in place under a single mutex, so the proxy thread, the
// GUI thread, and tests all observe one consistent pool. Key secrets and the
// provider list stay owned by the config owner; the only allocation owned
// here is the per-provider round-robin cursor table.
//
// Dependencies: standard library only (no httpz / DVUI needed). Imports only
// `@import("models.zig")`. Compiles on Zig 0.13.x through 0.16.x:
//   * mutex: `std.Thread.Mutex` where present, else a yield-spinning lock
//     over the `std.atomic.Mutex` spinlock (critical sections are tiny and
//     never block on I/O while held, so a spin is only ever brief).
//   * clock: `std.time.timestamp()` where present, else a direct OS read
//     (Windows `RtlGetSystemTimePrecise`, otherwise libc `clock_gettime`).
//
// Outcome semantics delegate to the shared classifiers in models.zig so the
// proxy and the rotator can never disagree:
//   2xx                  -> markSuccess (reset counters, revive to Active)
//   401 / 403            -> markDead (stays Dead until re-enabled/revived)
//   429 / 408 / 5xx      -> markCooldown for `cooldown_secs` (except 501,
//                           which like other 4xx counts a soft fault)
//   timeout / transport  -> markCooldown for `cooldown_secs` (reported either
//                           as null via reportResult or as status 0 via the
//                           proxy bridge, which only forwards u16)
//   other statuses       -> soft fault; escalates to a cooldown after
//                           `max_consecutive_errors` consecutive failures.
//
// Typical proxy-thread flow per upstream attempt:
//   const sel = rot.nextHealthy(provider_idx) orelse return error.AllKeysExhausted;
//   const status: ?u16 = forwardUpstream(...); // null on timeout / transport error
//   rot.reportResult(sel.provider_index, sel.key_index, status);
// Retry with the next key while `nextHealthy` keeps returning non-null, and
// only surface an upstream error once every key is exhausted. When a report
// moves a key out of rotation (Dead / CoolingDown), the proxy should call
// `metrics.noteFailover()` itself — the rotator deliberately does not import
// metrics so the dependency arrow stays one-way (proxy -> rotator).
const std = @import("std");
const builtin = @import("builtin");
const models = @import("models.zig");

/// Re-exported for call sites that want the state type without importing
/// models directly.
pub const KeyState = models.KeyState;

/// Soft faults (other 4xx, 501, unknown codes) escalate to a cooldown after
/// this many consecutive failures. Classified failures (2xx / 401 / 403 /
/// 429 / 408 / 5xx) apply immediately and never consult this threshold.
pub const default_max_consecutive_errors: u32 = 3;

/// A selected key, ready to dispatch upstream.
pub const KeySelection = struct {
    provider_index: usize,
    key_index: usize,
};

/// Per-provider (or global) pool health. `total` always equals
/// `active + cooling_down + dead + disabled`. Disabled keys are counted only
/// in `disabled`, never in a state bucket.
pub const HealthCounts = struct {
    total: usize = 0,
    active: usize = 0,
    cooling_down: usize = 0,
    dead: usize = 0,
    disabled: usize = 0,

    /// Keys currently eligible for rotation (enabled and Active, treating
    /// expired cooldowns as active — mirroring the next selection).
    pub fn healthy(self: HealthCounts) usize {
        return self.active;
    }
};

/// Lock-free copy of one key's state for status badges / logs.
pub const KeySnapshot = struct {
    state: KeyState,
    enabled: bool,
    consecutive_errors: u32,
    last_used: i64,
    cooldown_until: i64,
    cooldown_remaining_secs: i64,
};

/// Outcome of a single key ping. `status` carries the upstream HTTP status
/// when the probe got one; `ok` with a null status means "reachable, no
/// status to report" (soft success: clears soft errors and lifts cooldowns,
/// but never revives a Dead key by itself).
pub const PingResult = struct {
    ok: bool,
    latency_ms: u64 = 0,
    status: ?u16 = null,
};

/// Synchronous probe supplied by the owner (proxy layer): given a key secret
/// and the provider base URL, perform a cheap upstream request and report the
/// outcome. Must be thread-safe and must NOT call back into this Rotator (the
/// pool lock is released while it runs, but re-entry can still deadlock a
/// non-recursive mutex — keep the handler non-reentrant regardless).
pub const PingFn = *const fn (key: []const u8, base_url: []const u8) PingResult;

pub const PingError = error{
    NoPingHandler,
    InvalidProvider,
    InvalidKey,
};

/// Wall-clock source in unix seconds. Injectable so tests are deterministic
/// (see `setClock`); production defaults to `realtimeClock`.
pub const ClockFn = *const fn () i64;

/// Seconds since epoch from libc clock_gettime (POSIX only; Windows uses
/// RtlGetSystemTimePrecise above). Zig 0.16 spells the timespec fields
/// `sec`/`nsec` on every libc.
fn posixRealtimeSec() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return ts.sec;
}

fn posixRealtimeMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divFloor(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn realtimeClock() i64 {
    if (@hasDecl(std.time, "timestamp")) {
        return std.time.timestamp(); // Zig <= 0.15
    }
    // Zig 0.16 removed std.time's wall clock (it lives behind Io now); read
    // the OS clock directly so the rotator stays Io-free.
    if (builtin.os.tag == .windows) {
        // 100ns ticks since 1601-01-01; 11_644_473_600s = 1601 -> 1970.
        const ticks_100ns: i64 = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        return @divFloor(ticks_100ns, 10_000_000) - 11_644_473_600;
    }
    return posixRealtimeSec();
}

/// Mutual exclusion for the pool. Prefers the blocking OS mutex where the
/// standard library provides one (`std.Thread.Mutex` on Zig <= 0.15) and
/// falls back to a yield-spinning lock on toolchains that removed it (0.16
/// only ships the `std.atomic.Mutex` spinlock). No path locks twice: public
/// methods lock once and delegate to `*Locked` cores.
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

pub const Rotator = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: *models.ProxyConfig,
    mutex: Mutex = .{},
    cursors: []usize = &.{},
    ping_handler: ?PingFn = null,
    max_consecutive_errors: u32 = default_max_consecutive_errors,
    clock: ClockFn = realtimeClock,

    pub fn init(allocator: std.mem.Allocator, config: *models.ProxyConfig) !Self {
        var self = Self{ .allocator = allocator, .config = config };
        try self.ensureCursorsLocked();
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cursors);
        self.cursors = &.{};
    }

    /// Grow the cursor table after providers were added/removed elsewhere.
    /// Selection paths grow it automatically; call this after bulk edits so
    /// the next selection never reallocates under load.
    pub fn syncProviderCount(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.ensureCursorsLocked();
    }

    fn ensureCursorsLocked(self: *Self) !void {
        const n = self.config.providers.len;
        if (self.cursors.len >= n) return;
        const old_len = self.cursors.len;
        if (old_len == 0) {
            self.cursors = try self.allocator.alloc(usize, n);
        } else {
            self.cursors = try self.allocator.realloc(self.cursors, n);
        }
        @memset(self.cursors[old_len..], 0);
    }

    /// Swap the time source (tests install a fake clock for deterministic
    /// cooldown expiry instead of sleeping or poking timestamps).
    pub fn setClock(self: *Self, clock: ClockFn) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clock = clock;
    }

    fn nowUnix(self: *Self) i64 {
        return self.clock();
    }

    /// Bounds-checked key lookup. Caller must hold `mutex`.
    fn keyAt(self: *Self, provider_index: usize, key_index: usize) ?*models.Key {
        if (provider_index >= self.config.providers.len) return null;
        const keys = self.config.providers[provider_index].keys;
        if (key_index >= keys.len) return null;
        return &self.config.providers[provider_index].keys[key_index];
    }

    pub fn providerCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.config.providers.len;
    }

    pub fn keyCount(self: *Self, provider_index: usize) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (provider_index >= self.config.providers.len) return 0;
        return self.config.providers[provider_index].keys.len;
    }

    /// Next usable key for a provider (round-robin over enabled + Active
    /// keys), or null when the pool is exhausted. Expired cooldowns are
    /// reactivated lazily via `Key.tryPromote`, and the chosen key's
    /// `last_used` is stamped.
    pub fn nextHealthyKey(self: *Self, provider_index: usize) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.nextHealthyKeyLocked(provider_index);
    }

    /// Same as `nextHealthyKey` but bundles the provider index for the
    /// subsequent `reportResult` call.
    pub fn nextHealthy(self: *Self, provider_index: usize) ?KeySelection {
        if (self.nextHealthyKey(provider_index)) |key_index| {
            return .{ .provider_index = provider_index, .key_index = key_index };
        }
        return null;
    }

    fn nextHealthyKeyLocked(self: *Self, provider_index: usize) ?usize {
        if (provider_index >= self.config.providers.len) return null;
        self.ensureCursorsLocked() catch return null;
        const provider = &self.config.providers[provider_index];
        const n = provider.keys.len;
        if (n == 0) return null;
        const now = self.nowUnix();
        for (provider.keys) |*k| {
            _ = k.tryPromote(now);
        }
        const start = self.cursors[provider_index] % n;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const idx = (start + i) % n;
            const k = &provider.keys[idx];
            if (k.enabled and k.state == .Active) {
                k.last_used = now;
                self.cursors[provider_index] = (idx + 1) % n;
                return idx;
            }
        }
        return null;
    }

    // -- outcome reporting --------------------------------------------------

    /// Report an upstream HTTP status for a key, using the shared models.zig
    /// classifiers (see the file header for the mapping). Status 0 is the
    /// transport-failure sentinel used by the proxy bridge (which only
    /// forwards u16): it cools down immediately, exactly like reportTimeout.
    /// Unknown indices are ignored so proxy retry loops stay branch-free.
    pub fn reportHttpStatus(self: *Self, provider_index: usize, key_index: usize, status: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const k = self.keyAt(provider_index, key_index) orelse return;
        self.reportHttpStatusLocked(k, status);
    }

    /// Report a timeout / transport failure: counts an error and starts a
    /// `cooldown_secs` cooldown.
    pub fn reportTimeout(self: *Self, provider_index: usize, key_index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const k = self.keyAt(provider_index, key_index) orelse return;
        k.markCooldown(self.nowUnix(), self.config.cooldown_secs);
    }

    /// Alias for `reportTimeout` for call sites that distinguish connection
    /// failures from read timeouts.
    pub fn reportTransportError(self: *Self, provider_index: usize, key_index: usize) void {
        self.reportTimeout(provider_index, key_index);
    }

    /// Unified outcome hook for proxy retry loops: an HTTP status, or null
    /// for timeout / transport failure.
    pub fn reportResult(self: *Self, provider_index: usize, key_index: usize, status: ?u16) void {
        if (status) |s| {
            self.reportHttpStatus(provider_index, key_index, s);
        } else {
            self.reportTimeout(provider_index, key_index);
        }
    }

    fn reportHttpStatusLocked(self: *Self, k: *models.Key, status: u16) void {
        const now = self.nowUnix();
        if (status == 0) {
            // Transport-failure sentinel from the proxy bridge (reportKey
            // forwards u16 only, so timeouts arrive as 0): immediate cooldown,
            // mirroring reportTimeout and the proxy's standalone path.
            k.markCooldown(now, self.config.cooldown_secs);
        } else if (models.isHealthyStatus(status)) {
            k.markSuccess(now);
        } else if (models.statusSuggestsDead(status)) {
            k.markDead(now);
        } else if (models.statusSuggestsCooldown(status)) {
            k.markCooldown(now, self.config.cooldown_secs);
        } else {
            k.consecutive_errors +|= 1;
            if (k.consecutive_errors >= self.max_consecutive_errors) {
                k.markCooldown(now, self.config.cooldown_secs);
            }
        }
    }

    // -- health inspection ----------------------------------------------------

    fn countKeys(keys: []models.Key, now: i64) HealthCounts {
        var c = HealthCounts{};
        for (keys) |*k| {
            c.total += 1;
            if (!k.enabled) {
                c.disabled += 1;
                continue;
            }
            // Mirror tryPromote without mutating: an expired cooldown reads
            // as active because the next selection would promote it.
            var state = k.state;
            if (state == .CoolingDown and now >= k.cooldown_until) state = .Active;
            switch (state) {
                .Active => c.active += 1,
                .CoolingDown => c.cooling_down += 1,
                .Dead => c.dead += 1,
            }
        }
        return c;
    }

    /// Health of one provider's pool. Out-of-range providers yield zero
    /// counts.
    pub fn healthCounts(self: *Self, provider_index: usize) HealthCounts {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (provider_index >= self.config.providers.len) return .{};
        return countKeys(self.config.providers[provider_index].keys, self.nowUnix());
    }

    /// Health summed across all providers.
    pub fn totalHealthCounts(self: *Self) HealthCounts {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = self.nowUnix();
        var total = HealthCounts{};
        for (self.config.providers) |*prov| {
            const c = countKeys(prov.keys, now);
            total.total += c.total;
            total.active += c.active;
            total.cooling_down += c.cooling_down;
            total.dead += c.dead;
            total.disabled += c.disabled;
        }
        return total;
    }

    /// Lock-free copy of one key's state for status badges / logs.
    pub fn snapshotKey(self: *Self, provider_index: usize, key_index: usize) ?KeySnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        const k = self.keyAt(provider_index, key_index) orelse return null;
        const now = self.nowUnix();
        var remaining: i64 = 0;
        if (k.state == .CoolingDown) {
            remaining = k.cooldown_until - now;
            if (remaining < 0) remaining = 0;
        }
        return .{
            .state = k.state,
            .enabled = k.enabled,
            .consecutive_errors = k.consecutive_errors,
            .last_used = k.last_used,
            .cooldown_until = k.cooldown_until,
            .cooldown_remaining_secs = remaining,
        };
    }

    // -- manual operator controls ---------------------------------------------

    pub fn setKeyEnabled(self: *Self, provider_index: usize, key_index: usize, enabled: bool) void {
        if (enabled) {
            self.enableKey(provider_index, key_index);
            return;
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        const k = self.keyAt(provider_index, key_index) orelse return;
        k.enabled = false;
    }

    /// Manual disable: the key leaves rotation but keeps its state/counters.
    pub fn forceDisable(self: *Self, provider_index: usize, key_index: usize) void {
        self.setKeyEnabled(provider_index, key_index, false);
    }

    /// Manual re-enable: the key re-enters rotation immediately with cleared
    /// errors (a Dead or CoolingDown key revives to Active — this is an
    /// explicit operator action, not an automatic transition).
    pub fn enableKey(self: *Self, provider_index: usize, key_index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const k = self.keyAt(provider_index, key_index) orelse return;
        k.enabled = true;
        if (k.state == .Dead or k.state == .CoolingDown) {
            k.state = .Active;
            k.cooldown_until = 0;
            k.consecutive_errors = 0;
        }
    }

    /// Clear failure state without touching the enabled flag.
    pub fn reviveKey(self: *Self, provider_index: usize, key_index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const k = self.keyAt(provider_index, key_index) orelse return;
        k.state = .Active;
        k.cooldown_until = 0;
        k.consecutive_errors = 0;
    }

    /// Force a cooldown of `cooldown_secs` (or the configured default when
    /// null), e.g. from a `Retry-After` header the proxy parsed.
    pub fn forceCooldown(self: *Self, provider_index: usize, key_index: usize, cooldown_secs: ?u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const k = self.keyAt(provider_index, key_index) orelse return;
        k.markCooldown(self.nowUnix(), cooldown_secs orelse self.config.cooldown_secs);
    }

    /// Record a confirmed-bad key (e.g. upstream says "key revoked" in-band).
    /// Revive every Dead key of one provider back to Active (errors reset).
    /// Used after a provider demonstrably works again (e.g. a 200 came back
    /// through a fresh route) so keys killed by transient proxy failures
    /// recover automatically instead of staying Dead forever.
    pub fn reviveDead(self: *Self, provider_index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (provider_index >= self.config.providers.len) return;
        for (self.config.providers[provider_index].keys) |*k| {
            if (k.state == .Dead) {
                k.state = .Active;
                k.consecutive_errors = 0;
                k.cooldown_until = 0;
            }
        }
    }

    pub fn markDead(self: *Self, provider_index: usize, key_index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const k = self.keyAt(provider_index, key_index) orelse return;
        k.markDead(self.nowUnix());
    }

    // -- test-ping hooks ------------------------------------------------------

    pub fn setPingHandler(self: *Self, handler: PingFn) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ping_handler = handler;
    }

    pub fn clearPingHandler(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ping_handler = null;
    }

    /// Probe one key via the installed `PingFn` and fold the outcome back
    /// into the pool through the same state machine as live traffic, so the
    /// UI "test" button exercises real rotation semantics. Credentials are
    /// snapshotted under the lock; the handler runs unlocked. If the pool
    /// changed mid-flight the outcome is applied best-effort by index.
    pub fn testPing(
        self: *Self,
        provider_index: usize,
        key_index: usize,
    ) (PingError || std.mem.Allocator.Error)!PingResult {
        const handler: PingFn = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            // Validate indices before reporting handler state so callers get
            // the most actionable error first.
            if (provider_index >= self.config.providers.len) return error.InvalidProvider;
            if (key_index >= self.config.providers[provider_index].keys.len) return error.InvalidKey;
            break :blk self.ping_handler orelse return error.NoPingHandler;
        };

        var key_copy: ?[]u8 = null;
        var url_copy: ?[]u8 = null;
        defer {
            if (key_copy) |b| self.allocator.free(b);
            if (url_copy) |b| self.allocator.free(b);
        }
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (provider_index >= self.config.providers.len) return error.InvalidProvider;
            const prov = &self.config.providers[provider_index];
            if (key_index >= prov.keys.len) return error.InvalidKey;
            key_copy = try self.allocator.dupe(u8, prov.keys[key_index].key);
            url_copy = try self.allocator.dupe(u8, prov.base_url);
        }

        const result = handler(key_copy.?, url_copy.?);

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.keyAt(provider_index, key_index)) |k| {
                if (result.status) |st| {
                    self.reportHttpStatusLocked(k, st);
                } else if (!result.ok) {
                    k.markCooldown(self.nowUnix(), self.config.cooldown_secs);
                } else {
                    k.consecutive_errors = 0;
                    if (k.state == .CoolingDown) k.state = .Active;
                }
            }
        }
        return result;
    }
};

// -- unit tests ---------------------------------------------------------------

const testing = std.testing;

/// Build an owned config with one provider per entry of `keys_per_provider`.
/// All strings are heap-owned; tests run on an arena so no manual frees.
fn makeTestConfig(alloc: std.mem.Allocator, keys_per_provider: []const usize) !models.ProxyConfig {
    var cfg = models.ProxyConfig{
        .port = 8080,
        .auto_start = false,
        .cooldown_secs = 60,
        .timeout_ms = 5_000,
    };
    const providers = try alloc.alloc(models.Provider, keys_per_provider.len);
    for (keys_per_provider, 0..) |n_keys, pi| {
        const keys = try alloc.alloc(models.Key, n_keys);
        for (keys, 0..) |*k, ki| {
            k.* = .{ .key = try std.fmt.allocPrint(alloc, "sk-test-{d}-{d}", .{ pi, ki }) };
        }
        providers[pi] = .{
            .display_name = try std.fmt.allocPrint(alloc, "Test Provider {d}", .{pi}),
            .base_url = try alloc.dupe(u8, "https://example.invalid/v1/"),
            .prefix = try std.fmt.allocPrint(alloc, "t{d}/", .{pi}),
            .description = try alloc.dupe(u8, "rotator unit-test provider"),
            .keys = keys,
            .headers = &.{},
        };
    }
    cfg.providers = providers;
    return cfg;
}

/// Deterministic test clock: tests set `test_now` instead of sleeping or
/// poking key timestamps. Tests run sequentially in one thread, so a global
/// is safe here (the concurrency test keeps the realtime clock).
var test_now: i64 = 1_700_000_000;

fn testClock() i64 {
    return test_now;
}

fn initTestRotator(alloc: std.mem.Allocator, cfg: *models.ProxyConfig) !Rotator {
    var rot = try Rotator.init(alloc, cfg);
    rot.setClock(testClock);
    return rot;
}

fn stubPingOk(_: []const u8, _: []const u8) PingResult {
    return .{ .ok = true, .latency_ms = 12, .status = 200 };
}

fn stubPingDead(_: []const u8, _: []const u8) PingResult {
    return .{ .ok = false, .latency_ms = 5, .status = 401 };
}

test "round robin walks healthy keys in order and wraps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cfg = try makeTestConfig(alloc, &.{3});
    var rot = try initTestRotator(alloc, &cfg);
    defer rot.deinit();

    try testing.expect((rot.nextHealthyKey(0) orelse 99) == 0);
    try testing.expect((rot.nextHealthyKey(0) orelse 99) == 1);
    try testing.expect((rot.nextHealthyKey(0) orelse 99) == 2);
    try testing.expect((rot.nextHealthyKey(0) orelse 99) == 0);

    const sel = rot.nextHealthy(0).?;
    try testing.expectEqual(@as(usize, 0), sel.provider_index);
    try testing.expectEqual(@as(usize, 1), sel.key_index);
}

test "429 cools down, is skipped, and reactivates after expiry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cfg = try makeTestConfig(alloc, &.{3});
    test_now = 1_700_000_000;
    var rot = try initTestRotator(alloc, &cfg);
    defer rot.deinit();

    rot.reportHttpStatus(0, 0, 429);
    try testing.expect((rot.snapshotKey(0, 0).?).state == .CoolingDown);
    try testing.expect((rot.snapshotKey(0, 0).?).cooldown_remaining_secs > 0);
    try testing.expect((rot.nextHealthyKey(0) orelse 99) == 1);

    test_now += 61; // cooldown_secs (60) has expired
    var seen_zero = false;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        if ((rot.nextHealthyKey(0) orelse 99) == 0) seen_zero = true;
    }
    try testing.expect(seen_zero);
    try testing.expect((rot.snapshotKey(0, 0).?).state == .Active);
    try testing.expectEqual(@as(u32, 0), (rot.snapshotKey(0, 0).?).consecutive_errors);
}

test "401 and 403 kill the key permanently" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cfg = try makeTestConfig(alloc, &.{2});
    test_now = 1_700_000_000;
    var rot = try initTestRotator(alloc, &cfg);
    defer rot.deinit();

    rot.reportHttpStatus(0, 0, 401);
    rot.reportResult(0, 1, 403);
    try testing.expect((rot.snapshotKey(0, 0).?).state == .Dead);
    try testing.expect((rot.snapshotKey(0, 1).?).state == .Dead);
    // Even far-future time must not revive Dead keys.
    test_now += 1_000_000;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try testing.expect(rot.nextHealthyKey(0) == null);
    }
    const c = rot.healthCounts(0);
    try testing.expectEqual(@as(usize, 2), c.total);
    try testing.expectEqual(@as(usize, 0), c.active);
    try testing.expectEqual(@as(usize, 2), c.dead);
}

test "2xx resets consecutive errors and revives" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cfg = try makeTestConfig(alloc, &.{2});
    test_now = 1_700_000_000;
    var rot = try initTestRotator(alloc, &cfg);
    defer rot.deinit();

    rot.reportTimeout(0, 0);
    rot.reportResult(0, 0, null);
    try testing.expectEqual(@as(u32, 2), (rot.snapshotKey(0, 0).?).consecutive_errors);
    rot.reportHttpStatus(0, 0, 200);
    const snap = rot.snapshotKey(0, 0).?;
    try testing.expect(snap.state == .Active);
    try testing.expectEqual(@as(u32, 0), snap.consecutive_errors);
}

test "timeout and transport errors cool down and can exhaust the pool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cfg = try makeTestConfig(alloc, &.{2});
    test_now = 1_700_000_000;
    var rot = try initTestRotator(alloc, &cfg);
    defer rot.deinit();

    rot.reportTimeout(0, 0);
    try testing.expect((rot.snapshotKey(0, 0).?).state == .CoolingDown);
    rot.reportTransportError(0, 1);
    try testing.expect(rot.nextHealthyKey(0) == null);
    const c = rot.totalHealthCounts();
    try testing.expectEqual(@as(usize, 2), c.total);
    try testing.expectEqual(@as(usize, 2), c.cooling_down);
    try testing.expectEqual(@as(usize, 0), c.healthy());
}

test "soft faults escalate to cooldown after threshold" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cfg = try makeTestConfig(alloc, &.{1});
    test_now = 1_700_000_000;
    var rot = try initTestRotator(alloc, &cfg);
    defer rot.deinit();

    rot.reportHttpStatus(0, 0, 500);
    // 500 is an immediate cooldown per models.statusSuggestsCooldown.
    try testing.expect((rot.snapshotKey(0, 0).?).state == .CoolingDown);
    try testing.expect(rot.nextHealthyKey(0) == null);

    // A non-classified code (501) only counts soft faults first.
    rot.reviveKey(0, 0);
    rot.reportHttpStatus(0, 0, 501);
    try testing.expect((rot.snapshotKey(0, 0).?).state == .Active);
    try testing.expect(rot.nextHealthyKey(0) != null);
    rot.reportHttpStatus(0, 0, 501);
    rot.reportHttpStatus(0, 0, 501);
    try testing.expect((rot.snapshotKey(0, 0).?).state == .CoolingDown);
    try testing.expect(rot.nextHealthyKey(0) == null);
}

test "status 0 sentinel cools down immediately like a timeout" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cfg = try makeTestConfig(alloc, &.{2});
    test_now = 1_700_000_000;
    var rot = try initTestRotator(alloc, &cfg);
    defer rot.deinit();

    // The proxy bridge only forwards u16, so transport failures arrive as 0.
    rot.reportHttpStatus(0, 0, 0);
    try testing.expect((rot.snapshotKey(0, 0).?).state == .CoolingDown);
    try testing.expect((rot.nextHealthyKey(0) orelse 99) == 1);
    rot.reportResult(0, 1, 0);
    try testing.expect(rot.nextHealthyKey(0) == null);
}

test "forceDisable skips the key and enableKey revives it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cfg = try makeTestConfig(alloc, &.{2});
    test_now = 1_700_000_000;
    var rot = try initTestRotator(alloc, &cfg);
    defer rot.deinit();

    rot.forceDisable(0, 0);
    try testing.expect((rot.nextHealthyKey(0) orelse 99) == 1);
    try testing.expect((rot.nextHealthyKey(0) orelse 99) == 1);
    var c = rot.healthCounts(0);
    try testing.expectEqual(@as(usize, 1), c.disabled);
    try testing.expectEqual(@as(usize, 1), c.active);

    // Re-enable a key that also died while disabled: operator action revives.
    rot.reportHttpStatus(0, 0, 401);
    rot.enableKey(0, 0);
    const snap = rot.snapshotKey(0, 0).?;
    try testing.expect(snap.enabled);
    try testing.expect(snap.state == .Active);
    c = rot.healthCounts(0);
    try testing.expectEqual(@as(usize, 2), c.active);
}

test "reviveKey, forceCooldown and markDead hooks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cfg = try makeTestConfig(alloc, &.{2});
    test_now = 1_700_000_000;
    var rot = try initTestRotator(alloc, &cfg);
    defer rot.deinit();

    rot.reportHttpStatus(0, 0, 401);
    try testing.expect((rot.nextHealthyKey(0) orelse 99) == 1);
    rot.reviveKey(0, 0);
    try testing.expect((rot.snapshotKey(0, 0).?).state == .Active);

    rot.forceCooldown(0, 1, 3_600);
    const snap = rot.snapshotKey(0, 1).?;
    try testing.expect(snap.state == .CoolingDown);
    try testing.expect(snap.cooldown_remaining_secs > 3_500);
    try testing.expect((rot.nextHealthyKey(0) orelse 99) == 0);

    rot.markDead(0, 0);
    try testing.expect((rot.snapshotKey(0, 0).?).state == .Dead);
}

test "invalid indices are safe" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cfg = try makeTestConfig(alloc, &.{1});
    test_now = 1_700_000_000;
    var rot = try initTestRotator(alloc, &cfg);
    defer rot.deinit();

    try testing.expect(rot.nextHealthyKey(7) == null);
    try testing.expect(rot.nextHealthy(7) == null);
    try testing.expect(rot.snapshotKey(0, 9) == null);
    try testing.expect(rot.snapshotKey(9, 0) == null);
    try testing.expectEqual(@as(usize, 0), rot.keyCount(9));
    try testing.expectEqual(@as(usize, 1), rot.providerCount());
    // Must not crash.
    rot.reportHttpStatus(9, 0, 429);
    rot.reportTimeout(0, 9);
    rot.reportResult(9, 9, null);
    rot.forceDisable(9, 0);
    rot.enableKey(0, 9);
    rot.reviveKey(9, 9);
    rot.forceCooldown(0, 9, null);
    rot.markDead(9, 0);
    const c = rot.healthCounts(9);
    try testing.expectEqual(@as(usize, 0), c.total);
}

test "testPing needs a handler and folds outcomes into the pool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cfg = try makeTestConfig(alloc, &.{2});
    test_now = 1_700_000_000;
    var rot = try initTestRotator(alloc, &cfg);
    defer rot.deinit();

    try testing.expectError(error.NoPingHandler, rot.testPing(0, 0));
    try testing.expectError(error.InvalidProvider, rot.testPing(9, 0));

    rot.reportHttpStatus(0, 0, 429);
    rot.setPingHandler(stubPingOk);
    const ok = try rot.testPing(0, 0);
    try testing.expect(ok.ok);
    try testing.expectEqual(@as(u64, 12), ok.latency_ms);
    try testing.expect((rot.snapshotKey(0, 0).?).state == .Active);

    rot.setPingHandler(stubPingDead);
    _ = try rot.testPing(0, 1);
    try testing.expect((rot.snapshotKey(0, 1).?).state == .Dead);

    rot.clearPingHandler();
    try testing.expectError(error.NoPingHandler, rot.testPing(0, 0));
}

test "empty providers and multi-provider isolation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cfg = try makeTestConfig(alloc, &.{ 0, 2 });
    test_now = 1_700_000_000;
    var rot = try initTestRotator(alloc, &cfg);
    defer rot.deinit();

    try testing.expect(rot.nextHealthyKey(0) == null);
    try testing.expect((rot.nextHealthyKey(1) orelse 99) == 0);
    rot.reportHttpStatus(1, 0, 401);
    // Provider 0 is unaffected and still empty; provider 1 rotated.
    try testing.expect(rot.nextHealthyKey(0) == null);
    try testing.expect((rot.nextHealthyKey(1) orelse 99) == 1);
    const total = rot.totalHealthCounts();
    try testing.expectEqual(@as(usize, 2), total.total);
    try testing.expectEqual(@as(usize, 1), total.active);
    try testing.expectEqual(@as(usize, 1), total.dead);
}

const ConcurrencyCtx = struct {
    rot: *Rotator,
};

fn concurrencyWorker(ctx: *ConcurrencyCtx) void {
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        if (ctx.rot.nextHealthyKey(0)) |k| {
            switch (i % 5) {
                0 => ctx.rot.reportTimeout(0, k),
                1 => ctx.rot.reportHttpStatus(0, k, 429),
                else => ctx.rot.reportHttpStatus(0, k, 200),
            }
        }
    }
}

test "concurrent selections and reports stay consistent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var cfg = try makeTestConfig(alloc, &.{3});
    // Keeps the realtime clock on purpose: exercises the default path.
    var rot = try Rotator.init(alloc, &cfg);
    defer rot.deinit();

    var ctx = ConcurrencyCtx{ .rot = &rot };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, concurrencyWorker, .{&ctx});
    for (&threads) |*t| t.join();

    const c = rot.totalHealthCounts();
    try testing.expectEqual(@as(usize, 3), c.total);
    try testing.expectEqual(c.total, c.active + c.cooling_down + c.dead + c.disabled);
}

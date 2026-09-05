// Public HTTP CONNECT proxy pool, rebuilt on the jhao104/proxy_pool model.
//
// The pool keeps itself full and healthy INDEPENDENTLY of what the model
// providers do:
//   * a background "getter" fetches many proxy-list sources on a cadence and
//     hands every raw candidate to a "tester";
//   * the "tester" validates candidates against a NEUTRAL target (a tiny
//     HTTPS 204 endpoint), never against a model provider — so a proxy's
//     health reflects whether the proxy itself works, not whether some
//     upstream is rate-limiting us today;
//   * a proxy is only removed when it repeatedly fails the neutral probe
//     (its `fails` score hits the limit) or the origin throttles it through
//     many distinct egresses (short circuit-breaker, not per-route deletion);
//   * success on the neutral probe or on a real request decrements `fails`,
//     so a proxy that had a bad stretch is re-promoted instead of lost.
//
// Because origin 429/403 verdicts never delete a route, a provider that is
// rate-limiting us through every egress can no longer drain the pool.
//
// All list fetches and probes have deadlines; the owned task group is joined
// on shutdown. TLS authenticates the origin and encrypts credentials inside
// the tunnel. Transport failures and egress throttling never poison API keys.

const std = @import("std");
const HttpClient = @import("http_client.zig");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

fn nowMs() i64 {
    if (builtin.os.tag == .windows) {
        const ticks: i64 = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        return @divFloor(ticks, 10_000) - 11_644_473_600_000;
    }
    var ts: std.posix.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divFloor(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

pub const max_pool: usize = 256;
pub const max_latency_ms: u64 = 4000;
/// A proxy is dropped once `fails` reaches this limit. `fails` grows only on
/// neutral-probe failures (or on real-request transport failures that the
/// proxy itself caused); a proxy that had a bad stretch recovers because
/// success decrements `fails`. Origin 429/403 never count here.
pub const max_fails: u32 = 2;
/// Cadence of the proxy_pool-style "getter": re-pull the source lists.
pub const list_refresh_ms: i64 = 5 * 60 * 1000;
/// Cadence of the "tester (use)": re-validate idle routes against the neutral
/// target and let scores recover.
pub const validation_refresh_ms: i64 = 45 * 1000;
pub const validation_workers: usize = 40;
/// The pool is considered full enough at this many ready routes; when it drops
/// below, the next check triggers an immediate fetch (POOL_SIZE_MIN analog).
pub const target_ready: usize = 128;
pub const max_validate_batch: usize = 1500;
pub const max_candidates: usize = 80_000;
/// Origin-throttle circuit breaker: when the origin returns 429/403 through
/// this many DISTINCT egresses within `origin_breaker_window_ms`, the pool
/// stops handing out proxies for `origin_breaker_open_ms` so requests fail
/// fast with the real verdict instead of burning attempts and looking like a
/// dead pool.
pub const origin_breaker_threshold: u8 = 3;
pub const origin_breaker_window_ms: i64 = 5 * 1000;
pub const origin_breaker_open_ms: i64 = 3 * 1000;

/// One pooled proxy. `host` is heap-owned by the pool.
pub const Entry = struct {
    host: []const u8,
    port: u16,
    /// Best-known neutral-probe latency. Real request latency is generation
    /// time (model-dependent), so it never overwrites this.
    latency_ms: u32 = 0,
    /// proxy_pool "fail_count": increments on neutral-probe failure or a
    /// request transport failure attributable to the proxy; decrements on
    /// any success; drops the proxy at max_fails.
    fails: u32 = 0,
    /// Total neutral-probe checks (proxy_pool "check_count").
    check_count: u32 = 0,
    /// Monotonic counter: higher = used more recently (skip for fairness).
    last_used: u64 = 0,
    /// Preferred after a successful real request; ties broken toward these.
    preferred: bool = false,
    in_flight: bool = false,
    /// While set, the proxy is not handed out (short origin cooldown).
    blocked_until_ms: i64 = 0,
    validated_ms: i64 = 0,
    /// Wall-clock time the route last succeeded (neutral probe or real).
    last_ok_ms: i64 = 0,
    /// Real requests relayed through this route (not probes).
    uses: u64 = 0,
};

/// Public sources. Text sources return plain `ip:port` lines (some prefix a
/// scheme); the JSON sources carry per-proxy latency/uptime metadata that
/// lets the pool prioritize the likeliest-healthy candidates before probing.
/// All of them re-publish on their own cadence (every 5-60 minutes), so a
/// plain re-fetch is a fresh list. Sources are merged fairly; one large list
/// cannot hide the rest.
const list_sources = [_][]const u8{
    // -- verified live 2026-09-05; high-volume text lists --
    "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/all.txt",
    "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt",
    "https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/protocols/http/data.txt",
    "https://raw.githubusercontent.com/jetkai/proxy-list/main/online-proxies/txt/proxies-http.txt",
    "https://raw.githubusercontent.com/vakhov/fresh-proxy-list/master/http.txt",
    "https://raw.githubusercontent.com/roosterkid/openproxylist/main/HTTPS_RAW.txt",
    "https://raw.githubusercontent.com/ioproxy/Proxy-List/main/http.txt",
    "https://raw.githubusercontent.com/prxchk/proxy-list/main/http.txt",
    "https://raw.githubusercontent.com/Zaeem20/FREE_PROXIES_LIST/master/http.txt",
    // -- more aggregates (verified live) --
    "https://raw.githubusercontent.com/sunny9577/proxy-scraper/master/proxies.txt",
    "https://raw.githubusercontent.com/ALIILAPRO/Proxy/main/http.txt",
    "https://raw.githubusercontent.com/clarketm/proxy-list/master/proxy-list-raw.txt",
    "https://raw.githubusercontent.com/ShiftyTR/Proxy-List/master/https.txt",
    // -- frequently-refreshed aggregates --
    "https://api.proxyscrape.com/v2/?request=displayproxies&protocol=http&timeout=3000",
    "https://api.proxyscrape.com/v4/free-proxy-list/get?request=display_proxies&protocol=http&proxy_format=ipport&format=text&timeout=3000",
    "https://www.proxy-list.download/api/v1/get?type=http",
    "https://www.proxy-list.download/api/v1/get?type=https",
    "https://proxyspace.pro/http.txt",
    "https://raw.githubusercontent.com/databay-labs/free-proxy-list/main/http.txt",
    "https://raw.githubusercontent.com/iplocate/free-proxy-list/main/protocols/http.txt",
    "https://raw.githubusercontent.com/iplocate/free-proxy-list/main/protocols/https.txt",
    "https://raw.githubusercontent.com/VPSLabCloud/VPSLab-Free-Proxy-List/main/http_ssl.txt",
    "https://raw.githubusercontent.com/VPSLabCloud/VPSLab-Free-Proxy-List/main/http_ssl_elite.txt",
    "https://raw.githubusercontent.com/hproxy-com/free-proxy-list/main/http.txt",
    // -- JSON with per-proxy latency/uptime (used for prioritization) --
    "https://raw.githubusercontent.com/hproxy-com/free-proxy-list/main/all.json",
    "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies.json",
};

/// Neutral validation target: a tiny Google 204 endpoint. No model provider is
/// ever the arbiter of a proxy's health, so origin rate-limits can never drain
/// the pool. A 204 (or any 2xx) means "this proxy can reach the open internet
/// over HTTPS CONNECT + TLS".
const probe_url = "https://www.gstatic.com/generate_204";

const Mutex = if (@hasDecl(std.Thread, "Mutex"))
    std.Thread.Mutex
else
    struct {
        inner: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        pub fn lock(self: *@This()) void {
            while (self.inner.swap(true, .acquire)) {
                std.Thread.yield() catch {};
            }
        }
        pub fn unlock(self: *@This()) void {
            _ = self.inner.swap(false, .release);
        }
    };

pub const Pool = struct {
    alloc: Allocator,
    io: std.Io,
    tasks: std.Io.Group = .init,
    stopping: bool = false,
    mu: Mutex = .{},
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    lists_fetched_ms: i64 = 0,
    pool_validated_ms: i64 = 0,
    working: bool = false,
    refresh_started_ms: i64 = 0,
    waiting: usize = 0,
    wait_tickets: [128]u64 = @splat(0),
    next_ticket: u64 = 0,
    refresh_checked_ms: i64 = 0,
    candidates: CandidateList = .empty,
    candidate_cursor: usize = 0,
    clock: u64 = 0,
    quarantine: [1024]struct { host: [15]u8 = @splat(0), len: usize = 0, port: u16 = 0, until: i64 = 0 } = @splat(.{}),
    quarantine_next: usize = 0,
    last_refresh_error: []const u8 = "",
    /// Optional message sink (already-formatted string). Stringify at the call site.
    log_msg: ?*const fn ([]const u8) void = null,
    /// Sustained-demand hint: set by the request path when it has been waiting
    /// for capacity; lets the fetch kick in earlier than the next 5-min list
    /// cycle would. Cleared when a refresh pass starts.
    demand_high: bool = false,
    /// Circuit breaker, keyed per provider prefix (see the consts at the top
    /// of the file). One provider rate-limiting through many egresses pauses
    /// only ITS OWN proxied requests; other providers keep flowing.
    origin_breaker_until_ms: [8]i64 = @splat(0),
    origin_breaker_strikes: [8]u8 = @splat(0),
    last_breaker_host: [8][15]u8 = @splat(@splat(0)),
    last_breaker_host_len: [8]usize = @splat(0),
    last_breaker_at_ms: [8]i64 = @splat(0),

    fn breakerSlot(prefix: []const u8) usize {
        // A tiny stable hash of the provider prefix into a small slot table.
        var h: u32 = 2166136261;
        for (prefix) |c| h = (h ^ c) *% 16777619;
        return h % 8;
    }

    /// Called on every 429/403 verdict for `prefix`'s origin. Returns true
    /// when the request should stop immediately (the origin is throttling
    /// this account through many egresses); that provider's breaker then
    /// trips open briefly. This NEVER deletes or retires a route: the
    /// origin's mood is not the proxy's health.
    pub fn noteOriginThrottle(self: *Pool, prefix: []const u8, host: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        const s = breakerSlot(prefix);
        const at = self.now();
        if (at < self.origin_breaker_until_ms[s]) return true;
        const first_seen = self.last_breaker_host_len[s] == 0;
        const same_host = std.mem.eql(u8, self.last_breaker_host[s][0..self.last_breaker_host_len[s]], host);
        const window_expired = at - self.last_breaker_at_ms[s] > origin_breaker_window_ms;
        if (!first_seen and same_host and !window_expired) return false;
        if (first_seen) {
            self.last_breaker_at_ms[s] = at;
            self.origin_breaker_strikes[s] = 0;
            if (host.len <= 15) {
                self.last_breaker_host_len[s] = host.len;
                @memcpy(self.last_breaker_host[s][0..host.len], host);
            }
            return false;
        }
        const strikes: u8 = if (window_expired) 1 else self.origin_breaker_strikes[s] + 1;
        self.origin_breaker_strikes[s] = strikes;
        self.last_breaker_at_ms[s] = at;
        if (host.len <= 15) {
            self.last_breaker_host_len[s] = host.len;
            @memcpy(self.last_breaker_host[s][0..host.len], host);
        }
        if (strikes >= origin_breaker_threshold) {
            self.origin_breaker_until_ms[s] = at + origin_breaker_open_ms;
            self.origin_breaker_strikes[s] = 0;
            self.logInfo("proxy pool: provider {s} throttled through {d} distinct proxies; pausing its proxied attempts briefly", .{ prefix, origin_breaker_threshold });
            return true;
        }
        return false;
    }

    /// Whether `prefix`'s origin-throttle breaker is currently open.
    pub fn originThrottleOpen(self: *Pool, prefix: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.now() < self.origin_breaker_until_ms[breakerSlot(prefix)];
    }

    /// A successful request for `prefix` through a proxy clears its breaker.
    pub fn clearOriginThrottle(self: *Pool, prefix: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const s = breakerSlot(prefix);
        self.origin_breaker_until_ms[s] = 0;
        self.origin_breaker_strikes[s] = 0;
        self.last_breaker_at_ms[s] = self.now();
    }

    /// Record that the origin returned 429/403 for `host` through `prefix`
    /// and remember the route so it is not immediately re-picked for the same
    /// origin within the cooldown. Returns the ms to wait (from the origin's
    /// Retry-After when available) for the caller to surface.
    pub fn noteOriginThrottleRoute(self: *Pool, prefix: []const u8, host: []const u8, port: u16, retry_after_ms: u64) i64 {
        _ = prefix;
        self.mu.lock();
        defer self.mu.unlock();
        // Cool THIS route for that origin so we do not burn it again right
        // away; but keep the proxy itself healthy (the origin is the cause).
        // NOTE: this must NOT extend the per-provider breaker - doing so
        // would keep the breaker open forever while 429s keep arriving
        // (each one re-arming the open window), deadlocking the provider.
        const idx = for (self.entries.items, 0..) |item, i| {
            if (item.port == port and std.mem.eql(u8, item.host, host)) break i;
        } else return 0;
        const e = &self.entries.items[idx];
        const cool_ms: i64 = if (retry_after_ms != 0) @min(@as(i64, @intCast(retry_after_ms)), 60_000) else 8_000;
        e.blocked_until_ms = @max(e.blocked_until_ms, self.now() + cool_ms);
        return cool_ms;
    }

    pub fn init(alloc: Allocator, io: std.Io) Pool {
        return .{ .alloc = alloc, .io = io };
    }

    pub fn deinit(self: *Pool) void {
        self.mu.lock();
        self.stopping = true;
        self.mu.unlock();
        self.tasks.cancel(self.io);
        for (self.entries.items) |*e| self.alloc.free(e.host);
        self.entries.deinit(self.alloc);
        for (self.candidates.items) |c| self.alloc.free(c.host);
        self.candidates.deinit(self.alloc);
    }

    fn logInfo(self: *Pool, comptime fmt: []const u8, args: anytype) void {
        if (self.log_msg) |f| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
            f(msg);
        }
    }

    fn now(self: *Pool) i64 {
        _ = self;
        const t = nowMs();
        if (t == 0) return 1; // nowMs()==0 would make every staleness check false
        return t;
    }

    // -- selection -----------------------------------------------------------

    /// Called before each proxied request: keeps the pool fresh without ever
    /// blocking the caller. Returns the best entry (copy) or null.
    pub fn pick(self: *Pool, arena: Allocator) ?Picked {
        return self.pickAvoiding(arena, &.{});
    }

    fn quarantined(self: *Pool, host: []const u8, port: u16) bool {
        const at = self.now();
        for (self.quarantine) |q| if (q.until > at and q.port == port and std.mem.eql(u8, q.host[0..q.len], host)) return true;
        return false;
    }

    fn quarantineRoute(self: *Pool, host: []const u8, port: u16, ms: i64) void {
        if (host.len > 15) return;
        const q = &self.quarantine[self.quarantine_next % self.quarantine.len];
        q.* = .{ .len = host.len, .port = port, .until = self.now() + ms };
        @memcpy(q.host[0..host.len], host);
        self.quarantine_next +%= 1;
    }

    pub fn pickAvoiding(self: *Pool, arena: Allocator, avoided: []const Picked) ?Picked {
        self.maybeRefresh();
        self.mu.lock();
        defer self.mu.unlock();
        if (self.waiting != 0) return null;
        return self.pickLocked(arena, avoided);
    }

    fn pickLocked(self: *Pool, arena: Allocator, avoided: []const Picked) ?Picked {
        var best: ?usize = null;
        var best_latency: u32 = std.math.maxInt(u32);
        var best_used: u64 = std.math.maxInt(u64);
        var best_preferred = false;
        for (self.entries.items, 0..) |e, i| {
            if (e.in_flight or e.fails >= max_fails or e.blocked_until_ms > self.now() or self.quarantined(e.host, e.port)) continue;
            const tried = for (avoided) |old| {
                if (old.port == e.port and std.mem.eql(u8, old.host, e.host)) break true;
            } else false;
            if (tried) continue;
            if (e.validated_ms != 0 and self.now() - e.validated_ms > 2 * validation_refresh_ms) continue;
            // Prefer fast; tie-break on least-recently-used.
            const better = best == null or (e.preferred and !best_preferred) or
                (e.preferred == best_preferred and (e.latency_ms < best_latency or
                    (e.latency_ms == best_latency and e.last_used < best_used)));
            if (better) {
                best = i;
                best_preferred = e.preferred;
                best_latency = e.latency_ms;
                best_used = e.last_used;
            }
        }
        const idx = best orelse return null;
        self.clock += 1;
        self.entries.items[idx].last_used = self.clock;
        const e = &self.entries.items[idx];
        const host = arena.dupe(u8, e.host) catch return null;
        e.in_flight = true;
        return .{ .host = host, .port = e.port, .index = idx, .leased = true };
    }

    // Called with the pool mutex held. Busy and blocked entries are not capacity.
    fn readyCount(self: *Pool) usize {
        var n: usize = 0;
        for (self.entries.items) |e| {
            if (!e.in_flight and e.fails < max_fails and e.blocked_until_ms <= self.now() and
                (e.validated_ms == 0 or self.now() - e.validated_ms <= 2 * validation_refresh_ms) and
                !self.quarantined(e.host, e.port)) n += 1;
        }
        return n;
    }

    /// Wait for a lease or new validation within the caller's existing budget.
    /// Bound admission so arbitrary bursts cannot create an unlimited queue.
    pub fn waitForRoute(self: *Pool, arena: Allocator, avoided: []const Picked, budget_ms: u64) !?Picked {
        self.maybeRefresh();
        self.mu.lock();
        if (self.waiting == 0) {
            if (self.pickLocked(arena, avoided)) |picked| {
                self.mu.unlock();
                return picked;
            }
        }
        if (self.waiting == self.wait_tickets.len) {
            self.mu.unlock();
            return null;
        }
        const ticket = self.next_ticket;
        self.next_ticket +%= 1;
        self.wait_tickets[self.waiting] = ticket;
        self.waiting += 1;
        self.mu.unlock();
        defer {
            self.mu.lock();
            for (self.wait_tickets[0..self.waiting], 0..) |old, i| {
                if (old != ticket) continue;
                std.mem.copyForwards(u64, self.wait_tickets[i .. self.waiting - 1], self.wait_tickets[i + 1 .. self.waiting]);
                self.waiting -= 1;
                break;
            }
            self.mu.unlock();
        }
        const end = std.Io.Clock.awake.now(self.io).toMilliseconds() + @as(i64, @intCast(budget_ms));
        while (std.Io.Clock.awake.now(self.io).toMilliseconds() < end) {
            self.mu.lock();
            const first = self.wait_tickets[0] == ticket;
            const picked = if (first) self.pickLocked(arena, avoided) else null;
            const pending = !self.stopping or self.working or for (self.entries.items) |e| {
                if (e.in_flight) break true;
            } else false;
            self.mu.unlock();
            if (picked != null) return picked;
            if (first and !pending) return null;
            if (first) self.maybeRefresh();
            try std.Io.sleep(self.io, .fromMilliseconds(5), .awake);
        }
        // Out of budget with nothing picked: tell the next refresh trigger that
        // demand is sustained so it re-arms a fetch/validation pass immediately.
        self.mu.lock();
        self.demand_high = true;
        self.mu.unlock();
        return null;
    }

    /// Called by the request path between attempts so a refill starts as soon
    /// as the pool looks thin, without waiting for a request to fully exhaust
    /// its budget first.
    pub fn noteDemand(self: *Pool) void {
        self.mu.lock();
        if (self.readyCount() < target_ready) self.demand_high = true;
        self.mu.unlock();
        self.maybeRefresh();
    }

    /// True when the pool is short on ready routes.
    pub fn isThin(self: *Pool) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.readyCount() < target_ready;
    }

    // -- outcome reporting ---------------------------------------------------

    /// Report the outcome of using a proxy for a REAL request. Success keeps
    /// it (and improves its score); a transport failure the proxy caused
    /// bumps `fails`. A client disconnect (ok == null) says nothing about the
    /// route. Fast: O(1) lock.
    pub fn report(self: *Pool, picked: Picked, latency_ms: u32, ok: ?bool) void {
        self.mu.lock();
        defer self.mu.unlock();
        const index = for (self.entries.items, 0..) |item, i| {
            if (item.port == picked.port and std.mem.eql(u8, item.host, picked.host)) break i;
        } else return;
        const e = &self.entries.items[index];
        if (!picked.leased and e.in_flight) return; // A background probe cannot evict a live lease.
        if (picked.leased) e.in_flight = false;
        const healthy = ok orelse return; // A client disconnect says nothing about the route.
        if (healthy) {
            // proxy_pool score recovery: success improves the score. A real
            // 2xx through the route is as good as a neutral probe, so it also
            // refreshes validation freshness - a working route stays in
            // rotation instead of being aged out and re-probed.
            e.fails = if (e.fails > 0) e.fails - 1 else 0;
            e.last_ok_ms = self.now();
            e.validated_ms = self.now();
            e.uses +|= 1;
            if (e.latency_ms == 0) e.latency_ms = latency_ms;
        } else {
            e.fails += 1;
            if (e.fails >= max_fails) {
                const host = self.entries.items[index].host;
                self.quarantineRoute(host, e.port, 5 * 60 * 1000);
                self.logInfo("proxy pool: dropping {s} ({d} transport fails)", .{ host, e.fails });
                _ = self.entries.orderedRemove(index);
                self.alloc.free(host);
            }
        }
    }

    /// Origin status verdict on a real request (2xx or an origin error code).
    /// IMPORTANT: this NEVER changes a proxy's score or deletes it. An origin
    /// 429/403 says the ORIGIN is rate-limiting, not that the proxy is dead.
    /// The only effects: a 2xx marks the route preferred; a non-2xx cools the
    /// route briefly so the next request tries a different egress first.
    pub fn routeStatus(self: *Pool, picked: Picked, status: u16) void {
        self.mu.lock();
        defer self.mu.unlock();
        const index = for (self.entries.items, 0..) |item, i| {
            if (item.port == picked.port and std.mem.eql(u8, item.host, picked.host)) break i;
        } else return;
        const e = &self.entries.items[index];
        if (status >= 200 and status < 300) {
            e.preferred = true;
            e.validated_ms = self.now();
            e.blocked_until_ms = 0;
            return;
        }
        if (status == 429 or status == 403 or status == 408 or status >= 502) {
            // Cool only, never retire. 403/429 cool shortest (the origin is
            // the cause); 5xx/408 a touch longer.
            e.preferred = false;
            const base_ms: i64 = if (status == 429 or status == 403) 8_000 else 20_000;
            e.blocked_until_ms = @max(e.blocked_until_ms, self.now() + base_ms);
            return;
        }
    }

    /// A neutral-probe failure (background check against the neutral target).
    /// Unlike a real-request transport failure this is the strongest signal a
    /// proxy is unusable, so it counts double toward the drop threshold.
    fn reportProbeFailure(self: *Pool, host: []const u8, port: u16) void {
        self.mu.lock();
        defer self.mu.unlock();
        const index = for (self.entries.items, 0..) |item, i| {
            if (item.port == port and std.mem.eql(u8, item.host, host)) break i;
        } else return;
        const e = &self.entries.items[index];
        if (e.in_flight) return; // A live lease may be fine; probe again later.
        e.fails = @min(e.fails + 2, max_fails);
        if (e.fails >= max_fails) {
            const h = self.entries.items[index].host;
            self.quarantineRoute(h, e.port, 5 * 60 * 1000);
            self.logInfo("proxy pool: dropping {s} (failed the neutral probe)", .{h});
            _ = self.entries.orderedRemove(index);
            self.alloc.free(h);
        }
    }

    /// Called when a request got a 429/403 AND the same proxy failed a neutral
    /// probe: the proxy itself is dead/burned, so drop it (proxy_pool score).
    pub fn reportProxyDead(self: *Pool, host: []const u8, port: u16) void {
        self.reportProbeFailure(host, port);
    }

    // -- diagnostics ----------------------------------------------------------

    /// Diagnostics: tracked entries and whether a refresh pass is running.
    pub fn diag(self: *Pool) struct { tracked: usize, working: bool, lists_ms: i64, validated_ms: i64, last_error: []const u8, ready: usize, busy: usize, blocked: usize, waiting: usize, candidates: usize } {
        self.mu.lock();
        defer self.mu.unlock();
        return .{
            .ready = self.readyCount(),
            .busy = blk: {
                var n: usize = 0;
                for (self.entries.items) |e| {
                    if (e.in_flight) n += 1;
                }
                break :blk n;
            },
            .blocked = blk: {
                var n: usize = 0;
                for (self.entries.items) |e| {
                    if (e.blocked_until_ms > self.now()) n += 1;
                }
                break :blk n;
            },
            .waiting = self.waiting,
            .candidates = self.candidates.items.len,
            .tracked = self.entries.items.len,
            .working = self.working,
            .lists_ms = self.lists_fetched_ms,
            .validated_ms = self.pool_validated_ms,
            .last_error = self.last_refresh_error,
        };
    }

    /// How many alive proxies are currently pooled.
    pub fn alive(self: *Pool) usize {
        self.mu.lock();
        defer self.mu.unlock();
        var n: usize = 0;
        for (self.entries.items) |*e| {
            if (e.fails < max_fails and e.blocked_until_ms <= self.now() and
                (e.validated_ms == 0 or self.now() - e.validated_ms <= 2 * validation_refresh_ms)) n += 1;
        }
        return n;
    }

    // -- scheduler (proxy_pool getter + tester) -------------------------------

    /// Kick a background fetch + validation cycle when stale. Never blocks the
    /// caller: work happens on detached pool tasks.
    pub fn maybeRefresh(self: *Pool) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.stopping or self.working) return;
        if (self.now() - self.refresh_checked_ms < 1000) return;
        self.refresh_checked_ms = self.now();
        const stale = self.now() - self.pool_validated_ms > validation_refresh_ms or
            self.now() - self.lists_fetched_ms > list_refresh_ms or
            (self.now() - self.refresh_started_ms >= 5000 and self.readyCount() < target_ready) or
            // Under sustained demand the pool drains faster than the 5-min
            // list cadence can refill it, so a waiting request that is about
            // to give up re-arms a fresh validation pass immediately.
            (self.demand_high and self.readyCount() < target_ready and self.lists_fetched_ms != 0);
        if (!stale) return;
        self.demand_high = false;
        const ctx = self.alloc.create(RefreshCtx) catch return;
        ctx.* = .{ .pool = self };
        self.working = true;
        self.refresh_started_ms = self.now();
        self.tasks.concurrent(self.io, refreshTask, .{ctx}) catch {
            self.working = false;
            self.alloc.destroy(ctx);
        };
    }

    const RefreshCtx = struct {
        pool: *Pool,
    };

    /// The getter+tester pass. Fetches lists when due, then validates a batch
    /// of candidates (fresh + idle routes) against the NEUTRAL target, and
    /// removes routes that repeatedly fail the neutral probe.
    fn refreshTask(ctx: *RefreshCtx) std.Io.Cancelable!void {
        const pool = ctx.pool;
        const alloc = pool.alloc;
        defer {
            pool.mu.lock();
            pool.working = false;
            pool.mu.unlock();
            alloc.destroy(ctx);
        }

        var fresh = fetchLists(pool, alloc) catch return;
        defer {
            for (fresh.items) |cand| alloc.free(cand.host);
            fresh.deinit(alloc);
        }
        // Fresh candidates stay private until HTTPS CONNECT + TLS + the
        // neutral 204 all succeed; idle routes are re-probed to recover.
        const Job = struct {
            pool: *Pool,
            candidate: Candidate,
            is_existing: bool,
            fn run(job: @This()) void {
                if (job.is_existing) {
                    // Re-probe an idle route. Success recovers its score.
                    const t0 = nowMs();
                    timed(void, job.pool.io, max_latency_ms, probeThrough, .{
                        job.pool, job.candidate.host, job.candidate.port,
                    }) catch {
                        job.pool.reportProbeFailure(job.candidate.host, job.candidate.port);
                        return;
                    };
                    job.pool.mu.lock();
                    for (job.pool.entries.items) |*e| {
                        if (e.port == job.candidate.port and std.mem.eql(u8, e.host, job.candidate.host)) {
                            e.validated_ms = nowMs();
                            e.latency_ms = @intCast(@max(0, nowMs() - t0));
                            if (e.fails > 0) e.fails -= 1;
                            e.last_ok_ms = nowMs();
                            break;
                        }
                    }
                    job.pool.mu.unlock();
                    return;
                }
                job.pool.mu.lock();
                const blocked = job.pool.quarantined(job.candidate.host, job.candidate.port) or for (job.pool.entries.items) |entry| {
                    if (entry.port == job.candidate.port and std.mem.eql(u8, entry.host, job.candidate.host)) break true;
                } else false;
                job.pool.mu.unlock();
                if (blocked) return;
                const t0 = nowMs();
                timed(void, job.pool.io, max_latency_ms, probeThrough, .{
                    job.pool, job.candidate.host, job.candidate.port,
                }) catch return;
                const p = job.pool;
                p.mu.lock();
                defer p.mu.unlock();
                if (p.quarantined(job.candidate.host, job.candidate.port)) return;
                for (p.entries.items) |*e| {
                    if (e.port == job.candidate.port and std.mem.eql(u8, e.host, job.candidate.host)) {
                        e.latency_ms = @intCast(@max(0, nowMs() - t0));
                        e.validated_ms = nowMs();
                        e.last_ok_ms = nowMs();
                        if (e.fails > 0) e.fails -= 1;
                        return;
                    }
                }
                if (p.entries.items.len >= max_pool) {
                    var replace: ?usize = null;
                    for (p.entries.items, 0..) |entry, i| {
                        if (entry.in_flight) continue;
                        if (entry.blocked_until_ms > p.now() or p.now() - entry.validated_ms > 2 * validation_refresh_ms) {
                            replace = i;
                            break;
                        }
                    }
                    const idx = replace orelse return;
                    const old = p.entries.orderedRemove(idx);
                    p.quarantineRoute(old.host, old.port, 5 * 60 * 1000);
                    p.alloc.free(old.host);
                }
                const host = p.alloc.dupe(u8, job.candidate.host) catch return;
                p.entries.append(p.alloc, .{ .host = host, .port = job.candidate.port, .latency_ms = @intCast(@max(0, nowMs() - t0)), .validated_ms = nowMs(), .last_ok_ms = nowMs() }) catch {
                    p.alloc.free(host);
                    return;
                };
            }
        };
        const Work = struct {
            pool: *Pool,
            candidates: []const Candidate,
            cursor: std.atomic.Value(usize) = .init(0),
            fn run(work: *@This()) std.Io.Cancelable!void {
                while (true) {
                    try std.Io.checkCancel(work.pool.io);
                    const i = work.cursor.fetchAdd(1, .monotonic);
                    if (i >= work.candidates.len) return;
                    work.pool.mu.lock();
                    const enough = work.pool.readyCount() >= target_ready;
                    work.pool.mu.unlock();
                    if (enough and i >= max_pool) return;
                    Job.run(.{ .pool = work.pool, .candidate = work.candidates[i], .is_existing = work.candidates[i].existing });
                }
            }
        };
        var work: Work = .{ .pool = pool, .candidates = fresh.items };
        var validators: std.Io.Group = .init;
        defer validators.cancel(pool.io);
        for (0..@min(validation_workers, fresh.items.len)) |_| {
            validators.concurrent(pool.io, Work.run, .{&work}) catch break;
        }
        try validators.await(pool.io);
        pool.mu.lock();
        pool.pool_validated_ms = pool.now();
        pool.last_refresh_error = if (pool.entries.items.len == 0) "no public proxy passed HTTPS validation" else "";
        pool.mu.unlock();
        const capacity = pool.diag();
        pool.logInfo("proxy pool: {d} validated, {d} ready (target {d}; {d} cached candidates)", .{ pool.alive(), capacity.ready, target_ready, capacity.candidates });
    }

    const Candidate = struct {
        host: []u8,
        port: u16,
        /// Best-known latency estimate (JSON metadata when available; probe
        /// latency fills in after first validation). Used to sort candidates
        /// so fresh validation starts with the likeliest-good proxies.
        latency_estimate: u32 = std.math.maxInt(u32) / 2,
        /// True when this candidate is an idle route being re-validated
        /// (score recovery), false for a brand-new list candidate.
        existing: bool = false,
    };
    const CandidateList = std.ArrayList(Candidate);

    /// Download sources concurrently, interleave them, and retain a reservoir.
    /// Each refill advances through it instead of retrying the same first page.
    fn fetchLists(pool: *Pool, alloc: Allocator) !CandidateList {
        var out: CandidateList = .empty;
        errdefer {
            for (out.items) |c| alloc.free(c.host);
            out.deinit(alloc);
        }
        pool.mu.lock();
        const refresh_lists = pool.candidates.items.len == 0 or pool.now() - pool.lists_fetched_ms >= list_refresh_ms;
        pool.mu.unlock();
        if (refresh_lists) {
            const Fetch = struct {
                fn run(p: *Pool, url: []const u8, body: *?[]u8) void {
                    body.* = timed([]u8, p.io, 7000, httpGet, .{ p, p.alloc, url }) catch null;
                }
            };
            var bodies: [list_sources.len]?[]u8 = @splat(null);
            defer for (bodies) |body| if (body) |bytes| alloc.free(bytes);
            var group: std.Io.Group = .init;
            defer group.cancel(pool.io);
            for (list_sources, 0..) |src, i| try group.concurrent(pool.io, Fetch.run, .{ pool, src, &bodies[i] });
            try group.await(pool.io);
            var merged = try mergeSources(alloc, &bodies);
            try mergeJsonMetadata(pool, alloc, &bodies, &merged);
            pool.mu.lock();
            if (merged.items.len != 0) {
                for (pool.candidates.items) |c| alloc.free(c.host);
                pool.candidates.deinit(alloc);
                pool.candidates = merged;
                pool.candidate_cursor = 0;
            } else merged.deinit(alloc);
            pool.lists_fetched_ms = pool.now();
            pool.mu.unlock();
        }
        pool.mu.lock();
        defer pool.mu.unlock();
        // Re-validate idle, eligible routes first, preserving their warm leases.
        for (pool.entries.items) |e| {
            if (e.in_flight or e.blocked_until_ms > pool.now() or pool.quarantined(e.host, e.port)) continue;
            if (pool.now() - e.validated_ms < validation_refresh_ms) continue;
            try out.append(alloc, .{ .host = try alloc.dupe(u8, e.host), .port = e.port, .existing = true });
        }
        // Validation starts on the likeliest-good candidates (lowest
        // latency_estimate), then walks forward through the reservoir. The
        // walk is purely cursor-based, so repeated passes always cover new
        // territory instead of re-testing the head of the list.
        const existing_len = out.items.len;
        std.mem.sort(Candidate, out.items[existing_len..], {}, lessCandidate);
        const count = @min(pool.candidates.items.len, max_validate_batch);
        for (0..count) |_| {
            const c = pool.candidates.items[pool.candidate_cursor % pool.candidates.items.len];
            pool.candidate_cursor += 1;
            if (pool.quarantined(c.host, c.port)) continue;
            const exists = for (pool.entries.items) |e| {
                if (e.port == c.port and std.mem.eql(u8, e.host, c.host)) break true;
            } else false;
            if (exists) continue;
            try out.append(alloc, .{ .host = try alloc.dupe(u8, c.host), .port = c.port });
        }
        return out;
    }

    fn lessCandidate(_: void, a: Candidate, b: Candidate) bool {
        return a.latency_estimate < b.latency_estimate;
    }

    fn mergeSources(alloc: Allocator, bodies: []const ?[]const u8) !CandidateList {
        var out: CandidateList = .empty;
        errdefer {
            for (out.items) |c| alloc.free(c.host);
            out.deinit(alloc);
        }
        const positions = try alloc.alloc(usize, bodies.len);
        defer alloc.free(positions);
        @memset(positions, 0);
        var seen: std.StringHashMap(void) = .init(alloc);
        defer {
            var keys = seen.keyIterator();
            while (keys.next()) |key| alloc.free(key.*);
            seen.deinit();
        }
        while (out.items.len < max_candidates) {
            var more = false;
            for (bodies, 0..) |body, i| {
                const bytes = body orelse continue;
                if (positions[i] >= bytes.len) continue;
                more = true;
                const start = positions[i];
                const end = if (std.mem.indexOfScalarPos(u8, bytes, start, '\n')) |n| n else bytes.len;
                positions[i] = end + 1;
                var line = std.mem.trim(u8, bytes[start..end], " \t\r");
                if (std.mem.startsWith(u8, line, "http://")) line = line[7..];
                if (std.mem.startsWith(u8, line, "https://")) line = line[8..];
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const host = line[0..colon];
                const port = std.fmt.parseInt(u16, line[colon + 1 ..], 10) catch continue;
                if (port == 0) continue;
                _ = std.Io.net.IpAddress.parseIp4(host, port) catch continue;
                if (seen.contains(line)) continue;
                const key = try alloc.dupe(u8, line);
                try seen.put(key, {});
                try out.append(alloc, .{ .host = try alloc.dupe(u8, host), .port = port });
            }
            if (!more) break;
        }
        return out;
    }

    /// Folds per-proxy latency metadata from JSON sources into already-parsed
    /// candidates (matched by "ip:port"). Pure text bodies are skipped.
    fn mergeJsonMetadata(pool: *Pool, alloc: Allocator, bodies: []const ?[]const u8, out: *CandidateList) !void {
        _ = pool;
        var hp_buf: [64]u8 = undefined;
        for (bodies) |body| {
            const bytes = body orelse continue;
            const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
            if (trimmed.len < 2 or trimmed[0] != '[') continue;
            const parsed = std.json.parseFromSlice(std.json.Value, alloc, trimmed, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .array) continue;
            for (parsed.value.array.items) |item| {
                if (item != .object) continue;
                const proxy_str = (item.object.get("proxy") orelse item.object.get("ip") orelse continue);
                if (proxy_str != .string) continue;
                const host_port = proxy_str.string;
                const latency_val = item.object.get("latency_ms");
                if (latency_val == null or latency_val.? != .integer) continue;
                const latency: u32 = @intCast(@max(0, @min(std.math.maxInt(u32), latency_val.?.integer)));
                for (out.items) |*c| {
                    const hp = std.fmt.bufPrint(&hp_buf, "{s}:{d}", .{ c.host, c.port }) catch continue;
                    if (std.mem.eql(u8, hp, host_port)) {
                        c.latency_estimate = latency;
                        break;
                    }
                }
            }
        }
    }
};

/// A picked proxy, owned by the caller's arena.
pub const Picked = struct {
    host: []const u8,
    port: u16,
    index: usize,
    leased: bool = false,
};

/// Plain HTTP GET through no proxy (list sources are direct).
fn httpGet(pool: *Pool, alloc: Allocator, url: []const u8) ![]u8 {
    const uri = std.Uri.parse(url) catch return error.BadUri;
    var client: HttpClient = .{ .allocator = alloc, .io = pool.io };
    defer client.deinit();
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = .init(3),
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [512]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (@intFromEnum(response.head.status) / 100 != 2) return error.BadStatus;
    var transfer: [4096]u8 = undefined;
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(alloc);
    var reader = response.reader(&transfer);
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = try reader.readSliceShort(&buf);
        if (n == 0) break;
        try body.appendSlice(alloc, buf[0..n]);
        if (body.items.len > 4 * 1024 * 1024) break;
    }
    return try body.toOwnedSlice(alloc);
}

/// One-shot HTTPS probe through CONNECT to the NEUTRAL target, with origin
/// certificate validation. Returns true when the proxy reaches the open
/// internet (2xx). Public so the request path can re-check a proxy on a
/// 429/403 verdict to tell "origin rate-limit" from "dead proxy".
pub fn probeNeutralOk(io: std.Io, host: []const u8, port: u16) bool {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const proxy = arena.create(HttpClient.Proxy) catch return false;
    proxy.* = .{
        .protocol = .plain,
        .host = std.Io.net.HostName.init(arena.dupe(u8, host) catch return false) catch return false,
        .port = port,
        .authorization = null,
        .supports_connect = true,
    };
    const uri = std.Uri.parse(probe_url) catch return false;
    var client: HttpClient = .{ .allocator = arena, .io = io };
    defer client.deinit();
    client.http_proxy = proxy;
    client.https_proxy = proxy;
    var req = client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    }) catch return false;
    defer req.deinit();
    req.sendBodiless() catch return false;
    var redirect_buf: [512]u8 = undefined;
    const response = req.receiveHead(&redirect_buf) catch return false;
    return @intFromEnum(response.head.status) / 100 == 2;
}

fn probeThrough(pool: *Pool, host: []const u8, port: u16) !void {
    var arena_state = std.heap.ArenaAllocator.init(pool.alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const proxy = try arena.create(HttpClient.Proxy);
    proxy.* = .{
        .protocol = .plain,
        .host = try std.Io.net.HostName.init(try arena.dupe(u8, host)),
        .port = port,
        .authorization = null,
        .supports_connect = true,
    };
    const uri = std.Uri.parse(probe_url) catch return error.BadUri;
    var client: HttpClient = .{ .allocator = arena, .io = pool.io };
    defer client.deinit();
    client.http_proxy = proxy;
    client.https_proxy = proxy;
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirect_buf: [512]u8 = undefined;
    const response = try req.receiveHead(&redirect_buf);
    if (@intFromEnum(response.head.status) / 100 != 2) return error.BadStatus;
}

fn timeoutTask(io: std.Io, ms: u64) std.Io.Cancelable!void {
    try std.Io.sleep(io, .fromMilliseconds(@intCast(ms)), .awake);
}

pub fn timed(comptime T: type, io: std.Io, ms: u64, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) anyerror!T {
    const Result = union(enum) { result: anyerror!T, timeout: std.Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &buffer);
    defer _ = select.cancel();
    try select.concurrent(.timeout, timeoutTask, .{ io, ms });
    try select.concurrent(.result, func, args);
    var result = (try select.await());
    while (select.cancel()) |pending| {
        if (pending == .result and result == .timeout) {
            if (pending.result) |_| {
                result = pending;
            } else |_| {}
        }
    }
    return switch (result) {
        .result => |r| r,
        .timeout => error.Timeout,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "pool feedback follows endpoint identity after removals and cools only egress" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
    pool.stopping = true; // Deterministic fixtures must never fetch public lists.
    pool.lists_fetched_ms = nowMs();
    pool.pool_validated_ms = nowMs();
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 1001 });
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 1002 });
    const first = pool.pick(a).?;
    defer a.free(first.host);
    const second = pool.pick(a).?;
    defer a.free(second.host);
    try std.testing.expect(first.port != second.port);

    pool.report(first, 0, false);
    pool.report(first, 0, false);
    pool.report(second, 10, true);
    try std.testing.expectEqual(@as(usize, 1), pool.alive());
    // Origin 429 cools but never deletes (the route's health is the proxy's,
    // not the origin's).
    pool.routeStatus(second, 429);
    try std.testing.expectEqual(@as(usize, 1), pool.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), pool.alive()); // cooled, not removed
    pool.entries.items[0].blocked_until_ms = 0;
    pool.routeStatus(second, 200);
    try std.testing.expect(pool.entries.items[0].preferred);
    // Two proxy-attributable transport failures do drop it.
    pool.report(second, 0, false);
    pool.report(second, 0, false);
    try std.testing.expectEqual(@as(usize, 0), pool.entries.items.len);
}

test "probe deadline cancels stalled work" {
    try std.testing.expectError(error.Timeout, timed(void, std.testing.io, 10, timeoutTask, .{ std.testing.io, 60_000 }));
}

test "leases exclude concurrent use and request-local exclusions prevent replay" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
    pool.stopping = true;
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 9000 });
    const route = pool.pick(a).?;
    defer a.free(route.host);
    try std.testing.expect(pool.pick(a) == null);
    pool.report(route, 0, null);
    try std.testing.expect(pool.pickAvoiding(a, &.{route}) == null);
    const reused = pool.pick(a).?;
    defer a.free(reused.host);
    pool.report(reused, 5, true);
    try std.testing.expectEqual(@as(usize, 1), pool.alive());
}

test "failed route quarantine survives refresh publication and expires" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
    pool.stopping = true;
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 9001 });
    const route = pool.pick(a).?;
    defer a.free(route.host);
    // Two transport failures drop + quarantine the route.
    pool.report(route, 1, false);
    pool.report(route, 1, false);
    try std.testing.expectEqual(@as(usize, 0), pool.entries.items.len);
    try std.testing.expect(pool.quarantined("127.0.0.1", 9001));
    // While quarantined a re-published route is not pickable...
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 9001 });
    try std.testing.expect(pool.pick(a) == null);
    // ...but once the quarantine expires it is usable again.
    pool.quarantine[0].until = 0;
    const later = pool.pick(a).?;
    defer a.free(later.host);
    pool.report(later, 1, true);
}

test "background failures cannot evict a route with an active request" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
    pool.stopping = true;
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 9002 });
    const route = pool.pick(a).?;
    defer a.free(route.host);
    pool.report(.{ .host = route.host, .port = route.port, .index = 0 }, 0, false);
    try std.testing.expectEqual(@as(usize, 1), pool.entries.items.len);
    pool.report(route, 1, true);
}

test "fast successful routes are reused and model generation time is not probe latency" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
    pool.stopping = true;
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 1, .latency_ms = 900, .last_used = 0 });
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 2, .latency_ms = 100, .last_used = 20 });
    const fast = pool.pick(a).?;
    defer a.free(fast.host);
    try std.testing.expectEqual(@as(u16, 2), fast.port);
    pool.report(fast, 30_000, true);
    try std.testing.expectEqual(@as(u32, 100), pool.entries.items[1].latency_ms);
    const again = pool.pick(a).?;
    defer a.free(again.host);
    try std.testing.expectEqual(fast.port, again.port);
    pool.report(again, 0, null);
}

test "a real success refreshes validation freshness so working routes stay in rotation" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
    pool.stopping = true;
    // A route whose last validation is older than 2x the refresh interval is
    // normally unpickable; a real 2xx through it refreshes validated_ms.
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 7, .validated_ms = pool.now() - 3 * validation_refresh_ms });
    try std.testing.expect(pool.pick(a) == null); // aged out
    pool.entries.items[0].validated_ms = pool.now();
    const route = pool.pick(a).?;
    defer a.free(route.host);
    pool.report(route, 10, true); // success refreshes
    try std.testing.expect(pool.entries.items[0].validated_ms >= pool.now() - 1);
}

test "routeStatus cools but never deletes; only repeated transport fails drop" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
    pool.stopping = true;
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 3 });
    const route = pool.pick(a).?;
    defer a.free(route.host);
    // Many origin 429s: the route cools, is never deleted.
    for (0..20) |_| pool.routeStatus(route, 429);
    try std.testing.expectEqual(@as(usize, 1), pool.entries.items.len);
    pool.entries.items[0].blocked_until_ms = 0;
    pool.routeStatus(route, 200);
    // Release the held lease, then the route is pickable again.
    pool.report(route, 0, null);
    const re = pool.pick(a).?;
    defer a.free(re.host);
    // Two transport failures attributable to the proxy do drop it.
    pool.report(re, 0, false);
    pool.report(re, 0, false);
    try std.testing.expectEqual(@as(usize, 0), pool.entries.items.len);
}

test "neutral probe failure drops only after repeated strikes; recovery helps" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
    pool.stopping = true;
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 4001 });
    const route = pool.pick(a).?;
    defer a.free(route.host);
    // One neutral failure bumps twice but stays under max_fails.
    pool.reportProbeFailure("127.0.0.1", 4001);
    try std.testing.expectEqual(@as(usize, 1), pool.entries.items.len);
    // A subsequent success on the neutral probe recovers the score.
    pool.mu.lock();
    pool.entries.items[0].fails = 1;
    pool.mu.unlock();
    pool.report(route, 5, true);
    try std.testing.expectEqual(@as(u32, 0), pool.entries.items[0].fails);
    // A second neutral failure reaches max_fails and drops it.
    pool.reportProbeFailure("127.0.0.1", 4001);
    try std.testing.expectEqual(@as(usize, 0), pool.entries.items.len);
}

test "origin-throttle breaker trips per-provider on distinct egresses and opens" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
    pool.stopping = true;

    for (0..10) |_| {
        try std.testing.expect(!pool.noteOriginThrottle("p1/", "10.0.0.1"));
    }
    try std.testing.expect(!pool.originThrottleOpen("p1/"));

    try std.testing.expect(!pool.noteOriginThrottle("p1/", "10.0.0.2"));
    try std.testing.expect(!pool.noteOriginThrottle("p1/", "10.0.0.3"));
    try std.testing.expect(pool.noteOriginThrottle("p1/", "10.0.0.4"));
    try std.testing.expect(pool.originThrottleOpen("p1/"));

    // A different provider is NOT paused by p1's throttle.
    try std.testing.expect(!pool.originThrottleOpen("p2/"));

    pool.clearOriginThrottle("p1/");
    try std.testing.expect(!pool.originThrottleOpen("p1/"));

    try std.testing.expect(!pool.noteOriginThrottle("p1/", "10.0.0.5"));
    try std.testing.expect(!pool.noteOriginThrottle("p1/", "10.0.0.6"));
    try std.testing.expect(pool.noteOriginThrottle("p1/", "10.0.0.7"));
    pool.origin_breaker_until_ms[Pool.breakerSlot("p1/")] = 0;
    try std.testing.expect(!pool.originThrottleOpen("p1/"));
}

test "noteOriginThrottleRoute cools the route and honors retry-after" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
    pool.stopping = true;
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 6001 });
    const route = pool.pick(a).?;
    defer a.free(route.host);
    pool.report(route, 0, null); // release the lease
    // With Retry-After 5s, the route is cooled ~5s and never deleted.
    const cool = pool.noteOriginThrottleRoute("p/", "127.0.0.1", 6001, 5000);
    try std.testing.expect(cool >= 5000);
    try std.testing.expectEqual(@as(usize, 1), pool.entries.items.len);
    try std.testing.expect(pool.entries.items[0].blocked_until_ms > pool.now());
    // Origin 429s never drop the route.
    for (0..20) |_| pool.routeStatus(route, 429);
    try std.testing.expectEqual(@as(usize, 1), pool.entries.items.len);
}

test "repeated route-cooling never keeps the provider breaker open" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
    pool.stopping = true;
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 6002 });
    const route = pool.pick(a).?;
    defer a.free(route.host);
    pool.report(route, 0, null);
    // Simulate the origin 429ing every request for a while: each 429 cools
    // the route (and trips the breaker a few times), but a route-cooling call
    // on its own must NEVER extend an already-open breaker into the future.
    // Trip the breaker first via three distinct hosts.
    pool.mu.lock();
    const s = Pool.breakerSlot("p/");
    pool.origin_breaker_until_ms[s] = 0;
    pool.mu.unlock();
    _ = pool.noteOriginThrottle("p/", "10.1.0.1"); // baseline
    _ = pool.noteOriginThrottle("p/", "10.1.0.2");
    _ = pool.noteOriginThrottle("p/", "10.1.0.3");
    const tripped = pool.noteOriginThrottle("p/", "10.1.0.4");
    try std.testing.expect(tripped);
    const open_until = pool.origin_breaker_until_ms[Pool.breakerSlot("p/")];
    // Now cool a route for this provider: must not move the breaker later.
    _ = pool.noteOriginThrottleRoute("p/", "127.0.0.1", 6002, 0);
    try std.testing.expectEqual(open_until, pool.origin_breaker_until_ms[Pool.breakerSlot("p/")]);
    // The breaker still closes on its own once the open window elapses.
    pool.origin_breaker_until_ms[Pool.breakerSlot("p/")] = 0;
    try std.testing.expect(!pool.originThrottleOpen("p/"));
}

test "sources interleave, deduplicate and reject malformed addresses" {
    const a = std.testing.allocator;
    const sources = [_]?[]const u8{ "1.1.1.1:80\n2.2.2.2:80\n999.1.1.1:80", "http://3.3.3.3:8080\n1.1.1.1:80\ninvalid:99", null };
    var merged = try Pool.mergeSources(a, &sources);
    defer {
        for (merged.items) |c| a.free(c.host);
        merged.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 3), merged.items.len);
    try std.testing.expectEqualStrings("3.3.3.3", merged.items[1].host);
}

test "refills advance through cached candidates without fetching lists" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
    pool.stopping = true;
    pool.lists_fetched_ms = nowMs();
    for (0..800) |i| try pool.candidates.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = @intCast(i + 1) });
    var first = try Pool.fetchLists(&pool, a);
    defer {
        for (first.items) |c| a.free(c.host);
        first.deinit(a);
    }
    var next = try Pool.fetchLists(&pool, a);
    defer {
        for (next.items) |c| a.free(c.host);
        next.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 800), first.items.len);
    try std.testing.expectEqual(@as(u16, 1), first.items[0].port);
    try std.testing.expectEqual(@as(u16, 1), next.items[0].port);
    try std.testing.expectEqual(@as(usize, 800), next.items.len);
}

test "queued request acquires released lease without concurrent reuse" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
    pool.stopping = true;
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 9 });
    const held = pool.pick(a).?;
    defer a.free(held.host);
    const Release = struct {
        fn run(p: *Pool, r: Picked) void {
            std.Io.sleep(p.io, .fromMilliseconds(50), .awake) catch return;
            p.report(r, 10, true);
        }
    };
    var group: std.Io.Group = .init;
    defer group.cancel(pool.io);
    try group.concurrent(pool.io, Release.run, .{ &pool, held });
    const acquired = (try pool.waitForRoute(a, &.{}, 500)).?;
    defer a.free(acquired.host);
    try std.testing.expectEqual(held.port, acquired.port);
    pool.report(acquired, 0, null);
    try group.await(pool.io);
    try std.testing.expectEqual(@as(usize, 0), pool.waiting);
}

test "queue timeout releases admission without losing an active route" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
    pool.stopping = true;
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 10 });
    const held = pool.pick(a).?;
    defer a.free(held.host);
    try std.testing.expect((try pool.waitForRoute(a, &.{}, 50)) == null);
    try std.testing.expectEqual(@as(usize, 0), pool.waiting);
    try std.testing.expect(pool.entries.items[0].in_flight);
    pool.report(held, 0, null);
    try std.testing.expectEqual(@as(usize, 1), pool.readyCount());
}

test "new callers cannot bypass queued tickets when a route becomes free" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
    pool.stopping = true;
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 20 });
    pool.waiting = 1;
    pool.wait_tickets[0] = 5;
    try std.testing.expect(pool.pick(a) == null);
    try std.testing.expect(!pool.entries.items[0].in_flight);
    pool.waiting = 0;
    const route = pool.pick(a).?;
    defer a.free(route.host);
    pool.report(route, 0, null);
}

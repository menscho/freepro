// Public HTTP CONNECT proxy pool. Only HTTPS-validated candidates are exposed.
// List fetches and probes have deadlines; the owned task group is joined on
// shutdown. TLS authenticates the origin and encrypts credentials inside the
// tunnel. Transport failures and egress throttling never poison API keys.

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

/// Monotonic-enough wall clock for latency math (reuses std.time when the
/// build exposes it; upstream.zig's Stopwatch is not importable here).
fn stopwatchStartMs() i64 {
    return nowMs();
}

pub const max_pool: usize = 64;
pub const max_latency_ms: u64 = 6000;
pub const max_fails: u32 = 1;
pub const list_refresh_ms: i64 = 15 * 60 * 1000; // re-pull lists every 15 min
pub const validation_refresh_ms: i64 = 60 * 1000; // re-validate pool every 5 min
pub const max_validate_batch: usize = 96;

/// One alive proxy. `host` is heap-owned by the pool.
pub const Entry = struct {
    host: []const u8,
    port: u16,
    latency_ms: u32 = 0,
    fails: u32 = 0,
    /// Monotonic counter: higher = used more recently (skip for fairness).
    last_used: u64 = 0,
    preferred: bool = false,
    in_flight: bool = false,
    blocked_until_ms: i64 = 0,
    validated_ms: i64 = 0,
};

/// Public sources. All return plain `ip:port` text lists and refresh
/// upstream on their own cadence (minutes), so a plain re-fetch is a fresh
/// list. Checked: all four respond without auth.
const list_sources = [_][]const u8{
    "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt",
    "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt",
    "https://api.proxyscrape.com/v2/?request=displayproxies&protocol=http&timeout=3000",
    "https://www.proxy-list.download/api/v1/get?type=http",
    "https://proxyspace.pro/http.txt",
};

/// Validate HTTPS tunneling against the OpenCode catalog, without credentials.
const probe_url = "https://opencode.ai/zen/v1/models";

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
    clock: u64 = 0,
    quarantine: [128]struct { host: [15]u8 = @splat(0), len: usize = 0, port: u16 = 0, until: i64 = 0 } = @splat(.{}),
    quarantine_next: usize = 0,
    last_refresh_error: []const u8 = "",
    /// Optional message sink (already-formatted string). Stringify at the call site.
    log_msg: ?*const fn ([]const u8) void = null,

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

    /// Called before each proxied request: keeps the pool fresh without
    /// ever blocking the caller. Returns the best entry (copy) or null.
    pub fn pick(self: *Pool, arena: Allocator) ?Picked {
        return self.pickAvoiding(arena, &.{});
    }
    fn quarantined(self: *Pool, host: []const u8, port: u16) bool {
        for (self.quarantine) |q| if (q.until > self.now() and q.port == port and std.mem.eql(u8, q.host[0..q.len], host)) return true;
        return false;
    }
    fn quarantineRoute(self: *Pool, host: []const u8, port: u16) void {
        if (host.len > 15) return;
        const q = &self.quarantine[self.quarantine_next % self.quarantine.len];
        q.* = .{ .len = host.len, .port = port, .until = self.now() + 5 * 60 * 1000 };
        @memcpy(q.host[0..host.len], host);
        self.quarantine_next +%= 1;
    }
    pub fn pickAvoiding(self: *Pool, arena: Allocator, avoided: []const Picked) ?Picked {
        self.maybeRefresh();

        self.mu.lock();
        defer self.mu.unlock();
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
                (e.preferred == best_preferred and (e.last_used < best_used or
                    (e.last_used == best_used and e.latency_ms < best_latency)));
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

    /// Report the outcome of using a proxy. Success keeps it (EMA latency);
    /// failure bumps strikes and drops it at max_fails. Fast: O(1) lock.
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
            e.fails = 0;
            e.latency_ms = if (e.latency_ms == 0) latency_ms else (e.latency_ms * 3 + latency_ms) / 4;
        } else {
            e.fails += 1;
            if (e.fails >= max_fails) {
                const host = self.entries.items[index].host;
                self.quarantineRoute(host, e.port);
                self.logInfo("proxy pool: dropping {s} ({d} fails)", .{ host, e.fails });
                _ = self.entries.orderedRemove(index);
                self.alloc.free(host);
            }
        }
    }

    /// Origin throttling belongs to this egress route, not the API key.
    pub fn routeStatus(self: *Pool, picked: Picked, status: u16) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.entries.items) |*e| {
            if (e.port != picked.port or !std.mem.eql(u8, e.host, picked.host)) continue;
            if (status >= 200 and status < 300) {
                e.preferred = true;
                e.validated_ms = self.now();
            }
            if (status == 429 or status == 403 or status == 408 or status >= 502) {
                e.preferred = false;
                e.blocked_until_ms = self.now() + 60_000;
            }
            return;
        }
    }

    /// Diagnostics: tracked entries and whether a refresh pass is running.
    pub fn diag(self: *Pool) struct { tracked: usize, working: bool, lists_ms: i64, validated_ms: i64, last_error: []const u8 } {
        self.mu.lock();
        defer self.mu.unlock();
        return .{
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

    /// Kick a background list-fetch + validation cycle when stale. Never
    /// blocks the caller: work happens on detached pool tasks.
    pub fn maybeRefresh(self: *Pool) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.stopping or self.working) return;
        const stale = self.now() - self.pool_validated_ms > validation_refresh_ms or
            self.now() - self.lists_fetched_ms > list_refresh_ms or
            (self.entries.items.len < 3 and self.now() - self.pool_validated_ms > 10_000);
        if (!stale) return;
        const ctx = self.alloc.create(RefreshCtx) catch return;
        ctx.* = .{ .pool = self };
        self.working = true;
        self.tasks.concurrent(self.io, refreshTask, .{ctx}) catch {
            self.working = false;
            self.alloc.destroy(ctx);
        };
    }

    const RefreshCtx = struct {
        pool: *Pool,
    };

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
        // Candidates remain private until HTTPS CONNECT, TLS and the target
        // catalog response have all succeeded. Publish survivors immediately.
        const Job = struct {
            pool: *Pool,
            candidate: Candidate,
            fn run(job: @This()) void {
                job.pool.mu.lock();
                const blocked = job.pool.quarantined(job.candidate.host, job.candidate.port);
                job.pool.mu.unlock();
                if (blocked) return;
                const t0 = nowMs();
                timed(void, job.pool.io, max_latency_ms, probeThrough, .{
                    job.pool, job.candidate.host, job.candidate.port,
                }) catch {
                    job.pool.report(.{ .host = job.candidate.host, .port = job.candidate.port, .index = 0 }, 0, false);
                    return;
                };
                const p = job.pool;
                p.mu.lock();
                defer p.mu.unlock();
                if (p.quarantined(job.candidate.host, job.candidate.port)) return;
                for (p.entries.items) |*e| {
                    if (e.port == job.candidate.port and std.mem.eql(u8, e.host, job.candidate.host)) {
                        e.latency_ms = @intCast(@max(0, nowMs() - t0));
                        e.validated_ms = nowMs();
                        return;
                    }
                }
                if (p.entries.items.len >= max_pool) return;
                const host = p.alloc.dupe(u8, job.candidate.host) catch return;
                p.entries.append(p.alloc, .{ .host = host, .port = job.candidate.port, .latency_ms = @intCast(@max(0, nowMs() - t0)), .validated_ms = nowMs() }) catch {
                    p.alloc.free(host);
                    return;
                };
            }
        };
        var offset: usize = 0;
        while (offset < fresh.items.len and offset < 600) : (offset += 24) {
            try std.Io.checkCancel(pool.io);
            var group: std.Io.Group = .init;
            defer group.cancel(pool.io);
            for (fresh.items[offset..@min(offset + 24, fresh.items.len)]) |cand| {
                group.concurrent(pool.io, Job.run, .{Job{ .pool = pool, .candidate = cand }}) catch break;
            }
            try group.await(pool.io);
            if (pool.alive() >= 12) break;
        }
        pool.mu.lock();
        var stale_index: usize = 0;
        while (stale_index < pool.entries.items.len) {
            if (!pool.entries.items[stale_index].in_flight and pool.now() - pool.entries.items[stale_index].validated_ms > 2 * validation_refresh_ms) {
                const stale = pool.entries.orderedRemove(stale_index);
                alloc.free(stale.host);
            } else stale_index += 1;
        }
        pool.pool_validated_ms = pool.now();
        pool.last_refresh_error = if (pool.entries.items.len == 0) "no public proxy passed HTTPS validation" else "";
        pool.mu.unlock();
        pool.logInfo("proxy pool: {d} HTTPS-validated proxies", .{pool.alive()});
    }

    const Candidate = struct {
        host: []u8,
        port: u16,
        latency_estimate: u32 = std.math.maxInt(u32) / 2,
    };
    const CandidateList = std.ArrayList(Candidate);

    /// Pull all list sources into one deduped candidate list.
    fn fetchLists(pool: *Pool, alloc: Allocator) !CandidateList {
        var out: CandidateList = .empty;
        errdefer {
            for (out.items) |*c| alloc.free(c.host);
            out.deinit(alloc);
        }
        var seen: std.StringHashMap(void) = std.StringHashMap(void).init(alloc);
        defer {
            var it = seen.keyIterator();
            while (it.next()) |k| alloc.free(k.*);
            seen.deinit();
        }

        pool.mu.lock();
        for (pool.entries.items) |entry| {
            if (entry.in_flight or pool.quarantined(entry.host, entry.port)) continue;
            const copy = alloc.dupe(u8, entry.host) catch continue;
            out.append(alloc, .{ .host = copy, .port = entry.port }) catch alloc.free(copy);
        }
        const refresh_lists = pool.now() - pool.lists_fetched_ms >= list_refresh_ms or out.items.len < 3;
        pool.mu.unlock();
        if (!refresh_lists) return out;

        for (list_sources) |src| {
            const body = timed([]u8, pool.io, 10000, httpGet, .{ pool, alloc, src }) catch continue;
            defer alloc.free(body);
            var it = std.mem.splitAny(u8, body, "\r\n");
            while (it.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t");
                if (line.len == 0 or line[0] == '#') continue;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const host = line[0..colon];
                const port = std.fmt.parseInt(u16, line[colon + 1 ..], 10) catch continue;
                if (port == 0) continue;
                if (host.len < 7 or host.len > 15) continue; // ipv4 only
                var valid = true;
                for (host) |c| {
                    if ((c < '0' or c > '9') and c != '.') {
                        valid = false;
                        break;
                    }
                }
                if (!valid) continue;
                const key = try std.fmt.allocPrint(alloc, "{s}:{d}", .{ host, port });
                if (seen.contains(key)) {
                    alloc.free(key);
                    continue;
                }
                try seen.put(key, {});
                try out.append(alloc, .{
                    .host = try alloc.dupe(u8, host),
                    .port = port,
                });
            }
            if (out.items.len > 600) break; // plenty of candidates
        }
        pool.mu.lock();
        pool.lists_fetched_ms = pool.now();
        pool.mu.unlock();
        return out;
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
    // toOwnedSlice: the freed slice must match the full allocation, not the
    // logical length (DebugAllocator tracks exact sizes).
    return try body.toOwnedSlice(alloc);
}

/// One-shot HTTPS probe through CONNECT, with origin certificate validation.
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
    var response = try req.receiveHead(&redirect_buf);
    if (@intFromEnum(response.head.status) != 200) return error.BadStatus;
    var transfer: [4096]u8 = undefined;
    const body = try response.reader(&transfer).allocRemaining(arena, .limited(2 * 1024 * 1024));
    const json = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    if (json.value != .object) return error.InvalidCatalog;
    const data = json.value.object.get("data") orelse return error.InvalidCatalog;
    if (data != .array or data.array.items.len == 0) return error.InvalidCatalog;
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

test "pool feedback follows endpoint identity after removals and cools only egress" {
    const a = std.testing.allocator;
    var pool = Pool.init(a, std.testing.io);
    defer pool.deinit();
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
    pool.report(second, 10, true);
    try std.testing.expectEqual(@as(usize, 1), pool.alive());
    pool.routeStatus(second, 429);
    try std.testing.expectEqual(@as(usize, 0), pool.alive());
    try std.testing.expect(pool.pick(a) == null);
    pool.entries.items[0].blocked_until_ms = 0;
    pool.routeStatus(second, 200);
    try std.testing.expect(pool.entries.items[0].preferred);
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
    pool.report(route, 1, false);
    try std.testing.expect(pool.quarantined("127.0.0.1", 9001));
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 9001 });
    try std.testing.expect(pool.pick(a) == null);
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

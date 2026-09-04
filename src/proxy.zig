// src/proxy.zig
//
// freepro embedded proxy engine (Wave 2, Task 07: Zig 0.16 port).
//
// Multithreaded OpenAI-compatible HTTP listener on 127.0.0.1:<port>:
//
//   * GET  /v1/models             merged upstream catalog, provider prefixes
//   * POST /v1/chat/completions   prefix routing + key failover + SSE/JSON relay
//   * POST /v1/completions        same pipeline, completions endpoint
//   * GET  / or /health           local status probe for the dashboard
//
// Design notes:
//   * std only. No httpz / DVUI / GUI dependency. Upstream forwarding uses
//     HttpClient (TLS included); the listener is an std.Io.net loopback
//     server with one accept thread plus one detached worker thread per
//     downstream connection.
//   * Targets the installed Zig 0.16 toolchain. Compared with the 0.13 shape:
//       - std.Thread.Mutex is gone: Proxy/FakeUpstream use the local Mutex
//         shim below (blocking OS mutex where present, otherwise a
//         yield-spinning std.atomic.Mutex lock — same approach as
//         src/rotator.zig, whose critical sections are equally tiny).
//       - std.time.timestamp/milliTimestamp/sleep are gone: nowUnixSec()/nowMs()
//         prefer them where present and otherwise read the OS clock directly
//         (Windows RtlGetSystemTimePrecise, otherwise clock_gettime), so this
//         file stays Io-free outside socket code. Waits spin on
//         std.Thread.yield().
//       - Managed std.ArrayList is gone: every buffer uses the unmanaged
//         std.ArrayList(T) = .empty + explicit allocator arguments.
//       - std.net is gone: listener, test client and fake upstream use
//         std.Io.net (IpAddress.parseIp4 / listen / accept / connect) with
//         std.Io.Reader / std.Io.Writer framing. Upstream forwarding uses the
//         new HttpClient flow (client.request / sendBodyComplete /
//         sendBodiless / receiveHead / response.reader), mirroring
//         src/upstream.zig.
//       - std.Thread.Pool is gone: workers are detached threads counted in
//         active_workers (stop() drains them); pool_threads now bounds
//         concurrent workers via accept-loop backpressure instead of queueing.
//   * Ownership: Proxy borrows `config`, `rotator`, `logger` and `metrics`
//     (all owned by main.zig and guaranteed to outlive the proxy). Per-request
//     scratch memory comes from a per-connection arena that is freed when the
//     worker finishes. Functions returning owned slices are marked `Owned`;
//     everything else borrows.
//   * Threading: one accept-loop thread plus detached worker threads. The
//     config must not be mutated while the proxy is running; main.zig restarts
//     the proxy (stop -> mutate -> start) on config changes. The rotator must
//     be thread-safe; the standalone fallback picker is guarded by key_mu.
//   * Upstream timeout: HttpClient exposes no per-request timeout knob,
//     so `config.timeout_ms` is validated/stored by models.zig and honored
//     for listener behavior; upstream stalls rely on OS TCP timeouts and are
//     treated as transport failures (null status) that trigger failover.
//   * Logger/Metrics hooks are type-erased facades (see below), NOT imports of
//     logger.zig / metrics.zig: those modules are owned by sibling agents and
//     were still on the 0.13 spelling when this file was ported, and importing
//     them would break this file's build. Any pointer type exposing the same
//     method surface plugs in via Logger.wrap(ptr) / Metrics.wrap(ptr):
//         Logger:  info/warn/err(comptime fmt, args) + failover(from_1based,
//                  status, to_1based) + logRequest(method, path, status,
//                  latency_ms)
//         Metrics: begin() + end(provider_idx: ?usize, latency_ms, status) +
//                  noteFailover()
//     so main.zig flips with:
//         const proxy_mod = @import("proxy.zig");
//         Proxy.init(alloc, cfg, .{
//             .rotator = &rot,
//             .logger = proxy_mod.Logger.wrap(&log),
//             .metrics = proxy_mod.Metrics.wrap(&metrics),
//         })
//
// Shared contracts used (see src/models.zig):
//   Key{key, state, last_used, cooldown_until, consecutive_errors, enabled},
//   Provider{display_name, base_url, prefix, description, keys, headers},
//   CustomHeader{key, value},
//   ProxyConfig{port=8080, providers, auto_start, cooldown_secs=60, timeout_ms}.
// Rotator API bridged (see "Rotator bridge" below):
//   nextHealthyKey(provider_idx) ?usize / reportResult(p_idx, k_idx, ?u16).

const std = @import("std");
const HttpClient = @import("http_client.zig");
const builtin = @import("builtin");
const models = @import("models.zig");
const rotator_mod = @import("rotator.zig");
const freeproxy = @import("freeproxy.zig");
const responses_mod = @import("responses.zig");

const Allocator = std.mem.Allocator;
// Transport: blocking Winsock on Windows (the 0.16 std.Io.net backend is
// unreliable there for accepted sockets — see netwin.zig), std.Io.net
// everywhere else. Both expose IpAddress/Server/Stream with the same
// method names used below.
const Net = if (builtin.os.tag == .windows) @import("netwin.zig") else std.Io.net;

pub const Rotator = if (@hasDecl(rotator_mod, "Rotator"))
    rotator_mod.Rotator
else
    @compileError("rotator.zig must expose a Rotator type with nextHealthyKey()/reportResult(); see proxy.zig header");

// ---------------------------------------------------------------------------
// Mutex shim (mirrors src/rotator.zig)
//
// Prefers the blocking OS mutex where the standard library provides one
// (`std.Thread.Mutex` on Zig <= 0.15) and falls back to a yield-spinning lock
// over the `std.atomic.Mutex` spinlock on toolchains that removed it (0.16
// only ships the spinlock). Critical sections below are tiny and never block
// on I/O while held, so a spin is only ever brief.
// ---------------------------------------------------------------------------

pub const Mutex = if (@hasDecl(std.Thread, "Mutex"))
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

// ---------------------------------------------------------------------------
// Wall clock (Io-free; mirrors src/rotator.zig)
//
// Prefers std.time.timestamp()/milliTimestamp() where present (Zig <= 0.15)
// and otherwise reads the OS clock directly (Zig 0.16 removed std.time's wall
// clock; it lives behind std.Io there, which proxy threads must not depend on
// for timestamps).
// ---------------------------------------------------------------------------

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

fn osUnixSec() i64 {
    if (builtin.os.tag == .windows) {
        // 100ns ticks since 1601-01-01; 11_644_473_600s = 1601 -> 1970.
        const ticks_100ns: i64 = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        return @divFloor(ticks_100ns, 10_000_000) - 11_644_473_600;
    }
    return posixRealtimeSec();
}

fn osUnixMs() i64 {
    if (builtin.os.tag == .windows) {
        const ticks_100ns: i64 = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        return @divFloor(ticks_100ns, 10_000) - 11_644_473_600_000;
    }
    var ts: std.posix.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1_000 +
        @as(i64, @intCast(@divFloor(ts.nsec, 1_000_000)));
}

/// Unix seconds for key cooldown bookkeeping.
fn nowUnixSec() i64 {
    if (@hasDecl(std.time, "timestamp")) return std.time.timestamp();
    return osUnixSec();
}

/// Unix milliseconds for request latency stamps.
fn nowMs() i64 {
    if (@hasDecl(std.time, "milliTimestamp")) return std.time.milliTimestamp();
    return osUnixMs();
}

/// Process-wide Io shared by the listener, workers and upstream forwards.
///
/// This MUST be a real multi-threaded pool: `std.Io.Threaded
/// .global_single_threaded` is a single-threaded cooperative loop, so the
/// first blocking socket call (e.g. accept()) parks its only worker and
/// every later call from any other thread deadlocks. The pool below is
/// created once from the page allocator and lives for the process lifetime
/// (callers like main.zig may still inject their own pool via
/// ProxyOptions.io instead).
var pool_instance: ?std.Io.Threaded = null;
var pool_mu: Mutex = .{};

fn sharedPool() std.Io {
    pool_mu.lock();
    defer pool_mu.unlock();
    if (pool_instance == null) {
        pool_instance = std.Io.Threaded.init(std.heap.page_allocator, .{});
    }
    return pool_instance.?.io();
}

fn sharedIo() std.Io {
    return sharedPool();
}

// ---------------------------------------------------------------------------
// Logger / Metrics hook facades
//
// Type-erased adapters so this file never imports logger.zig / metrics.zig
// (both are mid-port by sibling agents). Any pointer type with the documented
// method surface plugs in via wrap(); a null hook disables logging/metrics.
// Wire formats stay proxy-side for info/warn/err; failover and request lines
// are delegated so the real logger owns their exact text.
// ---------------------------------------------------------------------------

/// Structural logger hook. Wrap any `*T` where T exposes:
///   info/warn/err(comptime fmt: []const u8, args: anytype) void
///   failover(from_key_1based: usize, status: u16, to_key_1based: usize) void
///   logRequest(method: []const u8, path: []const u8, status: u16,
///              latency_ms: u64) void
pub const Logger = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        info: *const fn (ctx: *anyopaque, msg: []const u8) void,
        warn: *const fn (ctx: *anyopaque, msg: []const u8) void,
        err: *const fn (ctx: *anyopaque, msg: []const u8) void,
        failover: *const fn (ctx: *anyopaque, from_1based: usize, status: u16, to_1based: usize) void,
        log_request: *const fn (ctx: *anyopaque, method: []const u8, path: []const u8, status: u16, latency_ms: u64) void,
    };

    /// Adapt a concrete logger pointer (e.g. *logger_mod.Logger). The pointer
    /// must outlive the proxy (main.zig owns it).
    pub fn wrap(ptr: anytype) Logger {
        const P = @TypeOf(ptr);
        const Adapters = struct {
            fn info(ctx: *anyopaque, msg: []const u8) void {
                const self: P = @ptrCast(@alignCast(ctx));
                self.info("{s}", .{msg});
            }
            fn warn(ctx: *anyopaque, msg: []const u8) void {
                const self: P = @ptrCast(@alignCast(ctx));
                self.warn("{s}", .{msg});
            }
            fn err(ctx: *anyopaque, msg: []const u8) void {
                const self: P = @ptrCast(@alignCast(ctx));
                self.err("{s}", .{msg});
            }
            fn failover(ctx: *anyopaque, from_1based: usize, status: u16, to_1based: usize) void {
                const self: P = @ptrCast(@alignCast(ctx));
                self.failover(from_1based, status, to_1based);
            }
            fn logRequest(ctx: *anyopaque, method: []const u8, path: []const u8, status: u16, latency_ms: u64) void {
                const self: P = @ptrCast(@alignCast(ctx));
                self.logRequest(method, path, status, latency_ms);
            }
        };
        const vt: VTable = .{
            .info = Adapters.info,
            .warn = Adapters.warn,
            .err = Adapters.err,
            .failover = Adapters.failover,
            .log_request = Adapters.logRequest,
        };
        return .{ .ctx = ptr, .vtable = &vt };
    }

    pub fn info(self: Logger, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "(log message too long)";
        self.vtable.info(self.ctx, msg);
    }

    pub fn warn(self: Logger, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "(log message too long)";
        self.vtable.warn(self.ctx, msg);
    }

    pub fn err(self: Logger, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "(log message too long)";
        self.vtable.err(self.ctx, msg);
    }

    /// Exact wire format the console shows on rotation (owned by the wrapped
    /// logger): `[FAILOVER] Key #N hit 429 -> Rotating to Key #M` (1-based).
    pub fn failover(self: Logger, from_key_1based: usize, status: u16, to_key_1based: usize) void {
        self.vtable.failover(self.ctx, from_key_1based, status, to_key_1based);
    }

    /// One line per proxied client call, e.g.
    /// `POST /v1/chat/completions -> 200 (42ms)`.
    pub fn logRequest(self: Logger, method: []const u8, path: []const u8, status: u16, latency_ms: u64) void {
        self.vtable.log_request(self.ctx, method, path, status, latency_ms);
    }
};

/// Structural metrics hook. Wrap any `*T` where T exposes:
///   begin() void
///   end(provider_idx: ?usize, latency_ms: u64, status: u16) void
///   noteFailover() void
pub const Metrics = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        begin: *const fn (ctx: *anyopaque) void,
        end: *const fn (ctx: *anyopaque, provider_idx: ?usize, latency_ms: u64, status: u16) void,
        note_failover: *const fn (ctx: *anyopaque) void,
        record_model_usage: ?*const fn (ctx: *anyopaque, model: []const u8, input: u64, output: u64, cached: u64, day: u32) void = null,
        record_usage: ?*const fn (ctx: *anyopaque, input: u64, output: u64, cached: u64, day: u32) void = null,
    };

    /// Adapt a concrete metrics pointer (e.g. *metrics_mod.Metrics). The
    /// pointer must outlive the proxy (main.zig owns it).
    pub fn wrap(ptr: anytype) Metrics {
        const P = @TypeOf(ptr);
        const C = @typeInfo(P).pointer.child;
        const Adapters = struct {
            fn begin(ctx: *anyopaque) void {
                const self: P = @ptrCast(@alignCast(ctx));
                self.begin();
            }
            fn end(ctx: *anyopaque, provider_idx: ?usize, latency_ms: u64, status: u16) void {
                const self: P = @ptrCast(@alignCast(ctx));
                self.end(provider_idx, latency_ms, status);
            }
            fn noteFailover(ctx: *anyopaque) void {
                const self: P = @ptrCast(@alignCast(ctx));
                self.noteFailover();
            }
            fn recordModelUsage(ctx: *anyopaque, model: []const u8, input: u64, output: u64, cached: u64, day: u32) void {
                const self: P = @ptrCast(@alignCast(ctx));
                self.recordModelUsage(model, input, output, cached, day);
            }
            fn recordUsage(ctx: *anyopaque, input: u64, output: u64, cached: u64, day: u32) void {
                const self: P = @ptrCast(@alignCast(ctx));
                self.recordUsage(input, output, cached, day);
            }
        };
        const vt: VTable = .{
            .begin = Adapters.begin,
            .end = Adapters.end,
            .note_failover = Adapters.noteFailover,
            // Only wired when the concrete metrics type supports usage
            // capture; test stubs omit it.
            .record_usage = if (@hasDecl(C, "recordUsage")) Adapters.recordUsage else null,
            .record_model_usage = if (@hasDecl(C, "recordModelUsage")) Adapters.recordModelUsage else null,
        };
        return .{ .ctx = ptr, .vtable = &vt };
    }

    /// Mark the start of one proxied request. Always pair with end().
    pub fn begin(self: Metrics) void {
        self.vtable.begin(self.ctx);
    }

    /// Mark the end of one proxied request. provider_idx is null when the
    /// request never routed (e.g. unknown prefix).
    pub fn end(self: Metrics, provider_idx: ?usize, latency_ms: u64, status: u16) void {
        self.vtable.end(self.ctx, provider_idx, latency_ms, status);
    }

    /// Called every time the proxy swaps to a new key mid-request.
    pub fn noteFailover(self: Metrics) void {
        self.vtable.note_failover(self.ctx);
    }

    /// Record token usage for one completed request (day = days-since-epoch).
    /// Optional hook: stub metrics (tests) may omit it.
    pub fn recordModelUsage(self: Metrics, model: []const u8, input: u64, output: u64, cached: u64, day: u32) void {
        if (self.vtable.record_model_usage) |f| f(self.ctx, model, input, output, cached, day) else self.recordUsage(input, output, cached, day);
    }
    pub fn recordUsage(self: Metrics, input: u64, output: u64, cached: u64, day: u32) void {
        if (self.vtable.record_usage) |f| f(self.ctx, input, output, cached, day);
    }
};

// ---------------------------------------------------------------------------
// Limits and error set
// ---------------------------------------------------------------------------

/// Cap for the inbound HTTP head (request line + headers).
pub const max_header_bytes: usize = 64 * 1024;
/// Cap for an inbound client body (chat payloads are small; 16 MiB is generous).
pub const max_body_bytes: usize = 16 * 1024 * 1024;
/// Cap for a buffered upstream error body kept for verbatim forwarding.
pub const max_upstream_error_bytes: usize = 256 * 1024;
/// Cap for a buffered upstream /v1/models document per provider.
pub const max_models_bytes: usize = 4 * 1024 * 1024;
/// Upper bound on upstream attempts per client request (failover loop guard).
pub const max_key_attempts: usize = 64;
/// Ceiling on concurrent downstream workers; the accept loop back-pressures
/// past it (see acceptLoop). Clamped to >= 1 in init.
pub const default_pool_threads: usize = 16;
/// The proxy binds loopback only; it is never exposed on LAN interfaces.
pub const loopback_ip: []const u8 = "127.0.0.1";

pub const ProxyError = error{
    FreeProxyUnavailable,
    AlreadyRunning,
    BadRequest,
    HeadersTooLarge,
    BodyTooLarge,
    UnknownModelPrefix,
    NoHealthyKey,
};

// ---------------------------------------------------------------------------
// Rotator bridge
//
// The shared contract is rotator.zig's live API: nextHealthyKey(provider_idx)
// picks the next usable key and reportResult(provider_idx, key_idx, status)
// folds the outcome back, with a null status for timeout / transport failure
// (see the rotator header for the 2xx/401/403/429/cooldown mapping). Both
// calls use the receiver form; this thin layer is the single adaptation point
// if the rotator surface ever changes shape again.
// ---------------------------------------------------------------------------

fn pickViaRotator(rot: *Rotator, provider_idx: usize) ?usize {
    return rot.nextHealthyKey(provider_idx);
}

fn reportViaRotator(rot: *Rotator, provider_idx: usize, key_idx: usize, status: ?u16) void {
    rot.reportResult(provider_idx, key_idx, status);
}

// ---------------------------------------------------------------------------
// Proxy
// ---------------------------------------------------------------------------

pub const ProxyOptions = struct {
    rotator: ?*Rotator = null,
    logger: ?Logger = null,
    metrics: ?Metrics = null,
    pool_threads: usize = default_pool_threads,
    /// Event loop for sockets. Defaults to the shared process pool when null.
    io: ?std.Io = null,
    /// Optional dashboard/API hook (implemented by dashboard.zig, installed
    /// by the GUI binary). Called first for every request; returning non-null
    /// means the hook fully handled it (status code). Keeps proxy.zig free
    /// of dashboard imports (no module cycle).
    dashboard: ?DashboardHook = null,
    /// Experimental free public proxy pool. When set, providers with
    /// use_free_proxy enabled route their upstream traffic through it.
    free_proxies: ?*freeproxy.Pool = null,
};

/// Dashboard hook surface. `body` is the raw request body bytes.
pub const DashboardHook = struct {
    ctx: *anyopaque,
    handle_fn: *const fn (
        ctx: *anyopaque,
        method: []const u8,
        path: []const u8,
        body: []const u8,
        alloc: Allocator,
        writer: *std.Io.Writer,
    ) ?u16,
};

pub const Proxy = struct {
    allocator: Allocator,
    config: *models.ProxyConfig,
    rotator: ?*Rotator,
    logger: ?Logger,
    metrics: ?Metrics,
    pool_threads: usize,
    io: std.Io,
    dashboard: ?DashboardHook,
    free_proxies: ?*freeproxy.Pool,

    mu: Mutex,
    key_mu: Mutex,
    /// Guards the per-provider model catalogs only. Separate from `mu`
    /// because request handlers (which may touch catalogs) must never take
    /// `mu`: the accept loop holds `mu` across a blocking accept().
    catalog_mu: Mutex,
    running: std.atomic.Value(bool),
    server: ?Net.Server,
    /// Pool group owning the accept task and all connection workers.
    /// Socket IO must run on pool threads: alertable APC waits in the 0.16
    /// Windows backend never complete on raw std.Thread.spawn threads.
    group: std.Io.Group,
    active_workers: std.atomic.Value(usize),
    in_flight: std.atomic.Value(usize),
    total_served: std.atomic.Value(u64),
    standalone_cursors: []usize,
    bound_port: u16,

    pub fn init(allocator: Allocator, config: *models.ProxyConfig, options: ProxyOptions) Proxy {
        return .{
            .allocator = allocator,
            .config = config,
            .rotator = options.rotator,
            .logger = options.logger,
            .metrics = options.metrics,
            .pool_threads = @max(1, options.pool_threads),
            .io = options.io orelse sharedIo(),
            .dashboard = options.dashboard,
            .free_proxies = options.free_proxies,
            .mu = .{},
            .key_mu = .{},
            .catalog_mu = .{},
            .running = std.atomic.Value(bool).init(false),
            .server = null,
            .group = std.Io.Group.init,
            .active_workers = std.atomic.Value(usize).init(0),
            .in_flight = std.atomic.Value(usize).init(0),
            .total_served = std.atomic.Value(u64).init(0),
            .standalone_cursors = &[_]usize{},
            .bound_port = config.port,
        };
    }

    /// Release proxy-owned state. Stops the listener first when running.
    /// The borrowed config/rotator/logger/metrics are left untouched.
    pub fn deinit(self: *Proxy) void {
        self.stop();
    }

    pub fn isRunning(self: *Proxy) bool {
        return self.running.load(.seq_cst);
    }

    /// Port from the config the listener was bound with.
    pub fn boundPort(self: *Proxy) u16 {
        return self.bound_port;
    }

    /// Requests currently being handled across all worker threads.
    pub fn inFlightCount(self: *Proxy) usize {
        return self.in_flight.load(.seq_cst);
    }

    /// Total requests handled since init (monotonic).
    pub fn totalServedCount(self: *Proxy) u64 {
        return self.total_served.load(.seq_cst);
    }

    /// Bind 127.0.0.1:port and serve until stop(). Thread-safe; starting
    /// twice returns error.AlreadyRunning.
    pub fn start(self: *Proxy) !void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.running.load(.seq_cst)) return ProxyError.AlreadyRunning;

        const addr = try Net.IpAddress.parseIp4(loopback_ip, self.config.port);
        var server = try addr.listen(self.io, .{ .reuse_address = true });
        errdefer server.deinit(self.io);

        const cursors = try self.allocator.alloc(usize, self.config.providers.len);
        @memset(cursors, 0);
        errdefer self.allocator.free(cursors);

        self.server = server;
        self.standalone_cursors = cursors;
        self.bound_port = self.config.port;
        self.running.store(true, .seq_cst);
        errdefer self.running.store(false, .seq_cst);

        // The accept loop blocks in socket IO, so it runs as a pool task:
        // pool worker threads service APC waits correctly, raw spawned
        // threads do not (Windows backend).
        self.group.concurrent(self.io, acceptTask, .{self}) catch |err| {
            self.running.store(false, .seq_cst);
            return err;
        };

        self.logInfo("proxy listening on 127.0.0.1:{d}", .{self.config.port});
    }

    /// Pool entry point for the accept loop (Group task fns take args only).
    fn acceptTask(self: *Proxy) void {
        self.acceptLoop();
    }

    /// Stop the listener, drain workers, release start()-owned state.
    /// Thread-safe and idempotent; safe to call when not running.
    pub fn stop(self: *Proxy) void {
        if (!self.running.load(.seq_cst)) return;
        self.running.store(false, .seq_cst);

        // Poke the loopback socket so a blocking accept() wakes up. The poke
        // itself runs on the pool: socket IO from a raw caller thread may
        // never complete (see sharedPool).
        pokePortOnPool(self.bound_port);

        // Ask every pool task (accept loop + workers) to unwind at its next
        // cancelation point, then wait for the drain. Futex-based, so this is
        // safe from any thread including the GUI/stdin threads. Never call
        // this from a proxy worker thread (dashboard handlers run on
        // workers): the pool join below would wait for the caller itself.
        // Worker-side teardown uses initiateStop/closeListener instead.
        self.group.cancel(self.io);
        self.group.await(self.io) catch {};

        self.mu.lock();
        defer self.mu.unlock();
        if (self.server) |*s| {
            s.deinit(self.io);
            self.server = null;
        }
        if (self.standalone_cursors.len != 0) {
            self.allocator.free(self.standalone_cursors);
            self.standalone_cursors = &[_]usize{};
        }
        self.logInfo("proxy stopped", .{});
    }

    /// Non-blocking half of stop(): signal the accept loop to exit and wake
    /// it, without joining any pool task. Safe from a proxy worker thread
    /// (dashboard handlers run on workers). Pair with closeListener(): wait
    /// for peer requests to drain, close the socket, mutate, then start().
    /// A later full stop() from a non-worker thread reclaims group state.
    pub fn initiateStop(self: *Proxy) void {
        if (!self.running.load(.seq_cst)) return;
        self.running.store(false, .seq_cst);
        pokePortOnPool(self.bound_port);
    }

    /// Close the listening socket without joining workers. Worker-side
    /// counterpart to the tail of stop(); idempotent with it.
    pub fn closeListener(self: *Proxy) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.server) |*s| {
            s.deinit(self.io);
            self.server = null;
        }
        if (self.standalone_cursors.len != 0) {
            self.allocator.free(self.standalone_cursors);
            self.standalone_cursors = &[_]usize{};
        }
    }

    // -- logging helpers (nullable logger) -------------------------------

    fn logInfo(self: *Proxy, comptime fmt: []const u8, args: anytype) void {
        if (self.logger) |l| l.info(fmt, args);
    }

    fn logWarn(self: *Proxy, comptime fmt: []const u8, args: anytype) void {
        if (self.logger) |l| l.warn(fmt, args);
    }

    fn logErr(self: *Proxy, comptime fmt: []const u8, args: anytype) void {
        if (self.logger) |l| l.err(fmt, args);
    }

    // -- key selection / reporting ----------------------------------------

    /// Next usable key index for a provider, or null when exhausted.
    /// Prefers the wired rotator; falls back to an internal round-robin over
    /// models.Key state when no rotator is attached (tests / embedding).
    fn pickKey(self: *Proxy, provider_idx: usize) ?usize {
        if (self.rotator) |rot| return pickViaRotator(rot, provider_idx);
        return self.pickStandaloneKey(provider_idx);
    }

    /// Fold one attempt's outcome back into the pool. A null status means
    /// timeout / transport failure and cools the key down.
    fn reportKey(self: *Proxy, provider_idx: usize, key_idx: usize, status: ?u16) void {
        if (self.rotator) |rot| {
            reportViaRotator(rot, provider_idx, key_idx, status);
            return;
        }
        self.reportStandalone(provider_idx, key_idx, status);
    }

    fn pickStandaloneKey(self: *Proxy, provider_idx: usize) ?usize {
        self.key_mu.lock();
        defer self.key_mu.unlock();
        if (provider_idx >= self.config.providers.len) return null;
        const prov = &self.config.providers[provider_idx];
        if (prov.keys.len == 0) return null;
        if (provider_idx >= self.standalone_cursors.len) return null;
        const now = nowUnixSec();
        const base = self.standalone_cursors[provider_idx] % prov.keys.len;
        var i: usize = 0;
        while (i < prov.keys.len) : (i += 1) {
            const idx = (base + i) % prov.keys.len;
            if (prov.keys[idx].isUsable(now)) {
                self.standalone_cursors[provider_idx] = idx + 1;
                return idx;
            }
        }
        return null;
    }

    fn reportStandalone(self: *Proxy, provider_idx: usize, key_idx: usize, status: ?u16) void {
        self.key_mu.lock();
        defer self.key_mu.unlock();
        if (provider_idx >= self.config.providers.len) return;
        const prov = &self.config.providers[provider_idx];
        if (key_idx >= prov.keys.len) return;
        const key = &prov.keys[key_idx];
        const now = nowUnixSec();
        const cooldown = self.config.cooldown_secs;
        const s = status orelse {
            key.markCooldown(now, cooldown);
            return;
        };
        if (models.isHealthyStatus(s)) {
            key.markSuccess(now);
        } else if (models.statusSuggestsDead(s)) {
            key.markDead(now);
        } else if (models.statusSuggestsCooldown(s)) {
            key.markCooldown(now, cooldown);
        } else {
            key.consecutive_errors +|= 1;
            key.last_used = now;
        }
    }

    // -- accept loop -------------------------------------------------------

    fn acceptLoop(self: *Proxy) void {
        while (self.running.load(.seq_cst)) {
            // Backpressure: pool_threads bounds concurrent workers. The loop
            // yields here instead of queueing, so memory stays bounded under
            // burst load and stop() can always drain.
            while (self.active_workers.load(.seq_cst) >= self.pool_threads) {
                if (!self.running.load(.seq_cst)) return;
                std.Thread.yield() catch {};
            }
            const conn = self.acceptOne() catch |err| {
                if (!self.running.load(.seq_cst)) break;
                self.logWarn("accept failed: {s}", .{@errorName(err)});
                continue;
            };
            if (!self.running.load(.seq_cst)) {
                conn.close(self.io);
                break;
            }
            const ctx = self.allocator.create(ConnContext) catch {
                conn.close(self.io);
                continue;
            };
            ctx.* = .{ .proxy = self, .conn = conn };
            _ = self.active_workers.fetchAdd(1, .seq_cst);
            self.group.concurrent(self.io, connTask, .{ctx}) catch |err| {
                self.logWarn("worker spawn failed: {s}", .{@errorName(err)});
                conn.close(self.io);
                self.allocator.destroy(ctx);
                _ = self.active_workers.fetchSub(1, .seq_cst);
                continue;
            };
        }
    }

    fn acceptOne(self: *Proxy) !Net.Stream {
        self.mu.lock();
        defer self.mu.unlock();
        const s = &(self.server orelse return error.ServerClosed);
        return try s.accept(self.io);
    }
};

const ConnContext = struct {
    proxy: *Proxy,
    conn: Net.Stream,
};

/// Pool entry point for one connection (Group task fns take args only).
fn connTask(ctx: *ConnContext) void {
    handleConn(ctx);
}

fn handleConn(ctx: *ConnContext) void {
    const self = ctx.proxy;
    const io = self.io;
    defer {
        ctx.conn.close(io);
        self.allocator.destroy(ctx);
        _ = self.active_workers.fetchSub(1, .seq_cst);
    }
    handleConnection(self, ctx.conn) catch |err| {
        if (self.logger) |l| l.warn("request failed: {s}", .{@errorName(err)});
    };
}

// ---------------------------------------------------------------------------
// Inbound HTTP framing
// ---------------------------------------------------------------------------

const InboundRequest = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8,
};

/// One chunk from a stream reader: returns as soon as ANY bytes are in hand.
/// `std.Io.Reader.readSliceShort` fills its whole destination and only
/// short-reads at EOF, which deadlocks request/response loops (the client
/// waits for our reply while we wait to fill the buffer). `readVec` on every
/// backend (std.Io.net, netwin) performs at most one socket read. Returns 0
/// at clean EOF.
fn readChunk(r: *std.Io.Reader, dest: []u8) !usize {
    var data = [1][]u8{dest};
    const n = r.readVec(&data) catch |err| switch (err) {
        error.EndOfStream => return 0,
        else => return err,
    };
    return n;
}

fn readFramedMessage(reader: *std.Io.Reader, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var tmp: [8192]u8 = undefined;
    while (std.mem.indexOf(u8, buf.items, "\r\n\r\n") == null) {
        if (buf.items.len >= max_header_bytes) return ProxyError.HeadersTooLarge;
        const n = try readChunk(reader, &tmp);
        if (n == 0) return error.EndOfStream;
        try buf.appendSlice(alloc, tmp[0..n]);
    }
    const head_end = std.mem.indexOf(u8, buf.items, "\r\n\r\n").? + 4;
    const content_len = parseContentLength(buf.items[0..head_end]);
    if (content_len > max_body_bytes) return ProxyError.BodyTooLarge;
    const total = head_end + content_len;
    while (buf.items.len < total) {
        const n = try readChunk(reader, &tmp);
        if (n == 0) return error.EndOfStream;
        try buf.appendSlice(alloc, tmp[0..n]);
    }
    return buf.items;
}

fn parseContentLength(head: []const u8) usize {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch 0;
    }
    return 0;
}

fn parseRequest(raw: []const u8) !InboundRequest {
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return ProxyError.BadRequest;
    const head = raw[0..head_end];
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return ProxyError.BadRequest;
    const line = head[0..line_end];
    var parts = std.mem.splitScalar(u8, line, ' ');
    const method = parts.next() orelse return ProxyError.BadRequest;
    var target = parts.next() orelse return ProxyError.BadRequest;
    if (parts.next() == null) return ProxyError.BadRequest;
    if (method.len == 0 or target.len == 0) return ProxyError.BadRequest;

    // Tolerate absolute-form targets ("POST http://host/v1/x HTTP/1.1").
    if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://")) {
        const scheme_end = std.mem.indexOf(u8, target, "://").? + 3;
        if (std.mem.indexOfScalarPos(u8, target, scheme_end, '/')) |slash| {
            target = target[slash..];
        } else {
            target = "/";
        }
    }
    // Strip the query string for routing.
    const path = if (std.mem.indexOfScalar(u8, target, '?')) |q| target[0..q] else target;

    const content_len = parseContentLength(head);
    const body_off = head_end + 4;
    if (raw.len < body_off + content_len) return ProxyError.BadRequest;
    return .{
        .method = method,
        .path = path,
        .body = raw[body_off .. body_off + content_len],
    };
}

// ---------------------------------------------------------------------------
// Downstream responses
// ---------------------------------------------------------------------------

fn reasonPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Error",
    };
}

fn sendJson(writer: *std.Io.Writer, status: u16, body: []const u8) !void {
    try writer.print(
        "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ status, reasonPhrase(status), body.len },
    );
    if (body.len != 0) try writer.writeAll(body);
}

fn sendStatus(writer: *std.Io.Writer, status: u16, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(
        &buf,
        "{{\"error\":{{\"message\":\"{s}\",\"type\":\"proxy_error\",\"code\":{d}}}}}",
        .{ message, status },
    ) catch "{\"error\":{\"message\":\"proxy error\",\"type\":\"proxy_error\"}}";
    try sendJson(writer, status, body);
}

fn sendSseHead(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Transfer-Encoding: chunked\r\n" ++
            "Connection: close\r\n\r\n",
    );
}

fn sendSseChunk(writer: *std.Io.Writer, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    var hexbuf: [16]u8 = undefined;
    const hex = std.fmt.bufPrint(&hexbuf, "{x}", .{bytes.len}) catch unreachable;
    try writer.writeAll(hex);
    try writer.writeAll("\r\n");
    try writer.writeAll(bytes);
    try writer.writeAll("\r\n");
    // Flush per chunk: the client asked for a live stream, so bytes must hit
    // the socket now rather than waiting for the writer buffer to fill.
    try writer.flush();
}

fn sendSseEnd(writer: *std.Io.Writer) !void {
    try writer.writeAll("0\r\n\r\n");
}

// ---------------------------------------------------------------------------
// Routing + completion pipeline
// ---------------------------------------------------------------------------

const UpstreamEndpoint = enum {
    chat_completions,
    completions,

    fn path(self: UpstreamEndpoint) []const u8 {
        return switch (self) {
            .chat_completions => "chat/completions",
            .completions => "completions",
        };
    }
};

/// True when a failed attempt should rotate to the next key: transient
/// (429/408/5xx sans 501), auth (401/403), or transport failure (status 0).
/// Deterministic client errors (400/404/422/...) return false.
pub fn shouldFailoverStatus(status: u16) bool {
    if (status == 0) return true;
    if (models.isHealthyStatus(status)) return false;
    if (models.statusSuggestsCooldown(status)) return true;
    if (models.statusSuggestsDead(status)) return true;
    return false;
}

/// Join a provider base URL and an endpoint path. Owned by the caller.
/// Documented rule: base_url is scheme://host plus the API root prefix
/// (include /v1 when the API lives there, e.g. "https://opencode.ai/zen/v1/").
pub fn joinUpstreamUrl(alloc: Allocator, base_url: []const u8, endpoint_path: []const u8) ![]u8 {
    const base = std.mem.trimEnd(u8, base_url, "/");
    const path = std.mem.trimStart(u8, endpoint_path, "/");
    return try std.fmt.allocPrint(alloc, "{s}/{s}", .{ base, path });
}

fn handleConnection(self: *Proxy, stream: Net.Stream) !void {
    const t0 = nowMs();
    _ = self.in_flight.fetchAdd(1, .seq_cst);
    var metrics_started = false;

    var method: []const u8 = "?";
    var path: []const u8 = "?";
    var status: u16 = 500;
    var provider_idx: ?usize = null;
    // True when the dashboard hook served this request (API calls, static
    // assets). Those are control traffic, not proxied requests: they must
    // not inflate total_served, skew latency metrics, or flood the console.
    var dashboard_req = false;

    // Arena first: its deinit defer must be registered BEFORE the logging
    // defer below so request strings stay alive until after logRequest runs
    // (defers run LIFO; reversing this order is a use-after-free).
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    defer {
        _ = self.in_flight.fetchSub(1, .seq_cst);
        const latency: u64 = @intCast(@max(0, nowMs() - t0));
        if (metrics_started) if (self.metrics) |m| m.end(provider_idx, latency, status);
        if (dashboard_req) {
            // Dashboard/API traffic: no served-count, log only failures.
            if (status >= 400) {
                if (self.logger) |l| l.warn("dashboard {s} {s} -> {d}", .{ method, path, status });
            }
        } else {
            _ = self.total_served.fetchAdd(1, .seq_cst);
            if (self.logger) |l| l.logRequest(method, path, status, latency);
        }
    }

    var rbuf: [8192]u8 = undefined;
    var wbuf: [32768]u8 = undefined;
    var stream_reader = stream.reader(self.io, &rbuf);
    var stream_writer = stream.writer(self.io, &wbuf);
    const reader = &stream_reader.interface;
    const writer = &stream_writer.interface;
    defer writer.flush() catch {};

    const raw = readFramedMessage(reader, alloc) catch {
        sendStatus(writer, 400, "malformed http request") catch {};
        status = 400;
        return;
    };
    const req = parseRequest(raw) catch {
        sendStatus(writer, 400, "malformed http request") catch {};
        status = 400;
        return;
    };
    method = req.method;
    path = req.path;

    status = routeRequest(self, writer, alloc, req, &provider_idx, &dashboard_req, &metrics_started) catch |err| {
        if (self.logger) |l| l.err("route {s} {s}: {s}", .{ req.method, req.path, @errorName(err) });
        sendStatus(writer, 500, "internal proxy error") catch {};
        status = 500;
        return;
    };
}

fn routeRequest(
    self: *Proxy,
    writer: *std.Io.Writer,
    alloc: Allocator,
    req: InboundRequest,
    provider_out: *?usize,
    is_dashboard_out: *bool,
    metrics_started: *bool,
) !u16 {
    const is_get = std.ascii.eqlIgnoreCase(req.method, "GET");
    const is_post = std.ascii.eqlIgnoreCase(req.method, "POST");

    // Dashboard + JSON API (GUI binary installs the hook; headless does not).
    if (self.dashboard) |hook| {
        if (hook.handle_fn(hook.ctx, req.method, req.path, req.body, alloc, writer)) |hstatus| {
            is_dashboard_out.* = true;
            provider_out.* = null;
            return hstatus;
        }
    }

    if (self.metrics) |m| m.begin();
    metrics_started.* = true;

    if (is_get and std.mem.eql(u8, req.path, "/v1/models")) {
        return try handleModels(self, writer, alloc);
    }
    if (is_post and std.mem.eql(u8, req.path, "/v1/chat/completions")) {
        return try handleCompletions(self, writer, alloc, req, .chat_completions, provider_out);
    }
    if (is_post and std.mem.eql(u8, req.path, "/v1/completions")) {
        return try handleCompletions(self, writer, alloc, req, .completions, provider_out);
    }
    if (is_get and (std.mem.eql(u8, req.path, "/") or std.mem.eql(u8, req.path, "/health"))) {
        return try handleHealth(self, writer);
    }
    try sendStatus(writer, 404, "unknown endpoint; freepro serves /v1/models and /v1/*completions");
    return 404;
}

fn handleHealth(self: *Proxy, writer: *std.Io.Writer) !u16 {
    var buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"status\":\"ok\",\"service\":\"freepro\",\"port\":{d},\"in_flight\":{d},\"total_served\":{d}}}", .{ self.bound_port, self.inFlightCount(), self.totalServedCount() });
    try sendJson(writer, 200, body);
    return 200;
}

// -- JSON payload helpers (arena-owned) ---------------------------------------

const ModelAndStream = struct {
    model: []const u8, // Owned (arena)
    stream: bool,
};

fn extractModelAndStream(alloc: Allocator, body: []const u8) !ModelAndStream {
    // Malformed JSON is a client error, not an internal one.
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return ProxyError.BadRequest;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return ProxyError.BadRequest,
    };
    const m = obj.get("model") orelse return ProxyError.BadRequest;
    const model = switch (m) {
        .string => |s| s,
        else => return ProxyError.BadRequest,
    };
    if (model.len == 0) return ProxyError.BadRequest;
    var stream = false;
    if (obj.get("stream")) |s| {
        stream = switch (s) {
            .bool => |b| b,
            else => false,
        };
    }
    return .{ .model = try alloc.dupe(u8, model), .stream = stream };
}

/// Stringify a JSON value to an owned slice. Same version shim as models.zig:
/// valueAlloc on newer std, stringifyAlloc on 0.13.x.
fn stringifyValueAlloc(alloc: Allocator, v: std.json.Value) ![]u8 {
    if (comptime @hasDecl(std.json.Stringify, "valueAlloc")) {
        return try std.json.Stringify.valueAlloc(alloc, v, .{});
    } else {
        return try std.json.stringifyAlloc(alloc, v, .{});
    }
}

/// Return a copy of a chat/completions body with "model" replaced by the
/// upstream (prefix-stripped) name. Owned by the caller (arena).
fn rewriteModelField(alloc: Allocator, body: []const u8, upstream_model: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return ProxyError.BadRequest;
    var root = parsed.value;
    const obj = switch (root) {
        .object => |*o| o,
        else => return ProxyError.BadRequest,
    };
    const entry = obj.getPtr("model") orelse return ProxyError.BadRequest;
    entry.* = .{ .string = upstream_model };
    return try stringifyValueAlloc(alloc, root);
}

// -- upstream HTTP ------------------------------------------------------------

const AttemptOutcome = struct {
    status: u16,
    /// Buffered upstream body. Empty when the response was already relayed
    /// downstream (success path); holds the error document otherwise.
    body: []const u8,
};

fn headerNameEq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn isManagedHeader(name: []const u8) bool {
    return headerNameEq(name, "authorization") or
        headerNameEq(name, "content-length") or
        headerNameEq(name, "content-type") or
        headerNameEq(name, "accept-encoding") or
        headerNameEq(name, "host") or
        headerNameEq(name, "connection");
}

/// One attempt's upstream headers: bearer auth (or an explicit custom
/// Authorization override) as a headers-override value, an optional
/// Content-Type override, plus the provider static headers that std.http
/// does not manage itself. All slices borrow from arena-owned or
/// provider-owned memory that outlives the request.
const PrivHeaders = struct {
    auth_value: []const u8,
    content_type: ?[]const u8,
    user_agent: ?[]const u8,
    extras: []std.http.Header,
};

fn buildPrivHeaders(
    alloc: Allocator,
    prov: *const models.Provider,
    key_material: []const u8,
) !PrivHeaders {
    var extras: std.ArrayList(std.http.Header) = .empty;
    var content_type: ?[]const u8 = null;
    // Provider User-Agent rides the managed user_agent override: std.http
    // would otherwise overwrite extras with its own default
    // ("zig/x.y.z (std.http)"), which OpenCode's gateway rejects.
    var user_agent: ?[]const u8 = null;

    var auth_value: []const u8 = undefined;
    if (prov.findHeader("authorization")) |auth| {
        auth_value = auth;
    } else if (key_material.len != 0) {
        auth_value = try std.fmt.allocPrint(alloc, "Bearer {s}", .{key_material});
    } else {
        // Public catalog endpoints: no Authorization header at all.
        auth_value = "";
    }

    for (prov.headers) |h| {
        if (headerNameEq(h.key, "authorization")) continue; // handled above
        if (headerNameEq(h.key, "content-type")) {
            content_type = h.value;
            continue;
        }
        if (headerNameEq(h.key, "user-agent")) {
            user_agent = h.value;
            continue;
        }
        if (isManagedHeader(h.key)) continue; // client manages the rest
        try extras.append(alloc, .{ .name = h.key, .value = h.value });
    }
    return .{
        .auth_value = auth_value,
        .content_type = content_type,
        .user_agent = user_agent,
        .extras = extras.items,
    };
}

fn headerValueHas(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn bufferUpstreamBody(reader: *std.Io.Reader, alloc: Allocator, cap: usize) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    var chunk: [32768]u8 = undefined;
    while (true) {
        const n = try reader.readSliceShort(&chunk);
        if (n == 0) break;
        if (body.items.len + n > cap) return ProxyError.BodyTooLarge;
        try body.appendSlice(alloc, chunk[0..n]);
    }
    return body.items;
}

/// Single upstream attempt. On 2xx the response is relayed downstream
/// (chunked SSE when the client asked for stream=true or the upstream speaks
/// event-stream, buffered JSON otherwise) and body is empty. On other
/// statuses the error document is buffered and returned for the caller to
/// forward or fail over. Transport errors propagate as Zig errors so the
/// caller can report a null status and rotate.
/// Extract the routed upstream model (post prefix strip) from a chat body.
fn routed_model_of(cfg: *models.ProxyConfig, alloc: Allocator, provider_idx: usize, chat_body: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, chat_body, .{}) catch return null;
    defer parsed.deinit();
    const m = switch (parsed.value) {
        .object => |o| o.get("model") orelse return null,
        else => return null,
    };
    if (m != .string) return null;
    const routed = cfg.providers[provider_idx].stripPrefix(m.string);
    // The parse arena dies with `defer` above; copy the slice out.
    return alloc.dupe(u8, routed) catch null;
}

/// Client-facing prefixed model id for a provider. Owned by `alloc`.
fn fullModelId(cfg: *models.ProxyConfig, alloc: Allocator, provider_idx: usize, upstream_model: []const u8) []const u8 {
    if (provider_idx >= cfg.providers.len) return upstream_model;
    return std.fmt.allocPrint(alloc, "{s}{s}", .{
        cfg.providers[provider_idx].prefix,
        upstream_model,
    }) catch upstream_model;
}

/// Build one chat.completion.chunk SSE frame from a complete chat reply.
/// Always returns `alloc`-owned memory (the static fallbacks are copied).
fn synthChunk(alloc: Allocator, chat_body: []const u8, finish: ?[]const u8) ![]const u8 {
    const static_ok = "data: {}\n\n";
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, chat_body, .{}) catch
        return try alloc.dupe(u8, static_ok);
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return try alloc.dupe(u8, static_ok),
    };
    var content: []const u8 = "";
    var tool_calls: ?std.json.Value = null;
    var finish_reason: []const u8 = "stop";
    if (obj.get("choices")) |cv| {
        if (cv == .array and cv.array.items.len > 0 and cv.array.items[0] == .object) {
            if (cv.array.items[0].object.get("finish_reason")) |f| {
                if (f == .string) finish_reason = f.string;
            }
            const msg = cv.array.items[0].object.get("message");
            if (msg != null and msg.? == .object) {
                tool_calls = msg.?.object.get("tool_calls");
                if (msg.?.object.get("content")) |c| {
                    if (c == .string) content = c.string;
                }
            }
        }
    }
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "data: {\"object\":\"chat.completion.chunk\"");
    inline for (.{ "id", "model", "created" }) |k| {
        if (obj.get(k)) |v| {
            try out.appendSlice(alloc, ",\"" ++ k ++ "\":");
            try out.appendSlice(alloc, try stringifyValueAlloc(alloc, v));
        }
    }
    if (finish != null) {
        if (obj.get("usage")) |u| {
            try out.appendSlice(alloc, ",\"usage\":");
            try out.appendSlice(alloc, try stringifyValueAlloc(alloc, u));
        }
    }
    try out.appendSlice(alloc, ",\"choices\":[{\"index\":0,\"delta\":{\"content\":");
    const qc = try std.json.Stringify.valueAlloc(alloc, std.json.Value{ .string = if (finish == null) content else "" }, .{});
    try out.appendSlice(alloc, qc);
    if (finish == null) {
        if (tool_calls) |tc| {
            if (tc == .array) {
                try out.appendSlice(alloc, ",\"tool_calls\":[");
                for (tc.array.items, 0..) |call, i| {
                    var indexed = call;
                    if (indexed != .object) continue;
                    try indexed.object.put(alloc, "index", .{ .integer = @intCast(i) });
                    if (i > 0) try out.appendSlice(alloc, ",");
                    try out.appendSlice(alloc, try stringifyValueAlloc(alloc, indexed));
                }
                try out.appendSlice(alloc, "]");
            }
        }
    }
    try out.appendSlice(alloc, "},\"finish_reason\":");
    try out.appendSlice(alloc, if (finish != null)
        (std.json.Stringify.valueAlloc(alloc, std.json.Value{ .string = finish_reason }, .{}) catch try alloc.dupe(u8, "\"stop\""))
    else
        "null");
    try out.appendSlice(alloc, "}]}\n\n");
    return try out.toOwnedSlice(alloc);
}

var debug_file: ?std.fs.File = null;
fn dumpWireMsg(msg: []const u8) void {
    const f = std.fs.createFileAbsolute("D:/freepro/tmp-verify/wire_dbg.txt", .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch {};
    f.writeAll(msg) catch {};
}

/// Strip the provider prefix from a client-facing model id.
fn cfg_strip(cfg: *models.ProxyConfig, provider_idx: usize, model: []const u8) []const u8 {
    if (provider_idx >= cfg.providers.len) return model;
    return cfg.providers[provider_idx].stripPrefix(model);
}

/// Current UTC day as days-since-epoch, for the usage day buckets.
fn usageToday() u32 {
    return @intCast(@divFloor(nowMs(), 86_400_000));
}

/// Per-request token usage accumulator. Upstream responses carry usage in
/// the final JSON body (non-stream) or the last SSE chunk; some gateways
/// send partial/null usage per chunk, so each field keeps the max seen.
const UsageAccum = struct {
    input: u64 = 0,
    output: u64 = 0,
    cached: u64 = 0,
    alloc: Allocator = std.heap.page_allocator,
    line: std.ArrayList(u8) = .empty,
    oversized: bool = false,

    fn deinit(self: *UsageAccum) void {
        self.line.deinit(self.alloc);
    }

    fn scan(self: *UsageAccum, bytes: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, bytes, .{}) catch return;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return;
        const usage = root.object.get("usage") orelse return;
        if (usage != .object) return;
        self.input = @max(self.input, number(usage.object.get("prompt_tokens") orelse usage.object.get("input_tokens")));
        self.output = @max(self.output, number(usage.object.get("completion_tokens") orelse usage.object.get("output_tokens")));
        if (usage.object.get("prompt_tokens_details") orelse usage.object.get("input_tokens_details")) |details| {
            if (details == .object) self.cached = @max(self.cached, number(details.object.get("cached_tokens")));
        }
    }
    fn number(value: ?std.json.Value) u64 {
        const v = value orelse return 0;
        return if (v == .integer and v.integer >= 0) @intCast(v.integer) else 0;
    }
    fn scanSse(self: *UsageAccum, bytes: []const u8) void {
        for (bytes) |byte| {
            if (byte == '\n') {
                if (!self.oversized and std.mem.startsWith(u8, self.line.items, "data:"))
                    self.scan(std.mem.trim(u8, self.line.items[5..], " \r\t"));
                self.line.clearRetainingCapacity();
                self.oversized = false;
            } else if (!self.oversized) {
                if (self.line.items.len >= max_body_bytes) {
                    self.oversized = true;
                    continue;
                }
                self.line.append(self.alloc, byte) catch {
                    self.oversized = true;
                };
            }
        }
    }
};

// Zen is a mixed-protocol gateway, not a provider-wide Responses endpoint.
fn usesResponses(prov: *const models.Provider, model: []const u8) bool {
    const uri = std.Uri.parse(prov.base_url) catch return prov.wire_api == .openai_responses;
    const zen = if (uri.host) |h| std.ascii.eqlIgnoreCase(h.percent_encoded, "opencode.ai") else false;
    if (zen) {
        return std.mem.startsWith(u8, model, "gpt-") or
            std.mem.startsWith(u8, model, "o1") or std.mem.startsWith(u8, model, "o3") or
            std.mem.startsWith(u8, model, "o4") or std.mem.startsWith(u8, model, "grok-") or
            std.mem.startsWith(u8, model, "muse-");
    }
    return prov.wire_api == .openai_responses;
}

// Only an explicit always-thinking rejection permits a single repair retry.
fn needsThinkingRepair(status: u16, body: []const u8) bool {
    if (status != 400 and status != 500) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{}) catch
        return thinkingMessage(body);
    defer parsed.deinit();
    return thinkingValue(parsed.value);
}
fn thinkingMessage(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "该模型始终思考") != null or
        std.mem.indexOf(u8, body, "does not support disabling thinking") != null or
        std.mem.indexOf(u8, body, "always thinks") != null or
        std.mem.indexOf(u8, body, "Reasoning is mandatory for this endpoint and cannot be disabled") != null;
}
fn thinkingValue(v: std.json.Value) bool {
    if (v == .string) return thinkingMessage(v.string);
    if (v == .object) {
        if (v.object.get("message")) |m| if (thinkingValue(m)) return true;
        if (v.object.get("error")) |e| if (thinkingValue(e)) return true;
    }
    return false;
}

fn thinkingBody(alloc: Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    var root = parsed.value;
    if (root != .object) return ProxyError.BadRequest;
    try root.object.put(alloc, "reasoning_effort", .{ .string = "low" });
    if (root.object.getPtr("thinking")) |v| {
        if (v.* == .object) {
            try v.object.put(alloc, "type", .{ .string = "enabled" });
        } else v.* = .{ .bool = true };
    }
    if (root.object.getPtr("reasoning")) |v| {
        if (v.* == .object) {
            try v.object.put(alloc, "effort", .{ .string = "low" });
            _ = v.object.swapRemove("enabled");
        }
    }
    return stringifyValueAlloc(alloc, root);
}

fn providerBody(alloc: Allocator, prov: *const models.Provider, body: []const u8) ![]const u8 {
    const uri = std.Uri.parse(prov.base_url) catch return body;
    const host = uri.host orelse return body;
    if (!std.ascii.eqlIgnoreCase(host.percent_encoded, "inference-api.nousresearch.com")) return body;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    var root = parsed.value;
    if (root != .object) return ProxyError.BadRequest;
    var tags = root.object.get("tags") orelse std.json.Value{ .array = std.array_list.Managed(std.json.Value).init(alloc) };
    if (tags != .array) return ProxyError.BadRequest;
    var has_user = false;
    var has_product = false;
    for (tags.array.items) |tag| {
        if (tag == .string) {
            has_user = has_user or std.mem.startsWith(u8, tag.string, "user=");
            has_product = has_product or std.mem.startsWith(u8, tag.string, "product=");
        }
    }
    if (!has_user) try tags.array.append(.{ .string = "user=freepro" });
    if (!has_product) try tags.array.append(.{ .string = "product=freepro" });
    try root.object.put(alloc, "tags", tags);
    return stringifyValueAlloc(alloc, root);
}

// Cline's buffered endpoint wraps its OpenAI completion in a data object.
fn chatReply(alloc: Allocator, body: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return body;
    if (parsed.value != .object) return body;
    const data = parsed.value.object.get("data") orelse return body;
    if (data != .object) return body;
    const choices = data.object.get("choices") orelse return body;
    if (choices != .array) return body;
    return stringifyValueAlloc(alloc, data);
}

fn sendSyntheticChat(writer: *std.Io.Writer, alloc: Allocator, body: []const u8) !void {
    try sendSseHead(writer);
    try sendSseChunk(writer, try synthChunk(alloc, body, null));
    try sendSseChunk(writer, try synthChunk(alloc, body, "stop"));
    try sendSseChunk(writer, "data: [DONE]\n\n");
    try sendSseEnd(writer);
}

fn forwardAttempt(
    self: *Proxy,
    provider_idx: usize,
    key_idx: usize,
    endpoint: UpstreamEndpoint,
    body: []const u8,
    sse_wanted: bool,
    writer: *std.Io.Writer,
    alloc: Allocator,
    acc: ?*UsageAccum,
) !AttemptOutcome {
    const prov = &self.config.providers[provider_idx];
    const key_material = prov.keys[key_idx].key;

    // Responses-wire providers: translate the chat body and target /responses.
    var wire_body: []const u8 = try providerBody(alloc, prov, body);
    var wire_path: []const u8 = endpoint.path();
    const model_name = routed_model_of(self.config, alloc, provider_idx, body) orelse "";
    const responses_mode = usesResponses(prov, model_name) and endpoint == .chat_completions;
    if (responses_mode) {
        const chat_parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
            return ProxyError.BadRequest;
        defer chat_parsed.deinit();
        const chat_model = switch (chat_parsed.value) {
            .object => |o| switch (o.get("model") orelse return ProxyError.BadRequest) {
                .string => |sm| sm,
                else => return ProxyError.BadRequest,
            },
            else => return ProxyError.BadRequest,
        };
        const upstream_model = cfg_strip(self.config, provider_idx, chat_model);
        wire_body = try responses_mod.buildResponsesBody(alloc, body, upstream_model);
        wire_path = "responses";
    }

    const url = try joinUpstreamUrl(alloc, prov.base_url, wire_path);
    const uri = std.Uri.parse(url) catch return ProxyError.BadRequest;

    const priv = try buildPrivHeaders(alloc, prov, key_material);
    const content_type = priv.content_type orelse "application/json";

    // Experimental free-proxy routing: when the provider opts in, ALL its
    // upstream traffic goes through the pool. If the pool is empty (still
    // warming), fail with a distinct error instead of leaking the caller's
    // real IP via a direct connection.
    var picked_proxy: ?freeproxy.Picked = null;
    if (self.free_proxies) |pool| {
        if (prov.use_free_proxy) {
            pool.maybeRefresh();
            picked_proxy = pool.pick(alloc);
            if (picked_proxy == null) return ProxyError.FreeProxyUnavailable;
        }
    }

    // Pool feedback: success/failure of THIS attempt, reported exactly once
    // via defer (transport errors included).
    const ProxiedOutcome = struct {
        pool: *freeproxy.Pool,
        picked: freeproxy.Picked,
        t0_ms: i64,
        ok: bool = false,
    };
    var proxied: ?ProxiedOutcome = if (picked_proxy) |picked| .{
        .pool = self.free_proxies.?,
        .picked = picked,
        .t0_ms = nowMs(),
    } else null;
    defer if (proxied) |pr| pr.pool.report(pr.picked, @intCast(@max(0, nowMs() - pr.t0_ms)), pr.ok);

    var client: HttpClient = .{ .allocator = alloc, .io = self.io };
    defer client.deinit();

    if (picked_proxy) |picked| {
        const proxy = try alloc.create(HttpClient.Proxy);
        proxy.* = .{
            .protocol = .plain,
            .host = try std.Io.net.HostName.init(try alloc.dupe(u8, picked.host)),
            .port = picked.port,
            .authorization = null,
            .supports_connect = true,
        };
        client.https_proxy = proxy;
        client.http_proxy = proxy;
    }

    // NOTE: extra_headers, not smuggled duplicates: auth/content-type ride as
    // header overrides while provider static headers ride as extras.
    // Redirects are unhandled so auth material never leaks to a redirect
    // target.
    const request_options: HttpClient.RequestOptions = .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{ .override = content_type },
            .authorization = .{ .override = priv.auth_value },
            .user_agent = if (priv.user_agent) |ua| .{ .override = ua } else .default,
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = priv.extras,
    };
    var req = if (picked_proxy != null)
        try freeproxy.timed(HttpClient.Request, self.io, 10000, HttpClient.request, .{ &client, .POST, uri, request_options })
    else
        try client.request(.POST, uri, request_options);
    defer req.deinit();

    // sendBodyComplete takes a mutable slice; the arena owns the copy.
    // Responses-wire providers send the translated body, not the original.
    const outbound = wire_body;
    const owned_body = try alloc.dupe(u8, outbound);
    try req.sendBodyComplete(owned_body);

    var redirect_buf: [512]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    const status: u16 = @intFromEnum(response.head.status);
    if (picked_proxy) |picked| {
        self.free_proxies.?.routeStatus(picked, status);
        if (self.logger) |l| l.info("public proxy {s}:{d}: upstream HTTP {d}", .{ picked.host, picked.port, status });
    }
    const ctype = response.head.content_type orelse "";
    const upstream_sse = headerValueHas(ctype, "text/event-stream");

    var transfer: [4096]u8 = undefined;
    const reader = response.reader(&transfer);

    if (models.isHealthyStatus(status)) {
        if (proxied) |*pr| pr.ok = true;
        if (responses_mode) {
            // Responses wire: the upstream always answers with one JSON
            // document (stream is never propagated); translate it and shape
            // it for the client as JSON or as synthesized chat SSE.
            const resp_body = try bufferUpstreamBody(reader, alloc, max_body_bytes);
            const upstream_model = routed_model_of(self.config, alloc, provider_idx, body) orelse "";
            const chat_body = responses_mod.chatFromResponses(alloc, resp_body, fullModelId(self.config, alloc, provider_idx, upstream_model)) catch resp_body;
            if (acc) |a| a.scan(chat_body);
            if (sse_wanted) {
                try sendSyntheticChat(writer, alloc, chat_body);
            } else {
                try sendJson(writer, status, chat_body);
            }
        } else if (upstream_sse) {
            try sendSseHead(writer);
            var chunk: [32768]u8 = undefined;
            while (true) {
                const n = try readChunk(reader, &chunk);
                if (n == 0) break;
                if (acc) |a| a.scanSse(chunk[0..n]);
                try sendSseChunk(writer, chunk[0..n]);
            }
            try sendSseEnd(writer);
        } else {
            const raw_body = try bufferUpstreamBody(reader, alloc, max_body_bytes);
            const resp_body = try chatReply(alloc, raw_body);
            if (acc) |a| a.scan(resp_body);
            if (sse_wanted) {
                try sendSyntheticChat(writer, alloc, resp_body);
            } else try sendJson(writer, status, resp_body);
        }
        return .{ .status = status, .body = &.{} };
    }

    const err_body = bufferUpstreamBody(reader, alloc, max_upstream_error_bytes) catch |err| {
        if (err == ProxyError.BodyTooLarge) return .{ .status = status, .body = &.{} };
        if (proxied) |*pr| pr.ok = false;
        return err;
    };
    if (proxied) |*pr| pr.ok = !headerValueHas(ctype, "text/html") and status != 407;
    return .{ .status = status, .body = err_body };
}

// -- POST /v1/chat/completions + /v1/completions -------------------------------

fn handleCompletions(
    self: *Proxy,
    writer: *std.Io.Writer,
    alloc: Allocator,
    req: InboundRequest,
    endpoint: UpstreamEndpoint,
    provider_out: *?usize,
) !u16 {
    const ms = extractModelAndStream(alloc, req.body) catch {
        try sendStatus(writer, 400, "request body must be JSON with a string \"model\"");
        return 400;
    };

    const routed = self.config.routeModel(ms.model) orelse {
        try sendStatus(writer, 400, "model prefix does not match any provider");
        return 400;
    };
    const p_idx = routed.provider_index;
    provider_out.* = p_idx;

    const prov = &self.config.providers[p_idx];
    if (prov.keys.len == 0) {
        try sendStatus(writer, 503, "provider has no API keys configured");
        return 503;
    }

    const upstream_body = rewriteModelField(alloc, req.body, routed.upstream_model) catch {
        try sendStatus(writer, 400, "request body must be a JSON object");
        return 400;
    };

    var acc: UsageAccum = .{ .alloc = alloc };
    defer acc.deinit();
    const ms_free_proxy = prov.use_free_proxy and self.free_proxies != null;
    const max_attempts = if (ms_free_proxy) 12 else @min(prov.keys.len + 1, max_key_attempts);
    var attempts: usize = 0;
    var prev_key: ?usize = null;
    var pending_failover: ?struct { from: usize, status: u16 } = null;
    var last_status: u16 = 503;
    var last_body: []const u8 = &.{};
    var tried_any = false;

    while (attempts < max_attempts) : (attempts += 1) {
        const key_idx = self.pickKey(p_idx) orelse break;
        if (!ms_free_proxy and prev_key != null and prev_key.? == key_idx and attempts > 0) break; // rotator stalled; avoid hammering
        prev_key = key_idx;
        tried_any = true;

        if (pending_failover) |pf| {
            if (self.logger) |l| {
                if (ms_free_proxy) l.info("public proxy route failed ({d}); trying another egress", .{pf.status}) else l.failover(pf.from + 1, pf.status, key_idx + 1);
            }
            pending_failover = null;
        }

        var outcome = forwardAttempt(self, p_idx, key_idx, endpoint, upstream_body, ms.stream, writer, alloc, &acc) catch |err| {
            if (err == ProxyError.FreeProxyUnavailable) {
                // Pool still warming / exhausted: not the key's fault. Fail
                // the request without touching key health.
                if (last_body.len != 0) {
                    try sendJson(writer, last_status, last_body);
                    return last_status;
                }
                try sendStatus(writer, 503, "no HTTPS-capable public proxy is currently available; the pool is refreshing (API keys unchanged)");
                return 503;
            }
            if (!ms_free_proxy) self.reportKey(p_idx, key_idx, null);
            if (self.metrics) |m| m.noteFailover();
            if (self.logger) |l| l.warn("key #{d} transport error: {s}", .{ key_idx + 1, @errorName(err) });
            pending_failover = .{ .from = key_idx, .status = 502 };
            last_status = 502;
            last_body = &.{};
            continue;
        };
        if (needsThinkingRepair(outcome.status, outcome.body)) {
            const repaired = try thinkingBody(alloc, upstream_body);
            if (self.logger) |l| l.info("model requires thinking; retrying once with low effort", .{});
            outcome = try forwardAttempt(self, p_idx, key_idx, endpoint, repaired, ms.stream, writer, alloc, &acc);
        }
        if (outcome.status >= 400 and outcome.status < 500 and
            !shouldFailoverStatus(outcome.status))
        {
            try sendJson(writer, outcome.status, outcome.body);
            return outcome.status;
        }
        // 500 from the upstream is the model's own bug (e.g. insufficient
        // reasoning budget), not a key problem. Don't touch key health.
        if (outcome.status == 500) {
            try sendJson(writer, outcome.status, outcome.body);
            return outcome.status;
        }

        if (!ms_free_proxy or models.isHealthyStatus(outcome.status)) self.reportKey(p_idx, key_idx, outcome.status);

        if (models.isHealthyStatus(outcome.status)) {
            if (self.metrics) |m| m.recordModelUsage(ms.model, acc.input, acc.output, acc.cached, usageToday());
            return outcome.status; // already relayed
        }

        // Non-healthy through a free proxy: the verdict may be the proxy's
        // (block pages, auth walls), not the provider's. Skip key-health
        // reporting so one bad hop cannot mark a working key Dead, and never
        // hand an HTML block page to the caller: failover instead.
        if (ms_free_proxy) {
            const looks_html = outcome.body.len > 0 and
                (std.mem.startsWith(u8, std.mem.trimStart(u8, outcome.body, "\x09\x0d\x0a"), "<") or
                    std.mem.indexOf(u8, outcome.body[0..@min(outcome.body.len, 256)], "<html") != null or
                    std.mem.indexOf(u8, outcome.body[0..@min(outcome.body.len, 256)], "<!DOCTYPE") != null);
            if (shouldFailoverStatus(outcome.status) or looks_html) {
                if (self.metrics) |m| m.noteFailover();
                pending_failover = .{ .from = key_idx, .status = outcome.status };
                last_status = outcome.status;
                last_body = if (looks_html) &.{} else outcome.body;
                continue;
            }
            try sendJson(writer, outcome.status, outcome.body);
            return outcome.status;
        }

        last_status = outcome.status;
        last_body = outcome.body;
        if (!shouldFailoverStatus(outcome.status)) {
            // Deterministic client error: forward the upstream verdict as-is.
            try sendJson(writer, outcome.status, outcome.body);
            return outcome.status;
        }
        if (self.metrics) |m| m.noteFailover();
        pending_failover = .{ .from = key_idx, .status = outcome.status };
    }

    if (!tried_any) {
        try sendStatus(writer, 503, "all API keys for this provider are exhausted or cooling down");
        return 503;
    }
    if (last_body.len != 0) {
        // Every key failed: hand the caller the last upstream verdict.
        try sendJson(writer, last_status, last_body);
        return last_status;
    }
    try sendStatus(writer, last_status, if (ms_free_proxy) "public proxy attempts failed; API keys were not put into cooldown" else "all API keys for this provider failed");
    return last_status;
}

// -- GET /v1/models -------------------------------------------------------------

fn appendCatalogEntries(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    body: []const u8,
    prefix: []const u8,
    owned_by: []const u8,
    created: i64,
    first: *bool,
) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return;
    const items: []const std.json.Value = switch (parsed.value) {
        .object => |o| switch (o.get("data") orelse return) {
            .array => |a| a.items,
            else => return,
        },
        .array => |a| a.items,
        else => return,
    };
    for (items) |item| {
        const id = switch (item) {
            .object => |o| switch (o.get("id") orelse continue) {
                .string => |s| s,
                else => continue,
            },
            else => continue,
        };
        if (!first.*) try out.appendSlice(alloc, ",");
        first.* = false;
        const full_id = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, id });
        const quoted_id = try stringifyValueAlloc(alloc, .{ .string = full_id });
        const quoted_owner = try stringifyValueAlloc(alloc, .{ .string = owned_by });
        const created_s = try std.fmt.allocPrint(alloc, "{d}", .{created});
        try out.appendSlice(alloc, "{\"id\":");
        try out.appendSlice(alloc, quoted_id);
        try out.appendSlice(alloc, ",\"object\":\"model\",\"created\":");
        try out.appendSlice(alloc, created_s);
        try out.appendSlice(alloc, ",\"owned_by\":");
        try out.appendSlice(alloc, quoted_owner);
        try out.appendSlice(alloc, "}");
    }
}

fn fetchProviderModels(
    self: *Proxy,
    alloc: Allocator,
    provider_idx: usize,
    key_idx: usize,
) ![]u8 {
    const prov = &self.config.providers[provider_idx];
    const url = try joinUpstreamUrl(alloc, prov.base_url, "models");
    const uri = std.Uri.parse(url) catch return ProxyError.BadRequest;

    const priv = try buildPrivHeaders(alloc, prov, prov.keys[key_idx].key);

    var client: HttpClient = .{ .allocator = alloc, .io = self.io };
    defer client.deinit();

    var req = try client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = .{ .override = priv.auth_value },
            .user_agent = if (priv.user_agent) |ua| .{ .override = ua } else .default,
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = priv.extras,
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [512]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    const status: u16 = @intFromEnum(response.head.status);
    if (!models.isHealthyStatus(status)) return ProxyError.BadRequest;
    var transfer: [4096]u8 = undefined;
    return try bufferUpstreamBody(response.reader(&transfer), alloc, max_models_bytes);
}

/// Public raw-body fetch of a provider's /models document. Used by the
/// dashboard refresh flow (which runs while the proxy is stopped). With
/// `key_idx == null` the request is sent without an Authorization header,
/// so public catalog endpoints (cline, nous, opencode) populate before any
/// key is configured.
pub fn fetchModelsBody(self: *Proxy, alloc: Allocator, provider_idx: usize, key_idx: ?usize) ![]u8 {
    const prov = &self.config.providers[provider_idx];
    const url = try joinUpstreamUrl(alloc, prov.base_url, "models");
    const uri = std.Uri.parse(url) catch return ProxyError.BadRequest;

    const key_material = if (key_idx) |ki| prov.keys[ki].key else "";
    const priv = try buildPrivHeaders(alloc, prov, key_material);

    var client: HttpClient = .{ .allocator = alloc, .io = self.io };
    defer client.deinit();

    var req = try client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = if (key_material.len != 0 or priv.auth_value.len != 0)
                .{ .override = priv.auth_value }
            else
                .default,
            .user_agent = if (priv.user_agent) |ua| .{ .override = ua } else .default,
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = priv.extras,
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [512]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);

    const status: u16 = @intFromEnum(response.head.status);
    if (!models.isHealthyStatus(status)) return ProxyError.BadRequest;
    var transfer: [4096]u8 = undefined;
    return try bufferUpstreamBody(response.reader(&transfer), alloc, max_models_bytes);
}

/// Serve /v1/models from the cached catalog (enabled entries only).
/// `fallback_data` carries a live-fetched OpenAI list body (just the
/// data-array contents) when the cache is empty. The catalog is read
/// under the proxy mutex (catalog swaps happen under it); the socket
/// write happens after the lock is released.
pub fn handleModelsCached(
    self: *Proxy,
    writer: *std.Io.Writer,
    alloc: Allocator,
    fallback_data: ?[]const u8,
) !u16 {
    var out: std.ArrayList(u8) = .empty;
    self.catalog_mu.lock();
    defer self.catalog_mu.unlock();
    try out.appendSlice(alloc, "{\"object\":\"list\",\"data\":[");
    const created = nowUnixSec();
    // hide_paid / free_mode gate exposure at serve time too: a refresh that
    // introduces new paid models must not leak them past this filter.
    const hide_paid = self.config.hide_paid;
    const free_mode = self.config.free_mode;

    var wrote_any = false;
    for (self.config.providers) |*prov| {
        for (prov.models) |*m| {
            if (!m.enabled) continue;
            if ((hide_paid or free_mode) and !m.isFree()) continue;
            if (wrote_any) try out.appendSlice(alloc, ",");
            wrote_any = true;
            const quoted_id = try stringifyValueAlloc(alloc, .{ .string = m.id });
            const quoted_owner = try stringifyValueAlloc(alloc, .{ .string = prov.display_name });
            try out.appendSlice(alloc, "{\"id\":");
            try out.appendSlice(alloc, quoted_id);
            try out.appendSlice(alloc, ",\"object\":\"model\",\"created\":");
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}", .{created}));
            try out.appendSlice(alloc, ",\"owned_by\":");
            try out.appendSlice(alloc, quoted_owner);
            if (m.context_window != 0) {
                try out.appendSlice(alloc, ",\"context_window\":");
                try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}", .{m.context_window}));
            }
            // Reasoning models expose the OpenAI-like reasoning flag so
            // client tools can show capability metadata.
            if (m.supports_reasoning) {
                try out.appendSlice(alloc, ",\"reasoning\":true");
            }
            {
                const advertised_levels = if (m.reasoning_levels.len == 0 or models.isLegacyReasoningLevels(m.reasoning_levels)) default_reasoning_levels else m.reasoning_levels;
                try out.appendSlice(alloc, ",\"reasoning_levels\":[");
                var lit = std.mem.splitScalar(u8, advertised_levels, ',');
                var lfirst = true;
                while (lit.next()) |lvl| {
                    if (lvl.len == 0) continue;
                    if (!lfirst) try out.appendSlice(alloc, ",");
                    lfirst = false;
                    try out.appendSlice(alloc, try stringifyValueAlloc(alloc, .{ .string = lvl }));
                }
                try out.appendSlice(alloc, "]");
            }
            try out.appendSlice(alloc, "}");
        }
    }
    // Cache empty (fresh install, no fetch yet): serve the live list.
    if (!wrote_any) {
        if (fallback_data) |data| try out.appendSlice(alloc, data);
    }
    try out.appendSlice(alloc, "]}");

    try sendJson(writer, 200, out.items);
    return 200;
}

/// Default reasoning effort levels offered when the upstream catalog does
/// not document them (see models.default_reasoning_levels).
pub const default_reasoning_levels = models.default_reasoning_levels;

/// Read upstream-documented reasoning levels from one models-document item.
/// Accepts arrays of strings under a few common key spellings; returns an
/// arena-owned comma-joined list, or null when the item says nothing.
fn reasoningLevelsFromDoc(o: std.json.ObjectMap, alloc: Allocator) ?[]const u8 {
    for ([_][]const u8{ "reasoning_levels", "reasoning_efforts", "reasoning_effort_levels" }) |k| {
        const v = o.get(k) orelse continue;
        switch (v) {
            .array => |arr| {
                var buf: std.ArrayList(u8) = .empty;
                var first = true;
                for (arr.items) |it| {
                    if (it != .string) continue;
                    if (!first) buf.appendSlice(alloc, ",") catch return null;
                    first = false;
                    buf.appendSlice(alloc, it.string) catch return null;
                }
                if (buf.items.len != 0) return buf.items;
            },
            .string => |s| {
                if (s.len != 0) return s;
            },
            else => {},
        }
    }
    return null;
}

/// Replace a provider's cached catalog with freshly fetched entries.
/// Preserves the enabled flag of surviving entries. Caller excludes
/// concurrent config mutation (dashboard applier or fetch window).
/// Kept free of upstream.zig imports (module layering), so it parses the
/// models document directly.
pub fn updateProviderCatalog(self: *Proxy, provider_idx: usize, body: []const u8, alloc: Allocator) !usize {
    const prov = &self.config.providers[provider_idx];
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return 0;
    defer parsed.deinit();
    const data = switch (parsed.value) {
        .object => |o| o.get("data") orelse return 0,
        else => return 0,
    };
    const entries = switch (data) {
        .array => |a| a.items,
        else => return 0,
    };

    // Single pass: count first, then build the replacement slice.
    const gpa = self.allocator;
    var count: usize = 0;
    for (entries) |item| {
        if (item != .object) continue;
        const o = item.object;
        const idv = o.get("id") orelse continue;
        if (idv != .string) continue;
        count += 1;
    }

    // Workers may concurrently populate the catalog on a fresh install;
    // serialize the read-modify-swap on the catalog mutex (never `mu`: the
    // accept loop holds `mu` across a blocking accept). The network fetch
    // already happened, so this critical section is CPU-only.
    self.catalog_mu.lock();
    defer self.catalog_mu.unlock();

    const kept = try gpa.alloc(models.ModelInfo, count);
    var n: usize = 0;
    errdefer {
        for (kept[0..n]) |*m| m.deinit(gpa);
        gpa.free(kept);
    }
    for (entries) |item| {
        if (item != .object) continue;
        const o = item.object;
        const idv = o.get("id") orelse continue;
        if (idv != .string) continue;
        const upstream_id = idv.string;
        const full_id = try std.fmt.allocPrint(gpa, "{s}{s}", .{ prov.prefix, upstream_id });
        errdefer gpa.free(full_id);
        const upstream_copy = try gpa.dupe(u8, upstream_id);
        errdefer gpa.free(upstream_copy);
        const provider_copy = try gpa.dupe(u8, prov.display_name);
        errdefer gpa.free(provider_copy);
        const prefix_copy = try gpa.dupe(u8, prov.prefix);
        errdefer gpa.free(prefix_copy);

        var ctx: u64 = 0;
        for ([_][]const u8{ "context_length", "context_window", "max_context_tokens", "context_size" }) |k| {
            if (o.get(k)) |cv| switch (cv) {
                .integer => |iv| {
                    if (iv > 0) {
                        ctx = @intCast(iv);
                        break;
                    }
                },
                else => {},
            };
        }
        // Reasoning support: OpenAI-like catalogs advertise it via
        // supported_parameters ("reasoning" / "reasoning_effort").
        var reasoning = false;
        if (o.get("supported_parameters")) |sp| switch (sp) {
            .array => |arr| for (arr.items) |p2| {
                if (p2 == .string and (std.mem.eql(u8, p2.string, "reasoning") or
                    std.mem.eql(u8, p2.string, "reasoning_effort")))
                {
                    reasoning = true;
                    break;
                }
            },
            else => {},
        };
        var enabled = true;
        var old_levels: ?[]const u8 = null;
        var was_free: ?bool = null;
        for (prov.models) |*old| {
            if (std.mem.eql(u8, old.upstream_id, upstream_id)) {
                enabled = old.enabled;
                // Preserve user-edited levels across refreshes.
                if (old.reasoning_levels.len != 0) old_levels = old.reasoning_levels;
                was_free = old.free;
                break;
            }
        }
        // Operator defaults apply to new models; retain later per-model edits.
        var levels = try gpa.dupe(u8, default_reasoning_levels);
        errdefer gpa.free(levels);
        if (old_levels) |ol| {
            gpa.free(levels);
            levels = try gpa.dupe(u8, if (models.isLegacyReasoningLevels(ol)) default_reasoning_levels else ol);
        }
        // Free tier: upstream flag (e.g. Kilo's isFree), the -free/:free
        // suffix, or a previously stored flag (b.ai seeds).
        var free_model = std.mem.endsWith(u8, upstream_id, "-free") or
            std.mem.endsWith(u8, upstream_id, ":free");
        if (o.get("isFree")) |fv| {
            if (fv == .bool) free_model = free_model or fv.bool;
        }
        if (was_free) |wf| free_model = free_model or wf;
        kept[n] = .{
            .id = full_id,
            .upstream_id = upstream_copy,
            .provider_name = provider_copy,
            .provider_prefix = prefix_copy,
            .context_window = ctx,
            .enabled = enabled,
            .supports_reasoning = reasoning,
            .reasoning_levels = levels,
            .free = free_model,
        };
        n += 1;
    }

    for (prov.models) |*old| old.deinit(gpa);
    if (prov.models.len != 0) gpa.free(prov.models);
    prov.models = kept;
    return n;
}

fn handleModels(self: *Proxy, writer: *std.Io.Writer, alloc: Allocator) !u16 {
    // Cache-first: serve the persisted catalog when any provider has one.
    for (self.config.providers) |*p| {
        if (p.models.len != 0) return handleModelsCached(self, writer, alloc, null);
    }

    // No cache yet (fresh install): live-fetch once, populate the cache,
    // and fall back to the live list for this response.
    var first = true;
    var live: std.ArrayList(u8) = .empty;
    for (self.config.providers, 0..) |*prov, p_idx| {
        const key_idx = self.pickKey(p_idx) orelse {
            if (self.logger) |l| l.warn("models: provider \"{s}\" has no healthy key, skipped", .{prov.display_name});
            continue;
        };
        const body = fetchProviderModels(self, alloc, p_idx, key_idx) catch |err| {
            self.reportKey(p_idx, key_idx, null);
            if (self.logger) |l| l.warn("models: provider \"{s}\" fetch failed: {s}", .{ prov.display_name, @errorName(err) });
            continue;
        };
        self.reportKey(p_idx, key_idx, 200);
        _ = updateProviderCatalog(self, p_idx, body, alloc) catch |err| {
            if (self.logger) |l| l.warn("models: cache update failed for \"{s}\": {s}", .{ prov.display_name, @errorName(err) });
        };
        appendCatalogEntries(&live, alloc, body, prov.prefix, prov.display_name, nowUnixSec(), &first) catch |err| {
            if (self.logger) |l| l.warn("models: provider \"{s}\" catalog parse failed: {s}", .{ prov.display_name, @errorName(err) });
        };
    }

    return handleModelsCached(self, writer, alloc, live.items);
}

// ---------------------------------------------------------------------------
// Unit + integration tests (run: zig test src/proxy.zig)
// ---------------------------------------------------------------------------

test "synthChunk emits content from a translated responses reply" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const resp =
        "{" ++ "\"id\":\"resp_echo\",\"created_at\":123,\"status\":\"completed\"," ++
        "\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ECHO-OK\"}]}]," ++
        "\"usage\":{\"input_tokens\":11,\"output_tokens\":4," ++
        "\"input_tokens_details\":{\"cached_tokens\":1}}}";
    const chat = try responses_mod.chatFromResponses(alloc, resp, "oc/m");
    // The translated reply must be complete, valid JSON.
    const reparsed = try std.json.parseFromSlice(std.json.Value, alloc, chat, .{});
    reparsed.deinit();
    const delta = try synthChunk(alloc, chat, null);
    try std.testing.expect(std.mem.indexOf(u8, delta, "ECHO-OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta, "\"finish_reason\":null") != null);
    const stop = try synthChunk(alloc, chat, "stop");
    try std.testing.expect(std.mem.indexOf(u8, stop, "\"finish_reason\":\"stop\"") != null);
}

test "joinUpstreamUrl trims slashes on both sides" {
    const alloc = std.testing.allocator;
    const a = try joinUpstreamUrl(alloc, "https://opencode.ai/zen/v1/", "chat/completions");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1/chat/completions", a);

    const b = try joinUpstreamUrl(alloc, "https://api.kilo.ai/api/gateway", "/models");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("https://api.kilo.ai/api/gateway/models", b);
}

test "reasonPhrase covers the codes we emit" {
    try std.testing.expectEqualStrings("OK", reasonPhrase(200));
    try std.testing.expectEqualStrings("Bad Request", reasonPhrase(400));
    try std.testing.expectEqualStrings("Not Found", reasonPhrase(404));
    try std.testing.expectEqualStrings("Internal Server Error", reasonPhrase(500));
    try std.testing.expectEqualStrings("Bad Gateway", reasonPhrase(502));
    try std.testing.expectEqualStrings("Service Unavailable", reasonPhrase(503));
}

test "shouldFailoverStatus matches the rotation contract" {
    try std.testing.expect(!shouldFailoverStatus(200));
    try std.testing.expect(shouldFailoverStatus(0)); // transport failure
    try std.testing.expect(shouldFailoverStatus(429));
    try std.testing.expect(shouldFailoverStatus(408));
    try std.testing.expect(shouldFailoverStatus(500));
    try std.testing.expect(shouldFailoverStatus(503));
    try std.testing.expect(!shouldFailoverStatus(501));
    try std.testing.expect(shouldFailoverStatus(401));
    try std.testing.expect(shouldFailoverStatus(403));
    try std.testing.expect(!shouldFailoverStatus(400));
    try std.testing.expect(!shouldFailoverStatus(404));
    try std.testing.expect(!shouldFailoverStatus(422));
}

test "extract + rewrite model field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ms = try extractModelAndStream(alloc, "{\"model\":\"oc/deepseek-r1\",\"stream\":true}");
    try std.testing.expectEqualStrings("oc/deepseek-r1", ms.model);
    try std.testing.expect(ms.stream);

    const ms2 = try extractModelAndStream(alloc, "{\"model\":\"kilo/llama\"}");
    try std.testing.expect(!ms2.stream);

    try std.testing.expectError(ProxyError.BadRequest, extractModelAndStream(alloc, "{\"model\":42}"));
    try std.testing.expectError(ProxyError.BadRequest, extractModelAndStream(alloc, "not json"));

    const rewritten = try rewriteModelField(alloc, "{\"model\":\"oc/deepseek-r1\",\"messages\":[]}", "deepseek-r1");
    const check = try std.json.parseFromSlice(std.json.Value, alloc, rewritten, .{});
    defer check.deinit();
    try std.testing.expectEqualStrings("deepseek-r1", check.value.object.get("model").?.string);
}

test "parseRequest splits method/path/query/body" {
    const raw = "POST http://x/v1/chat/completions?foo=bar HTTP/1.1\r\n" ++
        "Content-Length: 7\r\n\r\n{\"a\":1}";
    const req = try parseRequest(raw);
    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("/v1/chat/completions", req.path);
    try std.testing.expectEqualStrings("{\"a\":1}", req.body);

    const get = "GET /v1/models HTTP/1.1\r\nHost: x\r\n\r\n";
    const req2 = try parseRequest(get);
    try std.testing.expectEqualStrings("GET", req2.method);
    try std.testing.expectEqualStrings("/v1/models", req2.path);
    try std.testing.expectEqual(@as(usize, 0), req2.body.len);

    try std.testing.expectError(ProxyError.BadRequest, parseRequest("GARBAGE"));
    try std.testing.expectEqual(@as(usize, 0), parseContentLength("Host: x\r\n\r\n"));
}

test "chunked framing format is exact" {
    var backing: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&backing);
    try sendSseChunk(&w, "data: hi\n\n");
    try std.testing.expectEqualStrings("a\r\ndata: hi\n\n\r\n", w.buffered());
    const before = w.buffered().len;
    try sendSseChunk(&w, "");
    try std.testing.expectEqual(before, w.buffered().len); // empty chunks skipped
}

test "standalone picker rotates and honors cooldown/dead" {
    var keys = [_]models.Key{
        .{ .key = "k1" },
        .{ .key = "k2" },
        .{ .key = "k3" },
    };
    var headers = [_]models.CustomHeader{};
    var providers = [_]models.Provider{.{
        .display_name = "Test",
        .base_url = "http://127.0.0.1:9/",
        .prefix = "t/",
        .description = "test",
        .keys = &keys,
        .headers = &headers,
    }};
    var cfg = models.ProxyConfig{
        .port = testPort(18080),
        .providers = &providers,
        .cooldown_secs = 60,
    };
    var proxy = Proxy.init(std.testing.allocator, &cfg, .{});
    var cursors = [_]usize{0};
    proxy.standalone_cursors = &cursors;

    try std.testing.expectEqual(@as(?usize, 0), proxy.pickKey(0));
    try std.testing.expectEqual(@as(?usize, 1), proxy.pickKey(0));
    proxy.reportKey(0, 1, 429); // k2 cools down
    try std.testing.expectEqual(models.KeyState.CoolingDown, keys[1].state);
    try std.testing.expectEqual(@as(?usize, 2), proxy.pickKey(0));
    try std.testing.expectEqual(@as(?usize, 0), proxy.pickKey(0)); // wraps, skips k2
    proxy.reportKey(0, 0, 401); // k1 dead
    proxy.reportKey(0, 2, 200); // k3 healthy again
    try std.testing.expectEqual(models.KeyState.Dead, keys[0].state);
    try std.testing.expectEqual(@as(?usize, 2), proxy.pickKey(0));
    proxy.reportKey(0, 2, 429); // only k3 usable and now cooling
    try std.testing.expectEqual(@as(?usize, null), proxy.pickKey(0));
    proxy.reportKey(0, 0, null); // transport failure cools down (no crash on dead key)
    proxy.standalone_cursors = &[_]usize{};
}

// -- hook facade taps ----------------------------------------------------------

const TapLogger = struct {
    infos: usize = 0,
    warns: usize = 0,
    errs: usize = 0,
    failovers: usize = 0,
    requests: usize = 0,
    last_from: usize = 0,
    last_status: u16 = 0,
    last_to: usize = 0,

    pub fn info(self: *TapLogger, comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
        self.infos += 1;
    }

    pub fn warn(self: *TapLogger, comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
        self.warns += 1;
    }

    pub fn err(self: *TapLogger, comptime fmt: []const u8, args: anytype) void {
        _ = fmt;
        _ = args;
        self.errs += 1;
    }

    pub fn failover(self: *TapLogger, from_key_1based: usize, status: u16, to_key_1based: usize) void {
        self.failovers += 1;
        self.last_from = from_key_1based;
        self.last_status = status;
        self.last_to = to_key_1based;
    }

    pub fn logRequest(self: *TapLogger, method: []const u8, path: []const u8, status: u16, latency_ms: u64) void {
        _ = method;
        _ = path;
        _ = status;
        _ = latency_ms;
        self.requests += 1;
    }
};

const TapMetrics = struct {
    begins: usize = 0,
    ends: usize = 0,
    failovers: usize = 0,
    last_provider: ?usize = null,
    last_latency: u64 = 0,
    last_status: u16 = 0,

    pub fn begin(self: *TapMetrics) void {
        self.begins += 1;
    }

    pub fn end(self: *TapMetrics, provider_idx: ?usize, latency_ms: u64, status: u16) void {
        self.ends += 1;
        self.last_provider = provider_idx;
        self.last_latency = latency_ms;
        self.last_status = status;
    }

    pub fn noteFailover(self: *TapMetrics) void {
        self.failovers += 1;
    }
};

test "hook facades route to any structurally matching logger/metrics" {
    var tap = TapLogger{};
    const logger = Logger.wrap(&tap);
    logger.info("hello {s}", .{"world"});
    logger.warn("w{d}", .{1});
    logger.err("e", .{});
    logger.failover(2, 429, 3);
    logger.logRequest("POST", "/v1/chat/completions", 200, 42);
    try std.testing.expectEqual(@as(usize, 1), tap.infos);
    try std.testing.expectEqual(@as(usize, 1), tap.warns);
    try std.testing.expectEqual(@as(usize, 1), tap.errs);
    try std.testing.expectEqual(@as(usize, 1), tap.failovers);
    try std.testing.expectEqual(@as(usize, 2), tap.last_from);
    try std.testing.expectEqual(@as(u16, 429), tap.last_status);
    try std.testing.expectEqual(@as(usize, 3), tap.last_to);
    try std.testing.expectEqual(@as(usize, 1), tap.requests);

    var tm = TapMetrics{};
    const metrics = Metrics.wrap(&tm);
    metrics.begin();
    metrics.end(0, 42, 200);
    metrics.end(null, 7, 404);
    metrics.noteFailover();
    try std.testing.expectEqual(@as(usize, 1), tm.begins);
    try std.testing.expectEqual(@as(usize, 2), tm.ends);
    try std.testing.expectEqual(@as(?usize, null), tm.last_provider);
    try std.testing.expectEqual(@as(u64, 7), tm.last_latency);
    try std.testing.expectEqual(@as(u16, 404), tm.last_status);
    try std.testing.expectEqual(@as(usize, 1), tm.failovers);
}

// -- loopback test helpers -----------------------------------------------------

fn spinYield() void {
    std.Thread.yield() catch {};
}

fn readAllFromStream(stream: Net.Stream, io: std.Io, alloc: Allocator) ![]u8 {
    var rbuf: [8192]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    var out: std.ArrayList(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (true) {
        // The proxy answers with `Connection: close` and closes the socket
        // right after flushing the response. On Windows that close routinely
        // surfaces as error.ReadFailed (RST) instead of a clean zero-byte
        // read, so treat a short-read failure as EOF (ShortError carries no
        // other case). Tests assert on the bytes received, so a genuinely
        // truncated response still fails below.
        const n = sr.interface.readSliceShort(&chunk) catch break;
        if (n == 0) break;
        try out.appendSlice(alloc, chunk[0..n]);
    }
    if (out.items.len == 0) return try alloc.dupe(u8, "");
    return try out.toOwnedSlice(alloc);
}

fn loopbackStream(io: std.Io, port: u16) !Net.Stream {
    // Retry briefly: the listener binds synchronously in start(), but a
    // previous test's socket may still be draining.
    var spins: u32 = 0;
    while (true) {
        const addr = try Net.IpAddress.parseIp4(loopback_ip, port);
        if (addr.connect(io, .{ .mode = .stream })) |st| {
            return st;
        } else |err| {
            if (spins >= 20_000) return err;
            spins += 1;
            spinYield();
        }
    }
}

/// Test ports: `zig build test` runs several test binaries concurrently and
/// they all bind loopback ports, so spread the fixed bases apart per process
/// using the pid (Windows ephemeral range starts at 49152, so 18080..20091
/// never collides with it).
fn testPort(base: u16) u16 {
    const pid: u64 = switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.posix.getpid()),
    };
    return base + @as(u16, @intCast(pid % 2000));
}

fn testClientRequest(alloc: Allocator, port: u16, request: []const u8) ![]u8 {
    // Socket IO must run on pool threads (see sharedPool): the test runner
    // thread is a raw thread, so hop onto the pool and await the result.
    const io = sharedIo();
    var fut = std.Io.async(io, doTestRequest, .{ alloc, port, request });
    return try fut.await(io);
}

/// Pool-thread body of testClientRequest.
fn doTestRequest(alloc: Allocator, port: u16, request: []const u8) ![]u8 {
    const io = sharedIo();
    const stream = try loopbackStream(io, port);
    defer stream.close(io);
    var wbuf: [8192]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    try sw.interface.writeAll(request);
    try sw.interface.flush();
    return try readAllFromStream(stream, io, alloc);
}

/// Best-effort loopback poke so a thread blocked in accept() wakes up.
/// Runs on the pool for the same APC reason as every other socket call.
fn pokePort(port: u16) void {
    const io = sharedIo();
    const addr = Net.IpAddress.parseIp4(loopback_ip, port) catch return;
    const st = addr.connect(io, .{ .mode = .stream }) catch return;
    st.close(io);
}

fn pokePortOnPool(port: u16) void {
    const io = sharedIo();
    var fut = std.Io.async(io, pokePort, .{port});
    fut.await(io);
}

fn responseStatus(response: []const u8) !u16 {
    const eol = std.mem.indexOf(u8, response, "\r\n") orelse return error.BadResponse;
    var parts = std.mem.splitScalar(u8, response[0..eol], ' ');
    _ = parts.next() orelse return error.BadResponse;
    const code = parts.next() orelse return error.BadResponse;
    return try std.fmt.parseInt(u16, code, 10);
}

fn responseBody(response: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return &.{};
    return response[idx + 4 ..];
}

test "loopback: health, empty models, unknown prefix" {
    const alloc = std.testing.allocator;
    const port = testPort(18081);
    var cfg = models.ProxyConfig{ .port = port };
    var proxy = Proxy.init(alloc, &cfg, .{});
    try proxy.start();
    defer proxy.stop();
    try std.testing.expect(proxy.isRunning());

    const health = try testClientRequest(alloc, port, "GET /health HTTP/1.1\r\nHost: x\r\n\r\n");
    defer alloc.free(health);
    try std.testing.expectEqual(@as(u16, 200), try responseStatus(health));
    try std.testing.expect(std.mem.indexOf(u8, responseBody(health), "\"status\":\"ok\"") != null);

    const models_resp = try testClientRequest(alloc, port, "GET /v1/models HTTP/1.1\r\nHost: x\r\n\r\n");
    defer alloc.free(models_resp);
    try std.testing.expectEqual(@as(u16, 200), try responseStatus(models_resp));
    try std.testing.expectEqualStrings("{\"object\":\"list\",\"data\":[]}", responseBody(models_resp));

    const body = "{\"model\":\"nope/model\",\"messages\":[]}";
    const chat = try std.fmt.allocPrint(alloc, "POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    defer alloc.free(chat);
    const chat_resp = try testClientRequest(alloc, port, chat);
    defer alloc.free(chat_resp);
    try std.testing.expectEqual(@as(u16, 400), try responseStatus(chat_resp));

    const missing = try testClientRequest(alloc, port, "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n");
    defer alloc.free(missing);
    try std.testing.expectEqual(@as(u16, 404), try responseStatus(missing));

    try std.testing.expect(proxy.totalServedCount() >= 4);
    try std.testing.expectEqual(@as(usize, 0), proxy.inFlightCount());
}

// Fake upstream: first POST -> 429, later POSTs -> 200 JSON echo of the model.
const FakeUpstream = struct {
    port: u16,
    always_ok: bool = false,
    requests: std.atomic.Value(usize),
    stopping: std.atomic.Value(bool),
    saw_auth: [2][64]u8,
    saw_auth_len: [2]usize,
    saw_model: [64]u8,
    saw_model_len: usize,
    mu: Mutex,

    fn run(self: *FakeUpstream) void {
        const io = sharedIo();
        const addr = Net.IpAddress.parseIp4(loopback_ip, self.port) catch return;
        var server = addr.listen(io, .{ .reuse_address = true }) catch return;
        defer server.deinit(io);
        while (self.requests.load(.seq_cst) < 64 and !self.stopping.load(.seq_cst)) {
            const conn = server.accept(io) catch return;
            self.serve(conn, io) catch {};
        }
    }

    fn serve(self: *FakeUpstream, stream: Net.Stream, io: std.Io) !void {
        defer stream.close(io);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var rbuf: [8192]u8 = undefined;
        var sr = stream.reader(io, &rbuf);
        const raw = try readFramedMessage(&sr.interface, arena.allocator());
        const req = try parseRequest(raw);

        self.mu.lock();
        defer self.mu.unlock();
        const n = self.requests.load(.seq_cst);
        // Record Authorization + model for assertions.
        const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n").? + 4;
        var lines = std.mem.splitSequence(u8, raw[0..head_end], "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "authorization")) {
                const v = std.mem.trim(u8, line[colon + 1 ..], " \t");
                const slot = @min(n, 1);
                const len = @min(v.len, 64);
                @memcpy(self.saw_auth[slot][0..len], v[0..len]);
                self.saw_auth_len[slot] = len;
            }
        }
        const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), req.body, .{});
        const m = parsed.value.object.get("model").?.string;
        const len = @min(m.len, 64);
        @memcpy(self.saw_model[0..len], m[0..len]);
        self.saw_model_len = len;

        _ = self.requests.fetchAdd(1, .seq_cst);

        var wbuf: [4096]u8 = undefined;
        var sw = stream.writer(io, &wbuf);
        const w = &sw.interface;
        if (n == 0 and !self.always_ok) {
            const eb = "{\"error\":{\"message\":\"slow down\",\"type\":\"rate_limit\"}}";
            try w.print("HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{eb.len});
            try w.writeAll(eb);
        } else {
            const ok = "{\"id\":\"chatcmpl-1\",\"object\":\"chat.completion\",\"choices\":[],\"usage\":{\"prompt_tokens\":120,\"completion_tokens\":45,\"prompt_tokens_details\":{\"cached_tokens\":7}}}";
            try w.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ok.len});
            try w.writeAll(ok);
        }
        try w.flush();
    }
};

test "static headers ride on upstream requests" {
    const alloc = std.testing.allocator;
    // Header-echo stub: records every request header it receives.
    const H = struct {
        var seen: [8][128]u8 = undefined;
        var seen_len: [8]usize = [_]usize{0} ** 8;
        var count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
        var stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

        fn run() void {
            const io = sharedIo();
            const addr = Net.IpAddress.parseIp4(loopback_ip, testPort(18091)) catch return;
            var server = addr.listen(io, .{}) catch return;
            defer server.deinit(io);
            while (!stopping.load(.seq_cst)) {
                const conn = server.accept(io) catch return;
                serve(conn, io) catch {};
            }
        }

        fn serve(stream: Net.Stream, io: std.Io) !void {
            defer stream.close(io);
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            var rbuf: [8192]u8 = undefined;
            var sr = stream.reader(io, &rbuf);
            const raw = try readFramedMessage(&sr.interface, arena.allocator());
            const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n").? + 4;
            var wbuf: [2048]u8 = undefined;
            var sw = stream.writer(io, &wbuf);
            const w = &sw.interface;
            var lines = std.mem.splitSequence(u8, raw[0..head_end], "\r\n");
            var idx: usize = 0;
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "POST ") or std.mem.startsWith(u8, line, "GET ")) continue;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const name = std.mem.trim(u8, line[0..colon], " ");
                if (std.ascii.eqlIgnoreCase(name, "content-length")) continue;
                if (idx >= seen.len) break;
                const n = @min(line.len, 128);
                @memcpy(seen[idx][0..n], line[0..n]);
                seen_len[idx] = n;
                idx += 1;
            }
            _ = count.fetchAdd(1, .seq_cst);
            const ok = "{\"id\":\"x\",\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":1}}";
            try w.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ ok.len, ok });
            try w.flush();
        }

        fn find(name: []const u8) ?[]const u8 {
            var i: usize = 0;
            while (i < seen_len.len) : (i += 1) {
                if (seen_len[i] == 0) continue;
                const h = seen[i][0..seen_len[i]];
                const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, h[0..colon], " "), name)) {
                    return std.mem.trim(u8, h[colon + 1 ..], " ");
                }
            }
            return null;
        }
    };
    var stub_future = std.Io.async(sharedIo(), H.run, .{});
    defer {
        H.stopping.store(true, .seq_cst);
        pokePortOnPool(testPort(18091));
        stub_future.await(sharedIo());
    }

    var keys = [_]models.Key{.{ .key = "TESTKEY" }};
    var hdrs = [_]models.CustomHeader{
        .{ .key = "User-Agent", .value = "opencode/1.18.26" },
        .{ .key = "x-opencode-project", .value = "global" },
        .{ .key = "x-opencode-client", .value = "cli" },
    };
    var providers = [_]models.Provider{.{
        .display_name = "Echo",
        .base_url = "http://127.0.0.1:9/v1/",
        .prefix = "ec/",
        .description = "echo",
        .keys = &keys,
        .headers = &hdrs,
    }};
    providers[0].base_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/v1/", .{testPort(18091)});
    defer alloc.free(providers[0].base_url);
    const proxy_port = testPort(18092);
    var cfg = models.ProxyConfig{ .port = proxy_port, .providers = &providers };
    var proxy = Proxy.init(alloc, &cfg, .{});
    try proxy.start();
    defer proxy.stop();

    const body = "{\"model\":\"ec/m\",\"messages\":[],\"stream\":false}";
    const chat = try std.fmt.allocPrint(alloc, "POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
    defer alloc.free(chat);
    const resp = try testClientRequest(alloc, proxy_port, chat);
    defer alloc.free(resp);
    try std.testing.expectEqual(@as(u16, 200), try responseStatus(resp));

    try std.testing.expectEqualStrings("opencode/1.18.26", H.find("User-Agent").?);
    try std.testing.expectEqualStrings("global", H.find("x-opencode-project").?);
    try std.testing.expectEqualStrings("cli", H.find("x-opencode-client").?);
    try std.testing.expectEqualStrings("Bearer TESTKEY", H.find("authorization").?);
}

test "failover: 429 rotates bearer key and strips prefix" {
    const alloc = std.testing.allocator;

    var fake = FakeUpstream{
        .port = testPort(18082),
        .requests = std.atomic.Value(usize).init(0),
        .stopping = std.atomic.Value(bool).init(false),
        .saw_auth = undefined,
        .saw_auth_len = [_]usize{ 0, 0 },
        .saw_model = undefined,
        .saw_model_len = 0,
        .mu = .{},
    };
    // The stub blocks in socket IO, so it runs as a pool task (same APC
    // rule as the proxy workers). It exits after 2 requests; the defer
    // below guarantees teardown even on assertion failure.
    var fake_future = std.Io.async(sharedIo(), FakeUpstream.run, .{&fake});
    defer {
        fake.stopping.store(true, .seq_cst);
        pokePortOnPool(fake.port); // wake a blocking accept() so run() can exit
        fake_future.await(sharedIo());
    }

    var keys = [_]models.Key{ .{ .key = "KEY-ONE" }, .{ .key = "KEY-TWO" } };
    var headers = [_]models.CustomHeader{};
    const upstream_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/fake/v1/", .{fake.port});
    defer alloc.free(upstream_url);
    var providers = [_]models.Provider{.{
        .display_name = "Fake",
        .base_url = upstream_url,
        .prefix = "fk/",
        .description = "fake upstream",
        .keys = &keys,
        .headers = &headers,
    }};
    var cfg = models.ProxyConfig{ .port = testPort(18083), .providers = &providers, .cooldown_secs = 60 };
    const proxy_port = testPort(18083);
    var tap_log = TapLogger{};
    var tap_met = TapMetrics{};
    var proxy = Proxy.init(alloc, &cfg, .{
        .logger = Logger.wrap(&tap_log),
        .metrics = Metrics.wrap(&tap_met),
    });
    try proxy.start();
    defer proxy.stop();

    const body = "{\"model\":\"fk/magic-model\",\"messages\":[],\"stream\":false}";
    const chat = try std.fmt.allocPrint(alloc, "POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
    defer alloc.free(chat);
    const resp = try testClientRequest(alloc, proxy_port, chat);
    defer alloc.free(resp);

    try std.testing.expectEqual(@as(u16, 200), try responseStatus(resp));
    try std.testing.expect(std.mem.indexOf(u8, responseBody(resp), "chatcmpl-1") != null);

    // Upstream saw two attempts, prefix stripped, distinct bearer keys.
    var spins: u32 = 0;
    while (fake.requests.load(.seq_cst) < 2 and spins < 10_000_000) : (spins += 1) {
        spinYield();
    }
    try std.testing.expectEqual(@as(usize, 2), fake.requests.load(.seq_cst));
    try std.testing.expectEqualStrings("magic-model", fake.saw_model[0..fake.saw_model_len]);
    try std.testing.expectEqualStrings("Bearer KEY-ONE", fake.saw_auth[0][0..fake.saw_auth_len[0]]);
    try std.testing.expectEqualStrings("Bearer KEY-TWO", fake.saw_auth[1][0..fake.saw_auth_len[1]]);
    try std.testing.expectEqual(models.KeyState.CoolingDown, keys[0].state);
    try std.testing.expectEqual(models.KeyState.Active, keys[1].state);

    // Hook traffic flowed end to end: one rotation, one request line, one
    // metrics begin/end pair.
    try std.testing.expectEqual(@as(usize, 1), tap_log.failovers);
    try std.testing.expectEqual(@as(usize, 1), tap_log.last_from);
    try std.testing.expectEqual(@as(u16, 429), tap_log.last_status);
    try std.testing.expectEqual(@as(usize, 2), tap_log.last_to);
    try std.testing.expectEqual(@as(usize, 1), tap_log.requests);
    try std.testing.expectEqual(@as(usize, 1), tap_met.begins);
    try std.testing.expectEqual(@as(usize, 1), tap_met.ends);
    try std.testing.expectEqual(@as(usize, 1), tap_met.failovers);
}

test "usage capture: tokens recorded from upstream response" {
    const alloc = std.testing.allocator;
    const metrics_mod = @import("metrics.zig");

    var fake = FakeUpstream{
        .port = testPort(18086),
        .always_ok = true,
        .requests = std.atomic.Value(usize).init(0),
        .stopping = std.atomic.Value(bool).init(false),
        .saw_auth = undefined,
        .saw_auth_len = [_]usize{ 0, 0 },
        .saw_model = undefined,
        .saw_model_len = 0,
        .mu = .{},
    };
    var fake_future = std.Io.async(sharedIo(), FakeUpstream.run, .{&fake});
    defer {
        fake.stopping.store(true, .seq_cst);
        pokePortOnPool(fake.port);
        fake_future.await(sharedIo());
    }

    var keys = [_]models.Key{.{ .key = "UKEY" }};
    var headers = [_]models.CustomHeader{};
    const upstream_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}/fake/v1/", .{fake.port});
    defer alloc.free(upstream_url);
    var providers = [_]models.Provider{.{
        .display_name = "Fake",
        .base_url = upstream_url,
        .prefix = "fk/",
        .description = "fake upstream",
        .keys = &keys,
        .headers = &headers,
    }};
    var cfg = models.ProxyConfig{ .port = testPort(18087), .providers = &providers };
    var real_metrics = metrics_mod.Metrics.init();
    var proxy = Proxy.init(alloc, &cfg, .{
        .metrics = Metrics.wrap(&real_metrics),
    });
    try proxy.start();
    defer proxy.stop();

    const body = "{\"model\":\"fk/magic-model\",\"messages\":[],\"stream\":false}";
    const chat = try std.fmt.allocPrint(alloc, "POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
    defer alloc.free(chat);
    const resp = try testClientRequest(alloc, testPort(18087), chat);
    defer alloc.free(resp);
    try std.testing.expectEqual(@as(u16, 200), try responseStatus(resp));

    // recordUsage happens on the worker after the response is relayed; spin
    // briefly for the write to land.
    var spins: u32 = 0;
    var days_buf: [8]metrics_mod.UsageDay = undefined;
    var snap = real_metrics.usageSnapshot(&days_buf);
    while (snap.total_requests < 1 and spins < 10_000_000) : (spins += 1) {
        spinYield();
        snap = real_metrics.usageSnapshot(&days_buf);
    }
    try std.testing.expectEqual(@as(u64, 120), snap.total_in);
    try std.testing.expectEqual(@as(u64, 45), snap.total_out);
    try std.testing.expectEqual(@as(u64, 7), snap.total_cached);
    try std.testing.expectEqual(@as(u64, 1), snap.total_requests);
    try std.testing.expectEqual(@as(usize, 1), snap.days.len);
}

test "Zen selects wire format by model, custom providers retain configured format" {
    var p = models.Provider{ .display_name = "Zen", .base_url = "https://opencode.ai/zen/v1/", .prefix = "oc/", .description = "", .keys = &.{}, .headers = &.{}, .wire_api = .openai_responses };
    try std.testing.expect(!usesResponses(&p, "mimo-v2.5-free"));
    try std.testing.expect(!usesResponses(&p, "deepseek-v4-flash-free"));
    try std.testing.expect(usesResponses(&p, "gpt-5.4"));
    try std.testing.expect(usesResponses(&p, "muse-spark-1.3-contributor-free"));
    p.base_url = "https://example.com/v1";
    try std.testing.expect(usesResponses(&p, "mimo-v2.5-free"));
}

test "Thinking repair is specific and enables every supplied thinking control" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(needsThinkingRepair(400, "该模型始终思考，不支持关闭思考"));
    try std.testing.expect(!needsThinkingRepair(401, "该模型始终思考"));
    try std.testing.expect(!needsThinkingRepair(400, "invalid tools"));
    const out = try thinkingBody(a,
        \\{"model":"x","reasoning_effort":"none","thinking":{"type":"disabled","keep":"all"},"reasoning":{"effort":"none","enabled":false},"messages":[]}
    );
    const doc = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    const o = doc.value.object;
    try std.testing.expectEqualStrings("low", o.get("reasoning_effort").?.string);
    try std.testing.expectEqualStrings("enabled", o.get("thinking").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("all", o.get("thinking").?.object.get("keep").?.string);
    try std.testing.expectEqualStrings("low", o.get("reasoning").?.object.get("effort").?.string);
}

test "Synthesized SSE preserves indexed tools and final reason without repeating content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"hello","tool_calls":[{"id":"c1","type":"function","function":{"name":"lookup","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}
    ;
    const first = try synthChunk(a, body, null);
    const last = try synthChunk(a, body, "stop");
    try std.testing.expect(std.mem.indexOf(u8, first, "\"index\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "lookup") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "hello") == null);
    try std.testing.expect(std.mem.indexOf(u8, last, "\"finish_reason\":\"tool_calls\"") != null);
}

test "Nous tags are scoped to its host and retain caller attribution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = models.Provider{ .display_name = "Nous", .base_url = "https://inference-api.nousresearch.com/v1", .prefix = "n/", .description = "", .keys = &.{}, .headers = &.{} };
    const out = try providerBody(a, &p, "{\"model\":\"x\"}");
    const doc = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    try std.testing.expectEqualStrings("user=freepro", doc.value.object.get("tags").?.array.items[0].string);
    const custom = try providerBody(a, &p, "{\"model\":\"x\",\"tags\":[\"user=custom\",\"product=custom\"]}");
    const custom_doc = try std.json.parseFromSlice(std.json.Value, a, custom, .{});
    try std.testing.expectEqual(@as(usize, 2), custom_doc.value.object.get("tags").?.array.items.len);
    p.base_url = "https://example.com/v1";
    try std.testing.expectEqualStrings("{}", try providerBody(a, &p, "{}"));
}

test "public proxy transport failures do not cool or kill API keys" {
    const a = std.testing.allocator;
    var pool = freeproxy.Pool.init(a, sharedIo());
    defer pool.deinit();
    pool.lists_fetched_ms = nowMs();
    pool.pool_validated_ms = nowMs();
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 1 });
    try pool.entries.append(a, .{ .host = try a.dupe(u8, "127.0.0.1"), .port = 2 });
    var keys = [_]models.Key{.{ .key = "fixture-only" }};
    var providers = [_]models.Provider{.{ .display_name = "fixture", .base_url = "https://origin.invalid/v1", .prefix = "test/", .description = "", .headers = &.{}, .keys = &keys, .use_free_proxy = true }};
    var cfg = models.ProxyConfig{ .providers = &providers };
    var proxy = Proxy.init(a, &cfg, .{ .free_proxies = &pool });
    defer proxy.deinit();
    var cursors = [_]usize{0};
    proxy.standalone_cursors = &cursors;
    defer proxy.standalone_cursors = &.{};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    var provider: ?usize = null;
    const req = InboundRequest{ .method = "POST", .path = "/v1/chat/completions", .body = "{\"model\":\"test/m\",\"messages\":[]}" };
    _ = try handleCompletions(&proxy, &writer.writer, arena.allocator(), req, .chat_completions, &provider);
    try std.testing.expectEqual(@as(usize, 0), pool.entries.items.len);
    try std.testing.expectEqual(models.KeyState.Active, keys[0].state);
    try std.testing.expectEqual(@as(u32, 0), keys[0].consecutive_errors);
    try std.testing.expect(std.mem.indexOf(u8, writer.written(), "API keys unchanged") != null);
    _ = try handleCompletions(&proxy, &writer.writer, arena.allocator(), req, .chat_completions, &provider);
    try std.testing.expectEqual(models.KeyState.Active, keys[0].state);
}

test "usage accounting reads structured usage and reassembles split SSE events" {
    var acc: UsageAccum = .{ .alloc = std.testing.allocator };
    defer acc.deinit();
    acc.scan("{\"choices\":[{\"message\":{\"content\":\"prompt_tokens 999999\"}}]}");
    try std.testing.expectEqual(@as(u64, 0), acc.input);
    acc.scanSse("data: {\"usage\":{\"prompt_tok");
    acc.scanSse("ens\":123,\"completion_tokens\":45,\"prompt_tokens_details\":{\"cached_tokens\":67}}}\n\n");
    try std.testing.expectEqual(@as(u64, 123), acc.input);
    try std.testing.expectEqual(@as(u64, 45), acc.output);
    try std.testing.expectEqual(@as(u64, 67), acc.cached);
}

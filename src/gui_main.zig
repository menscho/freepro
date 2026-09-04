// src/gui_main.zig - freepro serve-mode entry point (browser dashboard).
//
// Headless companion to src/main.zig: it wires the SAME engine modules
// (models/config/logger/metrics/rotator/proxy) through relative sibling
// imports, starts the proxy unconditionally, and opens the operator
// dashboard in the default browser. A small stdin console with the
// quit|exit/status/open commands keeps the process controllable.
//
// Build/run (std-only, no third-party packages):
//   zig build-exe src/gui_main.zig   (direct compile; console on stdin)
//   ./gui_main                       (`quit` exits)
//
// Shutdown: the stdin thread sets the shutdown flag on quit/EOF; the main
// thread then stops the proxy, tears down the rotator, persists the config,
// and frees all owned state. Headless src/main.zig stays untouched: nothing
// here is imported by it, and this file never imports it.

const std = @import("std");
const builtin = @import("builtin");
const models = @import("models.zig");
const config_mod = @import("config.zig");
const logger_mod = @import("logger.zig");
const metrics_mod = @import("metrics.zig");
const rotator_mod = @import("rotator.zig");
const proxy_mod = @import("proxy.zig");
const freeproxy_mod = @import("freeproxy.zig");
const dashboard = @import("dashboard.zig");
const updater_mod = @import("updater.zig");

/// Upstream hosts that are unreachable (offline, firewalled, DNS down)
/// surface as error.Unexpected from the Windows network layer. The std
/// debug handler prints an NTSTATUS dump plus a stack trace per call,
/// which floods the console in serve mode; the dashboard already logs a
/// per-provider warning instead. Keep the dump out of release-style runs.
pub const std_options: std.Options = .{
    .unexpected_error_tracing = false,
};

// ---------------------------------------------------------------------------
// Application state (serve mode; the proxy borrows config/log/metrics)
// ---------------------------------------------------------------------------

const State = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    config: models.ProxyConfig,
    config_path: []u8,
    log: logger_mod.Logger,
    metrics: metrics_mod.Metrics,
    rot: ?rotator_mod.Rotator,
    server: ?proxy_mod.Proxy,
    proxies: freeproxy_mod.Pool,
    proxy_started: std.atomic.Value(bool),
    shutdown: std.atomic.Value(bool),
    start_ms: i64,
};

var g: State = undefined;
var controller: Controller = undefined;

const poll_delay = std.Io.Duration.fromMilliseconds(100);

/// Wall-clock time in unix milliseconds. `std.time.milliTimestamp` where
/// present (Zig <= 0.15), else a direct OS read so timestamps stay Io-free.
fn realtimeMillis() i64 {
    if (@hasDecl(std.time, "milliTimestamp")) {
        return std.time.milliTimestamp();
    }
    if (builtin.os.tag == .windows) {
        // 100ns ticks since 1601-01-01; 11_644_473_600_000ms = 1601 -> 1970.
        const ticks_100ns: i64 = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        return @divFloor(ticks_100ns, 10_000) - 11_644_473_600_000;
    }
    var ts: std.posix.timespec = undefined;
    // CLOCK_REALTIME; fail open (epoch) on error. Zig 0.16 spells the
    // timespec fields sec/nsec.
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divFloor(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

// ---------------------------------------------------------------------------
// Config file: OS-standard location, JSON via config.zig
// ---------------------------------------------------------------------------

/// Load the JSON config at `path`, falling back to presets (with a log line)
/// when the file is missing, unreadable, unparsable, or invalid.
/// Always returns an owned config. Requires g.log to be set.
fn loadConfigOrDefaults(alloc: std.mem.Allocator, path: []const u8) !models.ProxyConfig {
    var cfg = config_mod.loadFromPath(alloc, g.io, path) catch {
        g.log.warn("cannot load {s}; using OpenCode+Kilo presets", .{path});
        return config_mod.defaultConfig(alloc);
    };
    cfg.validate() catch {
        g.log.warn("config at {s} invalid; using presets", .{path});
        cfg.deinit(alloc);
        return config_mod.defaultConfig(alloc);
    };
    if (cfg.providers.len == 0) {
        g.log.warn("config at {s} has no providers; restoring OpenCode+Kilo presets", .{path});
        cfg.deinit(alloc);
        return config_mod.defaultConfig(alloc);
    }
    // Migration: append provider presets that did not exist when the config
    // was created (b.ai seeds; tokenrouter/cline/nous as bare gateways).
    const missing = [_]struct {
        prefix: []const u8,
        display_name: []const u8,
        base_url: []const u8,
        description: []const u8,
        make: *const fn (std.mem.Allocator) anyerror!models.Provider,
    }{
        .{ .prefix = models.bai_prefix, .display_name = models.bai_display_name, .base_url = models.bai_base_url, .description = models.bai_description, .make = models.defaultBaiProvider },
        .{ .prefix = models.tokenrouter_prefix, .display_name = models.tokenrouter_display_name, .base_url = models.tokenrouter_base_url, .description = models.tokenrouter_description, .make = models.defaultBareTokenRouter },
        .{ .prefix = models.cline_prefix, .display_name = models.cline_display_name, .base_url = models.cline_base_url, .description = models.cline_description, .make = models.defaultBareCline },
        .{ .prefix = models.nous_prefix, .display_name = models.nous_display_name, .base_url = models.nous_base_url, .description = models.nous_description, .make = models.defaultBareNous },
    };
    var appended: usize = 0;
    for (missing) |m| {
        var has = false;
        for (cfg.providers) |*p| {
            if (std.mem.eql(u8, p.prefix, m.prefix)) {
                has = true;
                break;
            }
        }
        if (has) continue;
        var prov = m.make(alloc) catch {
            g.log.warn("preset append failed for {s}; continuing without it", .{m.prefix});
            continue;
        };
        const old = cfg.providers;
        const grown = alloc.alloc(models.Provider, old.len + 1) catch {
            prov.deinit(alloc);
            continue;
        };
        @memcpy(grown[0..old.len], old);
        grown[old.len] = prov;
        cfg.providers = grown;
        appended += 1;
    }
    if (appended != 0) {
        cfg.validate() catch {};
        g.log.info("appended {d} missing provider preset(s)", .{appended});
    }
    // Migration: seed notes + site URLs for providers created before those
    // fields existed (matched by prefix; user edits are never overwritten).
    for (cfg.providers) |*p| {
        if (p.note.len == 0) {
            const preset_note = models.noteForPrefix(p.prefix);
            if (preset_note.len != 0) {
                p.note = alloc.dupe(u8, preset_note) catch p.note;
            }
        }
        if (p.site_url.len == 0) {
            const preset_site = models.siteUrlForPrefix(p.prefix);
            if (preset_site.len != 0) {
                p.site_url = alloc.dupe(u8, preset_site) catch p.site_url;
            }
        }
        // Migration: fix the two OpenCode session/request header values that
        // shipped corrupted. Zen endpoint selection is now per model.
        if (std.mem.eql(u8, p.prefix, models.opencode_prefix)) {
            for (p.headers) |*h| {
                if (std.mem.eql(u8, h.key, "x-opencode-session") and
                    std.mem.eql(u8, h.value, "ses_19f6c1805ffe2ziZ0G3WZ2dgAW"))
                {
                    const fixed = alloc.dupe(u8, "ses_19f6c1805ffe2ziZ0G3WZCdgAW") catch continue;
                    alloc.free(h.value);
                    h.value = fixed;
                }
                if (std.mem.eql(u8, h.key, "x-opencode-request") and
                    std.mem.eql(u8, h.value, "msg_8c4e2c91b7d03f5e"))
                {
                    const fixed = alloc.dupe(u8, "msg_8c4e2a91b7d03f5e") catch continue;
                    alloc.free(h.value);
                    h.value = fixed;
                }
            }
        }
        // Apply the configured defaults to models without explicit levels.
        for (p.models) |*m| {
            if (m.reasoning_levels.len == 0 or models.isLegacyReasoningLevels(m.reasoning_levels)) {
                const upgraded = alloc.dupe(u8, models.default_reasoning_levels) catch continue;
                if (m.reasoning_levels.len != 0) alloc.free(m.reasoning_levels);
                m.reasoning_levels = upgraded;
            }
        }
    }
    g.log.info("loaded config from {s}", .{path});
    return cfg;
}

/// Serialize the live config to disk (atomic tmp-file + rename inside
/// config.zig). Syncs lifetime token usage from live metrics first so the
/// dashboard survives restarts.
fn saveConfig() !void {
    syncUsageToConfig();
    try config_mod.saveToPath(g.alloc, g.io, &g.config, g.config_path);
    g.log.info("config saved to {s}", .{g.config_path});
}

/// Copy live usage counters from metrics into the config (totals + the
/// 30-day bucket ring).
fn syncUsageToConfig() void {
    g.metrics.syncConfig(g.alloc, &g.config) catch {};
}

fn restoreUsageFromConfig() void {
    g.metrics.restoreConfig(g.config);
}

// ---------------------------------------------------------------------------
// Rotator + proxy lifecycle (mirrors of main.zig)
// ---------------------------------------------------------------------------

fn rotPtr() ?*rotator_mod.Rotator {
    if (g.rot) |*rot| return rot;
    return null;
}

fn initRotator() void {
    g.rot = rotator_mod.Rotator.init(g.alloc, &g.config) catch |err| {
        g.log.err("rotator init failed: {s}", .{@errorName(err)});
        g.rot = null;
        return;
    };
    g.log.info("rotator ready over {d} providers", .{g.config.providers.len});
}

fn deinitRotator() void {
    if (g.rot) |*rot| {
        rot.deinit();
        g.rot = null;
    }
}

// ---------------------------------------------------------------------------
// Dashboard controller: dashboard.zig owns the struct; these adapters bind
// its lifecycle hooks to serve-mode State. Handlers run on proxy worker
// threads, so the in-flight adapter only touches atomics/metrics; heavier
// work goes through the dashboard applier.
// ---------------------------------------------------------------------------

const Controller = dashboard.Controller;

fn ctrlStop(c: *Controller) void {
    _ = c;
    stopProxy();
}

fn ctrlStart(c: *Controller) anyerror!void {
    _ = c;
    if (!startProxy()) return error.ProxyStartFailed;
}

fn ctrlIsRunning(c: *Controller) bool {
    // Ground truth from the proxy struct itself: the dashboard can stop and
    // restart the server from worker threads, which never touch this flag.
    // The struct lives in the global slot for the process lifetime, so the
    // read is always mapped memory (values may lag by milliseconds).
    return c.proxy.isRunning();
}

fn ctrlInFlight(c: *Controller) usize {
    _ = c;
    // Metrics counters, not g.server: the hook runs on proxy worker threads
    // and must never touch lifecycle-owned state.
    return g.metrics.snapshot().active_inflight;
}

fn ctrlReinitRotator(c: *Controller) void {
    _ = c;
    deinitRotator();
    initRotator();
}

/// Install the dashboard hook. The controller global outlives the proxy by
/// construction (both owned by serve-mode State), so the hook ctx stays
/// valid from the first startProxy() until process exit.
fn installDashboard() ?proxy_mod.DashboardHook {
    return controller.hook();
}

/// Start the proxy engine. Idempotent; returns false on failure (logged).
/// Proxy.start() is non-blocking (own accept thread + workers), so no
/// main-side proxy thread is needed. Safe to call when already running, and
/// rebinds a worker-side stopped server (dashboard fast path) without
/// reallocating: the payload slot is stable, so controller.proxy stays valid.
fn startProxy() bool {
    if (g.server == null) {
        g.server = proxy_mod.Proxy.init(g.alloc, &g.config, .{
            .rotator = rotPtr(),
            .logger = proxy_mod.Logger.wrap(&g.log),
            .metrics = proxy_mod.Metrics.wrap(&g.metrics),
            .io = g.io,
            .dashboard = installDashboard(),
            .free_proxies = &g.proxies,
        });
        controller.proxy = &g.server.?;
    }
    if (g.server.?.isRunning()) {
        g.proxy_started.store(true, .release);
        return true;
    }
    g.server.?.start() catch |err| {
        g.log.err("proxy failed to bind 127.0.0.1:{d}: {s}", .{ g.config.port, @errorName(err) });
        return false;
    };
    g.proxy_started.store(true, .release);
    g.log.info("proxy listening on 127.0.0.1:{d}", .{g.config.port});
    return true;
}

/// Stop the proxy engine and release it. Idempotent.
fn stopProxy() void {
    if (g.server) |*s| {
        s.stop();
        s.deinit();
        g.server = null;
    }
    g.proxy_started.store(false, .release);
}

// ---------------------------------------------------------------------------
// Browser launcher (warn-only; the proxy keeps serving either way)
// ---------------------------------------------------------------------------

fn dashboardUrl(buf: []u8) []u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}/", .{g.config.port}) catch buf[0..0];
}

/// Windows shell32: the OS-native URL launcher. Routed through
/// ShellExecuteExW with SEE_MASK_FLAG_NO_UI so a failing association never
/// pops the shell's own modal "fatal error" dialog inside our process (it
/// did before, titled with the URL), and after initializing COM on the
/// calling thread — ShellExecute requires it and fails without.
const shell32 = struct {
    pub const SW_SHOWNORMAL: i32 = 1;
    pub const SEE_MASK_NOASYNC: u32 = 0x1000;
    pub const SEE_MASK_FLAG_NO_UI: u32 = 0x400;
    pub const COINIT_APARTMENTTHREADED: u32 = 0x2;
    pub const COINIT_DISABLE_OLE1DDE: u32 = 0x4;

    pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) i32;

    pub extern "shell32" fn ShellExecuteExW(pexecinfo: *SHELLEXECUTEINFOW) callconv(.winapi) i32;

    // winshellapi.h SHELLEXECUTEINFO, natural alignment matches the C layout.
    pub const SHELLEXECUTEINFOW = extern struct {
        cbSize: u32,
        fMask: u32,
        hwnd: ?*anyopaque,
        lpVerb: ?[*:0]const u16,
        lpFile: ?[*:0]const u16,
        lpParameters: ?[*:0]const u16,
        lpDirectory: ?[*:0]const u16,
        nShow: i32,
        hInstApp: ?*anyopaque,
        lpIDList: ?*anyopaque,
        lpClass: ?[*:0]const u16,
        hkeyClass: ?*anyopaque,
        dwHotKey: u32,
        hIconOrMonitor: ?*anyopaque,
        hProcess: ?*anyopaque,
    };
};

fn openBrowser(url: []const u8) void {
    if (builtin.os.tag == .windows) {
        const wide = std.unicode.utf8ToUtf16LeAllocZ(g.alloc, url) catch {
            g.log.warn("cannot encode url {s}", .{url});
            return;
        };
        defer g.alloc.free(wide);
        // Per-thread COM init; S_OK / S_FALSE / RPC_E_CHANGED_MODE are all
        // fine to proceed on and we never uninitialize (process lives on).
        _ = shell32.CoInitializeEx(null, shell32.COINIT_APARTMENTTHREADED | shell32.COINIT_DISABLE_OLE1DDE);
        const open_verb: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("open");
        var info = shell32.SHELLEXECUTEINFOW{
            .cbSize = @sizeOf(shell32.SHELLEXECUTEINFOW),
            .fMask = shell32.SEE_MASK_NOASYNC | shell32.SEE_MASK_FLAG_NO_UI,
            .hwnd = null,
            .lpVerb = open_verb,
            .lpFile = wide.ptr,
            .lpParameters = null,
            .lpDirectory = null,
            .nShow = shell32.SW_SHOWNORMAL,
            .hInstApp = null,
            .lpIDList = null,
            .lpClass = null,
            .hkeyClass = null,
            .dwHotKey = 0,
            .hIconOrMonitor = null,
            .hProcess = null,
        };
        if (shell32.ShellExecuteExW(&info) == 1) return;
        // Silent failure (no dialog): log it, then try the explorer shim,
        // which opens the default browser for URLs and cannot pop a dialog.
        g.log.warn("cannot open browser via shell; dashboard is at {s}", .{url});
        _ = std.process.spawn(g.io, .{ .argv = &.{ "explorer.exe", url }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| {
            g.log.warn("cannot open browser ({s}); dashboard is at {s}", .{ @errorName(err), url });
        };
        return;
    }
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        else => &.{ "xdg-open", url },
    };
    // Spawned and intentionally never waited on: the browser outlives us.
    // Any failure only warns; the dashboard stays reachable by URL.
    _ = std.process.spawn(g.io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| {
        g.log.warn("cannot open browser ({s}); dashboard is at {s}", .{ @errorName(err), url });
    };
}

// ---------------------------------------------------------------------------
// Stdin operator console: quit|exit/status/open
// ---------------------------------------------------------------------------

fn stdinThreadMain() void {
    var buf: [1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(g.io, &buf);
    while (!g.shutdown.load(.acquire)) {
        const line = stdin.interface.takeDelimiter('\n') catch break;
        if (line == null) break; // EOF (piped input closed)
        if (handleCommand(line.?)) {
            g.shutdown.store(true, .release);
            break;
        }
    }
}

/// Returns true when the loop should quit.
fn handleCommand(raw: []const u8) bool {
    const line = std.mem.trim(u8, raw, " \t\r\n");
    if (line.len == 0) return false;
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    const verb = words.next() orelse return false;

    if (std.mem.eql(u8, verb, "quit") or std.mem.eql(u8, verb, "exit")) {
        print("shutting down...\n", .{});
        return true;
    }
    if (std.mem.eql(u8, verb, "status")) {
        printStatus();
    } else if (std.mem.eql(u8, verb, "open")) {
        var url_buf: [64]u8 = undefined;
        const url = dashboardUrl(&url_buf);
        openBrowser(url);
        print("dashboard: {s}\n", .{url});
    } else {
        print("unknown command '{s}'; commands: status, open, quit\n", .{verb});
    }
    return false;
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stdout().writeStreamingAll(g.io, text) catch {};
}

fn printStatus() void {
    const snap = g.metrics.snapshot();
    var url_buf: [64]u8 = undefined;
    // Ground truth from the proxy struct: the dashboard may stop or restart
    // the server from worker threads without touching the stdin flag. The
    // struct lives in the global slot for the process lifetime, so this read
    // is always mapped memory.
    const running = if (g.server) |*s| s.isRunning() else false;
    print("server: {s} on {s}\n", .{
        if (running) "RUNNING" else "STOPPED",
        dashboardUrl(&url_buf),
    });
    print("providers: {d}  requests: {d} served, {d} in flight, {d} errors, {d} failovers\n", .{
        g.config.providers.len,
        snap.total_requests,
        snap.active_inflight,
        snap.total_errors,
        snap.total_failovers,
    });
    print("config: {s}\n", .{g.config_path});
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_alloc = std.heap.DebugAllocator(.{}){};
    defer _ = debug_alloc.deinit();
    const alloc = debug_alloc.allocator();

    // App-owned I/O pool: file, stdio, sleep, and child-spawn calls on every
    // thread go through this. Joined (stdin thread) before deinit: the stdin
    // join is deferred later, so it runs first.
    var threaded = std.Io.Threaded.init(alloc, .{ .environ = init.environ });
    defer threaded.deinit();

    g.log = logger_mod.Logger.init();
    g.metrics = metrics_mod.Metrics.init();
    g.alloc = alloc;
    g.io = threaded.io();
    var args = try std.process.Args.Iterator.initAllocator(init.args, alloc);
    defer args.deinit();
    _ = args.next();
    var background = false;
    if (args.next()) |arg| {
        background = std.mem.eql(u8, arg, "--background");
        if (std.mem.eql(u8, arg, "--version")) {
            print("freepro {s}\n", .{updater_mod.version});
            return;
        }
        if (std.mem.eql(u8, arg, "--apply-update")) {
            const target = args.next() orelse return error.MissingArgument;
            const marker = args.next() orelse return error.MissingArgument;
            return updater_mod.applyUpdate(alloc, g.io, target, marker);
        }
    }
    var updater = updater_mod.Updater.init(alloc, g.io);
    defer updater.deinit();

    // Snapshot the OS environment once; config.zig resolves the OS-standard
    // path from it. The resolved path is a dupe, so the map is short-lived.
    const env_block: std.process.Environ.Block = if (builtin.os.tag == .windows)
        .global
    else if (builtin.link_libc) env_block: {
        var n: usize = 0;
        while (std.c.environ[n] != null) : (n += 1) {}
        break :env_block .{ .slice = std.c.environ[0..n :null] };
    } else .empty;
    const environ: std.process.Environ = .{ .block = env_block };
    var env_map = try std.process.Environ.createMap(environ, alloc);
    defer env_map.deinit();

    g.config_path = try config_mod.configFilePath(alloc, &env_map);
    errdefer alloc.free(g.config_path);
    g.config = try loadConfigOrDefaults(alloc, g.config_path);
    g.rot = null;
    g.server = null;
    g.proxies = freeproxy_mod.Pool.init(alloc, g.io);
    g.proxies.log_msg = struct {
        fn sink(msg: []const u8) void {
            g.log.info("{s}", .{msg});
        }
    }.sink;
    g.proxy_started = std.atomic.Value(bool).init(false);
    g.shutdown = std.atomic.Value(bool).init(false);
    g.start_ms = realtimeMillis();

    var quickadd_random: [16]u8 = undefined;
    g.io.random(&quickadd_random);
    const quickadd_token = try std.fmt.allocPrint(alloc, "{x}", .{quickadd_random});
    defer alloc.free(quickadd_token);
    const kimi_config_path = try @import("quickadd.zig").configPath(alloc, &env_map);
    defer alloc.free(kimi_config_path);
    controller = .{
        .updater = &updater,
        .kimi_config_path = kimi_config_path,
        .quickadd_token = quickadd_token,
        .alloc = alloc,
        .io = g.io,
        .config = &g.config,
        .config_path = g.config_path,
        .log = &g.log,
        .metrics = &g.metrics,
        // Server slot is created by startProxy below; the payload address is
        // stable across restarts (same global slot), so back-filling it there
        // stays valid for the process lifetime.
        .proxy = undefined,
        .free_proxies = &g.proxies,
        .stop_fn = ctrlStop,
        .start_fn = ctrlStart,
        .is_running_fn = ctrlIsRunning,
        .in_flight_fn = ctrlInFlight,
        .reinit_rotator_fn = ctrlReinitRotator,
    };
    g.metrics.setProviderCount(g.config.providers.len);

    g.log.info("freepro serve starting (config: {s})", .{g.config_path});
    initRotator();
    restoreUsageFromConfig();
    // Start warming the free-proxy pool immediately when any provider uses
    // it, so the first proxied request never races validation.
    for (g.config.providers) |*p| {
        if (p.use_free_proxy) {
            g.proxies.maybeRefresh();
            break;
        }
    }

    // Serve mode starts unconditionally: this binary exists to serve, so
    // auto_start is not consulted (unlike the headless operator console).
    if (!startProxy()) {
        g.log.warn("proxy failed to start; fix the port and restart", .{});
    } else {
        var url_buf: [64]u8 = undefined;
        const url = dashboardUrl(&url_buf);
        g.log.info("dashboard at {s}", .{url});
        if (env_map.get("FREEPRO_NO_BROWSER") == null) openBrowser(url);
    }

    updater.startCheck();

    const stdin_thread = if (background) null else try std.Thread.spawn(.{}, stdinThreadMain, .{});
    defer if (stdin_thread) |t| t.join();

    // Idle loop: the proxy owns its threads; here we only wait for quit/EOF.
    var last_usage_save = realtimeMillis();
    while (!g.shutdown.load(.acquire)) {
        if (updater.ready() and controller.inFlight() == 0) {
            stopProxy();
            controller.mu.lock();
            const saved = blk: {
                g.metrics.syncConfig(g.alloc, &g.config) catch break :blk false;
                config_mod.saveToPath(g.alloc, g.io, &g.config, g.config_path) catch break :blk false;
                break :blk true;
            };
            controller.mu.unlock();
            if (saved) {
                updater.activate() catch {
                    updater.saveFailed();
                    _ = startProxy();
                    continue;
                };
                // Exit releases the Windows executable and any blocked console reader.
                std.process.exit(0);
            }
            updater.saveFailed();
            _ = startProxy();
        }
        if (realtimeMillis() - last_usage_save >= 30_000) {
            controller.mu.lock();
            g.metrics.syncConfig(g.alloc, &g.config) catch {};
            config_mod.saveToPath(g.alloc, g.io, &g.config, g.config_path) catch {};
            controller.mu.unlock();
            last_usage_save = realtimeMillis();
        }
        std.Io.sleep(g.io, poll_delay, .awake) catch {};
    }

    // Graceful shutdown: stop listener, join workers, persist, free.
    stopProxy();
    deinitRotator();
    saveConfig() catch |err| {
        std.debug.print("final config save failed: {s}\n", .{@errorName(err)});
    };
    g.proxies.deinit();
    g.config.deinit(alloc);
    alloc.free(g.config_path);
}

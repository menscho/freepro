// src/main.zig — freepro application entry point (Wave1-Task10; Wave3-Task02).
//
// Wiring owned by this file: resolve the OS config path via config.zig, load
// the config from disk (or presets), init the logger / metrics / rotator,
// install proxy lifecycle hooks into the UI shell, plug the Models +
// Console+Settings views into App.views, run the foreground GUI loop with a
// stdin operator console thread, and on shutdown stop the server, persist the
// config, and free everything.
//
// Quick start (no third-party packages needed):
//   zig build run                 (from D:/freepro)
//   zig build-exe src/main.zig    (direct compile; operator console on stdin)
//   ./freepro                     (`quit` exits)
//
// Sibling contracts used (relative imports, per project convention):
//   models.zig  — ProxyConfig { port, providers, auto_start, cooldown_secs,
//                 timeout_ms } + defaultConfig/parse/toJsonAlloc/validate/deinit
//   config.zig  — configFilePath/loadFromPath/saveToPath/defaultConfig over
//                 std.Io + std.process.Environ.Map (owns ALL persistence; main
//                 keeps no inline file/env plumbing)
//   logger.zig  — Logger { init/info/warn/err/failover/logRequest, subscriber }
//   metrics.zig — Metrics { init/setProviderCount/snapshot }
//   ui/app.zig  — App { init/deinit/setViews/setHooks/render/refreshMetrics },
//                 ServerHooks, Views/ViewFn, nullUi()
//
// Sibling contracts USED (relative imports, per project convention):
//   rotator.zig — Rotator { init(alloc, cfg) !Rotator, deinit,
//                 nextHealthyKey(provider_idx) ?usize, reportResult(
//                 provider_idx, key_idx, status: ?u16), ... } (src/rotator.zig;
//                 main only uses init/deinit and passes *Rotator through)
//
// PROXY STATUS (Wave3-Task02): the flip is APPLIED. proxy.zig compiles on
// the Zig 0.16 toolchain (probe: `zig test src/proxy.zig` builds; only its
// loopback socket test fails at runtime in this Windows sandbox), exposes
// `Proxy` with the contract below, and main.zig imports it: have_proxy is
// true, State carries `server: ?proxy_mod.Proxy`, and startProxy/stopProxy
// drive it directly. Logger/Metrics cross the boundary through proxy.zig's
// structural facades (`proxy_mod.Logger.wrap(&g.log)` /
// `proxy_mod.Metrics.wrap(&g.metrics)`); the rotator crosses as
// `?*rotator_mod.Rotator` (aka `proxy_mod.Rotator`).
//   Proxy.init(alloc, cfg, .{ .rotator = ?*Rotator, .logger = ?*Logger,
//                            .metrics = ?*Metrics }) Proxy
//   proxy.start() !void  (binds 127.0.0.1:port, spawns its own accept
//                         thread + worker pool, then returns)
//   proxy.stop() void    (unblocks accept, joins workers, idempotent)
//   proxy.deinit() void  (leaves borrowed config/log/metrics alone)
// No main-side proxy thread is needed: Proxy.start() is non-blocking, so the
// accept loop + workers already run in the background by design; main only
// owns start/stop/shutdown ordering. If proxy.zig ever regresses to a stub
// without `Proxy`, have_proxy goes false, State.server collapses to `u0`,
// and start/stop degrade to logged no-ops without further edits.
//
// DVUI NOTE: the foreground loop below pumps App.render() every frame against
// ui/app.zig's Ui vtable. This binary stays headless by design (nullUi() +
// stdin operator console). The real native window lives in src/gui_main.zig
// (DVUI + SDL3, ), which renders the same view-models with
// native widgets instead of going through the Ui vtable.
//

// Shutdown: the stdin thread sets the shutdown flag on `quit`/EOF; the frame
// loop then stops the proxy thread (join), saves the config file, and frees
// all owned state. Ctrl-C without a handler still kills the process abruptly,
// so the loop also autosaves every autosave_interval_ms while dirty.

const std = @import("std");
const builtin = @import("builtin");
const models = @import("models.zig");
const config_mod = @import("config.zig");
const logger_mod = @import("logger.zig");
const metrics_mod = @import("metrics.zig");
const rotator_mod = @import("rotator.zig");
const proxy_mod = @import("proxy.zig");
const app_ui = @import("ui/app.zig");
const views_dashboard = @import("ui/views_dashboard.zig");
const views_providers = @import("ui/views_providers.zig");
const models_console = @import("ui/views_models_console.zig");

/// Unreachable upstream hosts surface as error.Unexpected on Windows; the
/// std debug handler would print an NTSTATUS dump per call. The headless
/// console already surfaces per-provider warnings instead.
pub const std_options: std.Options = .{
    .unexpected_error_tracing = false,
};

const have_rotator = @hasDecl(rotator_mod, "Rotator");
// Proxy engine presence: true while proxy.zig exposes its Proxy decl and
// compiles on this toolchain (verified by probe: `zig test src/proxy.zig`
// builds; 8/9 tests pass, the loopback test hits a Windows sandbox
// CONNECTION_RESET at runtime). Wiring below adapts both states.
const have_proxy = @hasDecl(proxy_mod, "Proxy");

// TOOLCHAIN NOTE (Zig 0.16): the blocking OS mutex (`std.Thread.Mutex`),
// wall-clock `std.time.milliTimestamp`, `GeneralPurposeAllocator`, and the
// `std.fs`/`std.io` file+stdio API no longer exist. This file follows the
// house shims from logger.zig/rotator.zig/config.zig: a yield-spinning Mutex
// over `std.atomic.Mutex`, a direct-OS millisecond clock,
// `std.heap.DebugAllocator`, and all file/stdio/sleep I/O through an
// app-owned `std.Io.Threaded` pool stored on State as `io`. Config
// persistence itself (path resolution, atomic JSON load/save) is owned by
// config.zig operating on a one-shot `std.process.Environ.Map` snapshot;
// main keeps no inline file or env plumbing.
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
    // CLOCK_REALTIME; fail open (epoch) if the call fails: uptime/autosave
    // just read as zero. Zig 0.16 spells the timespec fields sec/nsec.
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divFloor(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Slot for the rotator: the real type (rotator.zig compiles), empty struct
/// if it ever regresses to a stub without Rotator.
const RotatorSlot = if (have_rotator) ?rotator_mod.Rotator else struct {
    _absent: u8 = 0,
};

const autosave_interval_ms: i64 = 30_000;
const frame_delay = std.Io.Duration.fromMilliseconds(33);

// ---------------------------------------------------------------------------
// Global application state (single-window app; view adapters read it back)
// ---------------------------------------------------------------------------

const State = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    config: models.ProxyConfig,
    config_path: []u8,
    log: logger_mod.Logger,
    metrics: metrics_mod.Metrics,
    app: app_ui.App,
    dashboard_view: views_dashboard.DashboardView,
    providers_view: views_providers.ProvidersView,
    models_view: models_console.ModelsView,
    console_view: models_console.ConsoleView,
    settings: models_console.SettingsState,
    rot: RotatorSlot,
    server: if (have_proxy) ?proxy_mod.Proxy else u0,
    proxy_started: std.atomic.Value(bool),
    shutdown: std.atomic.Value(bool),
    state_mutex: Mutex,
    start_ms: i64,
    last_autosave_ms: i64,
};

var g: State = undefined;

// ---------------------------------------------------------------------------
// Config file: OS-standard location, JSON via config.zig
//
// All path resolution, directory creation, and atomic JSON read/write live
// in config.zig (std.Io + std.process.Environ.Map). This file only adds the
// preset-fallback policy: any load failure (missing/unreadable/malformed/
// invalid) logs a line and yields an owned OpenCode+Kilo preset config.
// ---------------------------------------------------------------------------

/// Load the JSON config at `path`, falling back to presets (with a log line)
/// when the file is missing, unreadable, unparsable, or invalid.
/// Always returns an owned config. Requires g.log/g.io to be set.
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
    g.log.info("loaded config from {s}", .{path});
    return cfg;
}

/// Serialize the live config to disk (atomic tmp-file + rename inside
/// config.zig) and clear the settings dirty flag.
fn saveConfig() !void {
    try g.metrics.syncConfig(g.alloc, &g.config);
    try config_mod.saveToPath(g.alloc, g.io, &g.config, g.config_path);
    g.settings.markClean();
    g.last_autosave_ms = realtimeMillis();
    g.log.info("config saved to {s}", .{g.config_path});
}

// ---------------------------------------------------------------------------
// Rotator + proxy lifecycle (background thread)
// ---------------------------------------------------------------------------

fn rotPtr() ?*rotator_mod.Rotator {
    if (comptime have_rotator) {
        if (g.rot) |*rot| return rot;
        return null;
    } else {
        return null;
    }
}

fn initRotator() void {
    if (comptime have_rotator) {
        g.rot = rotator_mod.Rotator.init(g.alloc, &g.config) catch |err| {
            g.log.err("rotator init failed: {s}", .{@errorName(err)});
            g.rot = null;
            return;
        };
        g.log.info("rotator ready over {d} providers", .{g.config.providers.len});
    } else {
        g.log.warn("rotator.zig has no Rotator yet; serving without key rotation", .{});
    }
}

fn deinitRotator() void {
    if (comptime have_rotator) {
        if (g.rot) |*rot| {
            rot.deinit();
            g.rot = null;
        }
    }
}

/// Start the proxy engine. Idempotent; returns false when the engine is
/// unavailable or startup fails (reason is logged). Proxy.start() is
/// non-blocking (it spawns its own accept thread + workers and returns), so
/// no main-side proxy thread is needed.
fn startProxy() bool {
    if (g.proxy_started.load(.acquire)) return true;
    if (comptime have_proxy) {
        if (g.server != null) {
            g.proxy_started.store(true, .release);
            return true;
        }
        g.server = proxy_mod.Proxy.init(g.alloc, &g.config, .{
            .rotator = rotPtr(),
            .logger = proxy_mod.Logger.wrap(&g.log),
            .metrics = proxy_mod.Metrics.wrap(&g.metrics),
            .io = g.io,
        });
        g.server.?.start() catch |err| {
            g.log.err("proxy failed to bind 127.0.0.1:{d}: {s}", .{ g.config.port, @errorName(err) });
            g.server = null;
            return false;
        };
        g.proxy_started.store(true, .release);
        g.log.info("proxy listening on 127.0.0.1:{d}", .{g.config.port});
        return true;
    } else {
        g.log.warn("proxy engine unavailable (proxy.zig does not compile yet); start ignored", .{});
        return false;
    }
}

/// Stop the proxy engine and release it. Idempotent.
fn stopProxy() void {
    if (comptime have_proxy) {
        if (g.server) |*s| {
            s.stop();
            s.deinit();
            g.server = null;
        }
        g.proxy_started.store(false, .release);
    }
}

// ---------------------------------------------------------------------------
// ServerHooks for the UI shell top bar (run on the frame thread)
// ---------------------------------------------------------------------------

fn hookStart(ctx: ?*anyopaque, port: u16) bool {
    const self: *State = @ptrCast(@alignCast(ctx.?));
    self.config.port = port;
    if (!startProxy()) {
        self.app.setStatus("Proxy failed to start (see console).", .{});
        return false;
    }
    self.app.status = .running;
    self.app.setStatus("Proxy running on 127.0.0.1:{d}.", .{self.config.port});
    return true;
}

fn hookStop(ctx: ?*anyopaque) void {
    const self: *State = @ptrCast(@alignCast(ctx.?));
    _ = self;
    stopProxy();
}

fn hookPortChanged(ctx: ?*anyopaque, port: u16) void {
    const self: *State = @ptrCast(@alignCast(ctx.?));
    if (self.config.port == port) return;
    if (self.proxy_started.load(.acquire)) {
        stopProxy();
        self.config.port = port;
        if (startProxy()) {
            self.app.setStatus("Port set to {d}; proxy restarted.", .{port});
        } else {
            self.app.status = .stopped;
            self.app.setStatus("Port set to {d}; restart failed.", .{port});
        }
    } else {
        self.config.port = port;
    }
}

// ---------------------------------------------------------------------------
// ViewFn adapters: App.views slots -> view-model state (run on frame thread)
// ---------------------------------------------------------------------------

fn renderDashboard(app: *app_ui.App, ui: app_ui.Ui) void {
    _ = app;
    const view = &g.dashboard_view;
    ui.beginCol();
    ui.label("Dashboard - live proxy overview");
    for (view.stats.cards()) |card| {
        var buf: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "[{s}] {d} - {s}", .{ card.title, card.value, card.hint }) catch card.title;
        ui.label(line);
    }
    {
        var meta: [96]u8 = undefined;
        const line = std.fmt.bufPrint(&meta, "avg {d:.1}ms | errors {d} | failovers {d}", .{
            view.stats.avg_latency_ms,
            view.stats.total_errors,
            view.stats.total_failovers,
        }) catch "traffic";
        ui.label(line);
    }
    ui.label("--- activity ---");
    const feed = view.recent.items;
    const start = if (feed.len > 30) feed.len - 30 else 0;
    var line_buf: [logger_mod.max_msg_len + 32]u8 = undefined;
    for (feed[start..]) |*line| {
        var clock: [8]u8 = undefined;
        const stamp = logger_mod.formatTimeOfDay(line.timestamp_ms, &clock);
        const text = std.fmt.bufPrint(&line_buf, "{s} [{s}] {s}", .{ stamp, line.level.tag(), line.text() }) catch line.text();
        ui.label(text);
    }
    ui.endCol();
}

fn renderProviders(app: *app_ui.App, ui: app_ui.Ui) void {
    _ = app;
    const view = &g.providers_view;
    ui.beginCol();
    ui.label("Providers & Keys");
    ui.beginRow();
    for (g.config.providers, 0..) |*provider, i| {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}{s} [{s}]", .{
            if (view.selected == i) "[*] " else "[ ] ",
            provider.display_name,
            provider.prefix,
        }) catch provider.display_name;
        if (ui.button(name)) view.select(i, g.config.providers.len);
    }
    ui.endRow();
    if (view.selected < g.config.providers.len) {
        const provider = &g.config.providers[view.selected];
        const summary = views_providers.summarizeProvider(provider);
        var sum_buf: [160]u8 = undefined;
        const sum = std.fmt.bufPrint(&sum_buf, "{s} | {s} | {d}/{d} healthy - {s}", .{
            provider.display_name,
            provider.base_url,
            summary.healthy,
            summary.total,
            provider.description,
        }) catch provider.display_name;
        ui.label(sum);
        const shown = @min(provider.keys.len, 20);
        var key_buf: [96]u8 = undefined;
        for (provider.keys[0..shown], 0..) |*key, ki| {
            const badge = views_providers.badgeFor(key);
            const masked = views_providers.maskKey(key.key);
            const line = std.fmt.bufPrint(&key_buf, "#{d} {s} [{s}]{s}", .{
                ki + 1,
                masked.slice(),
                badge.label(),
                if (key.enabled) "" else " (disabled)",
            }) catch "#?";
            ui.label(line);
        }
        if (provider.keys.len > shown) {
            var more: [32]u8 = undefined;
            ui.label(std.fmt.bufPrint(&more, "... +{d} more", .{provider.keys.len - shown}) catch "...");
        }
    } else {
        ui.label("(no providers)");
    }
    ui.endCol();
}

fn renderModelsView(app: *app_ui.App, ui: app_ui.Ui) void {
    const view = &g.models_view;
    ui.beginCol();
    ui.label("Model Explorer - merged /v1/models catalog");
    if (ui.textBox(view.query_buf[0..], &view.query_len)) {
        view.setQuery(view.query_buf[0..view.query_len]) catch |err| {
            app.setStatus("Search failed: {s}.", .{@errorName(err)});
        };
    }
    ui.beginRow();
    for (models_console.StatusFilter.all_filters) |f| {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{
            if (view.filter == f) "[*] " else "[ ] ",
            f.label(),
        }) catch f.label();
        if (ui.button(name)) {
            view.setFilter(f) catch |err| {
                app.setStatus("Filter failed: {s}.", .{@errorName(err)});
            };
        }
    }
    ui.endRow();
    const rows = view.visible.items;
    const shown = @min(rows.len, models_console.max_text_rows);
    var row_buf: [160]u8 = undefined;
    for (rows[0..shown]) |index| {
        const entry = &view.entries.items[index];
        const line = std.fmt.bufPrint(&row_buf, "{s} | {s} | {s} | {s}", .{
            entry.prefixed_name,
            entry.provider_display,
            entry.upstream_name,
            entry.status.label(),
        }) catch entry.prefixed_name;
        ui.label(line);
    }
    if (rows.len > shown) {
        var more_buf: [32]u8 = undefined;
        const more = std.fmt.bufPrint(&more_buf, "... +{d} more", .{rows.len - shown}) catch "...";
        ui.label(more);
    }
    ui.endCol();
}

fn renderConsoleSettings(app: *app_ui.App, ui: app_ui.Ui) void {
    const console = &g.console_view;
    const settings = &g.settings;

    ui.beginCol();
    ui.label("Live Request Console");
    ui.beginRow();
    if (ui.button(if (console.follow) "Pause" else "Follow")) {
        console.setFollow(!console.follow);
    }
    if (ui.button("Clear")) console.clear();
    {
        var level_buf: [24]u8 = undefined;
        const level_text = std.fmt.bufPrint(&level_buf, "level>={s}", .{@tagName(console.min_level)}) catch "level";
        if (ui.button(level_text)) {
            console.setMinLevel(switch (console.min_level) {
                .info => .request,
                .request => .failover,
                .failover => .warn,
                .warn => .err,
                .err => .info,
            });
        }
    }
    ui.endRow();
    const tail = console.tail.items;
    const start = if (tail.len > 60) tail.len - 60 else 0;
    var line_buf: [logger_mod.max_msg_len + 32]u8 = undefined;
    for (tail[start..]) |*line| {
        var clock: [8]u8 = undefined;
        const stamp = logger_mod.formatTimeOfDay(line.timestamp_ms, &clock);
        const text = std.fmt.bufPrint(&line_buf, "{s} [{s}] {s}", .{ stamp, line.level.tag(), line.text() }) catch line.text();
        ui.label(text);
    }

    ui.label("Settings");
    ui.beginRow();
    {
        var auto_buf: [32]u8 = undefined;
        const auto_text = std.fmt.bufPrint(&auto_buf, "[{s}] auto-start", .{
            if (settings.auto_start) "x" else " ",
        }) catch "auto-start";
        if (ui.button(auto_text)) {
            settings.toggleAutoStart();
            g.log.info("auto-start {s}", .{if (settings.auto_start) "on" else "off"});
        }
    }
    ui.endRow();

    ui.beginRow();
    ui.label("cooldown(s):");
    if (ui.button("-")) settings.stepCooldown(-1);
    if (ui.textBox(settings.cooldown_text[0..], &settings.cooldown_len)) {
        settings.commitCooldownText() catch {
            app.setStatus("Invalid cooldown: use {d}..{d}.", .{ models_console.min_cooldown_secs, models_console.max_cooldown_secs });
        };
    }
    if (ui.button("+")) settings.stepCooldown(1);
    ui.endRow();

    ui.beginRow();
    ui.label("timeout(ms):");
    if (ui.button("-")) settings.stepTimeout(-1);
    if (ui.textBox(settings.timeout_text[0..], &settings.timeout_len)) {
        settings.commitTimeoutText() catch {
            app.setStatus("Invalid timeout: use {d}..{d}.", .{ models_console.min_timeout_ms, models_console.max_timeout_ms });
        };
    }
    if (ui.button("+")) settings.stepTimeout(1);
    ui.endRow();

    ui.beginRow();
    if (settings.dirty) ui.label("unsaved changes");
    if (ui.button("Save to config")) {
        settings.applyToConfig(&g.config) catch |err| {
            app.setStatus("Settings invalid: {s}.", .{@errorName(err)});
            ui.endRow();
            ui.endCol();
            return;
        };
        saveConfig() catch |err| {
            app.setStatus("Save failed: {s}.", .{@errorName(err)});
            ui.endRow();
            ui.endCol();
            return;
        };
        app.setStatus("Saved to {s}.", .{g.config_path});
    }
    ui.endRow();
    ui.endCol();
}

// ---------------------------------------------------------------------------
// Operator console (stdin thread): start/stop, settings, text snapshots
// ---------------------------------------------------------------------------

fn stdinThreadMain() void {
    var buf: [1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(g.io, &buf);
    while (!g.shutdown.load(.acquire)) {
        // Io.Reader.takeDelimiter keeps the 0.13 semantics: the line without
        // its delimiter, the unterminated tail on EOF, null on clean EOF.
        const line = stdin.interface.takeDelimiter('\n') catch break;
        if (line == null) break; // EOF (piped input closed)
        if (handleCommand(line.?)) break;
    }
    g.shutdown.store(true, .release);
}

/// Buffered stdout writer for multi-line snapshots; the caller must flush.
fn stdoutBuffered(buf: []u8) std.Io.File.Writer {
    return std.Io.File.stdout().writer(g.io, buf);
}

/// Returns true when the loop should quit.
fn handleCommand(raw: []const u8) bool {
    const line = std.mem.trim(u8, raw, " \t\r\n");
    if (line.len == 0) return false;
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    const verb = words.next() orelse return false;

    g.state_mutex.lock();
    defer g.state_mutex.unlock();

    if (std.mem.eql(u8, verb, "quit") or std.mem.eql(u8, verb, "exit")) {
        print("shutting down...\n", .{});
        return true;
    }
    if (std.mem.eql(u8, verb, "help")) {
        printHelp();
    } else if (std.mem.eql(u8, verb, "status")) {
        printStatus();
    } else if (std.mem.eql(u8, verb, "start")) {
        if (hookStart(&g, g.config.port)) print("proxy started on {d}\n", .{g.config.port});
    } else if (std.mem.eql(u8, verb, "stop")) {
        hookStop(&g);
        g.app.status = .stopped;
        print("proxy stopped\n", .{});
    } else if (std.mem.eql(u8, verb, "restart")) {
        hookStop(&g);
        if (hookStart(&g, g.config.port)) print("proxy restarted on {d}\n", .{g.config.port});
    } else if (std.mem.eql(u8, verb, "models")) {
        const rest = std.mem.trim(u8, words.rest(), " \t");
        if (rest.len > 0) g.models_view.setQuery(rest) catch {};
        g.models_view.refresh(g.config.providers) catch {};
        var sbuf: [4096]u8 = undefined;
        var out = stdoutBuffered(&sbuf);
        g.models_view.renderText(&out.interface) catch {};
        out.interface.flush() catch {};
    } else if (std.mem.eql(u8, verb, "search")) {
        g.models_view.setQuery(std.mem.trim(u8, words.rest(), " \t")) catch {};
        print("search: \"{s}\" ({d} shown)\n", .{ g.models_view.query(), g.models_view.visible.items.len });
    } else if (std.mem.eql(u8, verb, "clearsearch")) {
        g.models_view.clearQuery() catch {};
        print("search cleared\n", .{});
    } else if (std.mem.eql(u8, verb, "filter")) {
        const name = words.next() orelse "";
        var matched = false;
        for (models_console.StatusFilter.all_filters) |f| {
            if (std.ascii.eqlIgnoreCase(f.label(), name)) {
                g.models_view.setFilter(f) catch {};
                print("filter: {s}\n", .{f.label()});
                matched = true;
                break;
            }
        }
        if (!matched) print("filter: all|healthy|cooldown|dead|unknown\n", .{});
    } else if (std.mem.eql(u8, verb, "console")) {
        g.console_view.poll();
        var sbuf: [4096]u8 = undefined;
        var out = stdoutBuffered(&sbuf);
        g.console_view.renderAnsi(&out.interface) catch {};
        out.interface.flush() catch {};
    } else if (std.mem.eql(u8, verb, "settings")) {
        var sbuf: [4096]u8 = undefined;
        var out = stdoutBuffered(&sbuf);
        g.settings.renderText(&out.interface) catch {};
        out.interface.flush() catch {};
    } else if (std.mem.eql(u8, verb, "cooldown")) {
        const arg = words.next() orelse "";
        const secs = std.fmt.parseInt(u64, arg, 10) catch 0;
        if (secs < models_console.min_cooldown_secs or secs > models_console.max_cooldown_secs) {
            print("cooldown: {d}..{d} seconds\n", .{ models_console.min_cooldown_secs, models_console.max_cooldown_secs });
        } else {
            g.config.cooldown_secs = secs;
            g.settings.syncFromConfig(&g.config);
            g.settings.markDirty();
            print("cooldown set to {d}s (unsaved)\n", .{secs});
        }
    } else if (std.mem.eql(u8, verb, "timeout")) {
        const arg = words.next() orelse "";
        const ms = std.fmt.parseInt(u32, arg, 10) catch 0;
        if (ms < models_console.min_timeout_ms or ms > models_console.max_timeout_ms) {
            print("timeout: {d}..{d} ms\n", .{ models_console.min_timeout_ms, models_console.max_timeout_ms });
        } else {
            g.config.timeout_ms = ms;
            g.settings.syncFromConfig(&g.config);
            g.settings.markDirty();
            print("timeout set to {d}ms (unsaved)\n", .{ms});
        }
    } else if (std.mem.eql(u8, verb, "autostart")) {
        const arg = words.next() orelse "";
        if (std.mem.eql(u8, arg, "on")) {
            g.config.auto_start = true;
        } else if (std.mem.eql(u8, arg, "off")) {
            g.config.auto_start = false;
        } else {
            print("autostart on|off\n", .{});
            return false;
        }
        g.settings.syncFromConfig(&g.config);
        g.settings.markDirty();
        print("auto-start {s} (unsaved)\n", .{arg});
    } else if (std.mem.eql(u8, verb, "port")) {
        const arg = words.next() orelse "";
        const port = std.fmt.parseInt(u16, arg, 10) catch 0;
        if (port == 0) {
            print("port: 1..65535\n", .{});
        } else {
            hookPortChanged(&g, port);
            g.app.syncPortText();
            g.settings.markDirty();
            print("port set to {d}\n", .{port});
        }
    } else if (std.mem.eql(u8, verb, "save")) {
        saveConfig() catch |err| {
            print("save failed: {s}\n", .{@errorName(err)});
            return false;
        };
        print("saved to {s}\n", .{g.config_path});
    } else {
        print("unknown command '{s}'; type 'help'\n", .{verb});
    }
    return false;
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.File.stdout().writeStreamingAll(g.io, text) catch {};
}

fn printHelp() void {
    print(
        \\commands:
        \\  status                 server + counters snapshot
        \\  start|stop|restart      proxy lifecycle
        \\  models [query]         model catalog table (optional search)
        \\  search <text>          set catalog search (empty clears)
        \\  clearsearch            clear catalog search
        \\  filter <name>          all|healthy|cooldown|dead|unknown
        \\  console                color-coded log tail
        \\  settings               settings panel snapshot
        \\  cooldown <secs>        5..3600 (restart proxy to apply)
        \\  timeout <ms>           1000..300000 (restart proxy to apply)
        \\  autostart on|off       launch proxy at startup
        \\  port <n>               1..65535 (restarts proxy if running)
        \\  save                   persist config now
        \\  quit                   graceful shutdown (also persists config)
        \\
    , .{});
}

fn printStatus() void {
    const snap = g.metrics.snapshot();
    var keys: usize = 0;
    var enabled: usize = 0;
    for (g.config.providers) |*provider| {
        for (provider.keys) |*key| {
            keys += 1;
            if (key.enabled) enabled += 1;
        }
    }
    const uptime_s = @divFloor(realtimeMillis() - g.start_ms, 1000);
    print("server: {s} on 127.0.0.1:{d} (uptime {d}s)\n", .{
        if (g.proxy_started.load(.acquire)) "RUNNING" else "STOPPED",
        g.config.port,
        uptime_s,
    });
    print("providers: {d}  keys: {d} ({d} enabled)\n", .{ g.config.providers.len, keys, enabled });
    print("requests: {d} served, {d} in flight, {d} errors, {d} failovers\n", .{
        snap.total_requests,
        snap.active_inflight,
        snap.total_errors,
        snap.total_failovers,
    });
    print("shell: tab={s} served={d} active-providers={d} healthy-keys={d}\n", .{
        @tagName(g.app.active_tab),
        g.app.metrics.total_requests,
        g.app.metrics.active_providers,
        g.app.metrics.healthy_keys,
    });
    print("settings: {s}\n", .{if (g.settings.dirty) "unsaved changes" else "in sync"});
    print("config: {s}\n", .{g.config_path});
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() !void {
    var debug_alloc = std.heap.DebugAllocator(.{}){};
    defer _ = debug_alloc.deinit();
    const alloc = debug_alloc.allocator();

    // App-owned I/O pool: file, stdio, and sleep calls on every thread go
    // through this. Joined (stdin thread) before it is deinitialized: the
    // stdin join is deferred later, so it runs first.
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();

    g.log = logger_mod.Logger.init();
    g.metrics = metrics_mod.Metrics.init();
    g.alloc = alloc;
    g.io = threaded.io();

    // Snapshot the OS environment once; config.zig resolves the OS-standard
    // path from it. The resolved path is a dupe, so the map is short-lived.
    // Windows exposes the process environment via the PEB global block;
    // POSIX reads the libc `environ` array (libc is linked on those targets).
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
    g.models_view = models_console.ModelsView.init(alloc);
    g.dashboard_view = views_dashboard.DashboardView.init(alloc, &g.log, g.config.port);
    g.providers_view = views_providers.ProvidersView.init(alloc);
    g.console_view = models_console.ConsoleView.init(alloc, &g.log);
    g.settings = models_console.SettingsState.initFromConfig(&g.config);
    g.rot = if (comptime have_rotator) null else .{};
    if (comptime have_proxy) {
        g.server = null;
    } else {
        g.server = 0;
    }
    g.proxy_started = std.atomic.Value(bool).init(false);
    g.shutdown = std.atomic.Value(bool).init(false);
    g.state_mutex = .{};
    g.start_ms = realtimeMillis();
    g.last_autosave_ms = g.start_ms;

    g.app = app_ui.App.init(alloc, &g.config);
    g.app.setViews(.{
        .dashboard = renderDashboard,
        .providers = renderProviders,
        .models = renderModelsView,
        .console_settings = renderConsoleSettings,
    });
    g.app.setHooks(.{
        .context = @ptrCast(&g),
        .start_fn = hookStart,
        .stop_fn = hookStop,
        .port_changed_fn = hookPortChanged,
    });
    g.metrics.setProviderCount(g.config.providers.len);
    g.metrics.restoreConfig(g.config);

    g.log.info("freepro starting (config: {s})", .{g.config_path});
    initRotator();

    if (g.config.auto_start) {
        if (!hookStart(&g, g.config.port)) {
            g.log.warn("auto-start failed; type 'start' to retry", .{});
        }
    } else {
        g.log.info("auto-start off; type 'start' to launch the proxy, 'help' for commands", .{});
    }

    var stdin_thread = try std.Thread.spawn(.{}, stdinThreadMain, .{});
    defer stdin_thread.join();

    // Foreground GUI loop: refresh view state, render one frame, autosave.
    while (!g.shutdown.load(.acquire)) {
        g.state_mutex.lock();
        g.dashboard_view.port = g.config.port;
        g.dashboard_view.server_running = g.proxy_started.load(.acquire);
        g.dashboard_view.refresh(g.config.providers, &g.metrics);
        g.models_view.refresh(g.config.providers) catch |err| {
            g.log.err("catalog refresh failed: {s}", .{@errorName(err)});
        };
        g.console_view.poll();
        g.app.render(app_ui.nullUi());
        g.state_mutex.unlock();

        if (g.settings.dirty and
            realtimeMillis() - g.last_autosave_ms >= autosave_interval_ms)
        {
            g.last_autosave_ms = realtimeMillis();
            saveConfig() catch |err| {
                g.log.warn("autosave failed: {s}", .{@errorName(err)});
            };
        }
        std.Io.sleep(g.io, frame_delay, .awake) catch {};
    }

    // Graceful shutdown: stop listener, join workers, persist, free.
    stopProxy();
    deinitRotator();
    saveConfig() catch |err| {
        std.debug.print("final config save failed: {s}\n", .{@errorName(err)});
    };
    g.console_view.deinit();
    g.dashboard_view.deinit();
    g.providers_view.deinit();
    g.models_view.deinit();
    g.app.deinit();
    g.config.deinit(alloc);
    alloc.free(g.config_path);
}

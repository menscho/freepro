// src/ui/app.zig — freepro native UI shell (window lifecycle, theme, chrome).
//
// Owner: Wave1-Task08 shell agent. This file owns ONLY the application shell:
// window init/deinit, dark theme palette, top bar, tab navigation, per-frame
// render dispatch, responsive layout, and stub views behind function pointers
// so other agents' view files (dashboard/providers/models/console) can plug in.
//
// DEPENDENCY NOTE (build stays green without third-party libs):
// This module is std-only and compiles with `zig build-exe src/main.zig`
// today. Real pixels come from a DVUI backend (pure Zig, no Electron) wired
// in build.zig by the build owner:
//
//   const dvui_dep = b.dependency("dvui", .{ .target = target, .optimize = optimize });
//   exe.root_module.addImport("dvui", dvui_dep.module("dvui"));
//
// A DVUI backend implements `Ui.VTable` below (beginFrame/endFrame,
// row/column containers, label/button/textBox/dot/clipboard/size) on top of
// `dvui` + its SDL/window backend, constructs `Ui{ .ptr, .vtable }`, owns the
// OS window, and calls `render(root, app)` once per frame. Until then,
// `nullUi()` provides a headless no-op backend used for smoke checks.
//
// Typography: DVUI renders with the OS system font stack and subpixel
// hinting; `Theme.font_scale` multiplies every size step. The backend should
// multiply `font_scale` by the OS DPI factor in beginFrame so text stays
// smooth on HiDPI displays. Layout uses `Layout.forWidth` so the top bar and
// tabs wrap gracefully on narrow windows.
//
// Shared contracts assumed (owned by the models agent, src/models.zig):
//   Key{ key, state (enum with Active|CoolingDown|Dead), last_used,
//        cooldown_until, consecutive_errors, enabled }
//   Provider{ display_name, base_url, prefix, description, keys, headers }
//   CustomHeader{ key, value }
//   ProxyConfig{ port (default 54321), providers (slice or ArrayList),
//                auto_start, cooldown_secs (default 60), timeout_ms }
// Field access below goes through small duck-typed helpers so both a slice
// and a std.ArrayList work for `providers`/`keys`, and key health is matched
// on the state's tag name so the enum's type name may vary.

const std = @import("std");
const models = @import("../models.zig");

pub const loopback: []const u8 = "127.0.0.1";
pub const default_port: u16 = 54321;
pub const default_cooldown_secs: u64 = 60;

/// Primary navigation tabs. Order here is the tab-bar order.
pub const Tab = enum(u8) {
    dashboard,
    providers,
    models,
    console_settings,

    pub const all: [4]Tab = .{ .dashboard, .providers, .models, .console_settings };

    pub fn title(self: Tab) []const u8 {
        return switch (self) {
            .dashboard => "Dashboard",
            .providers => "Providers",
            .models => "Models",
            .console_settings => "Console+Settings",
        };
    }
};

/// Server lifecycle as shown in the top bar.
pub const ServerStatus = enum {
    stopped,
    running,

    pub fn badge(self: ServerStatus) []const u8 {
        return switch (self) {
            .stopped => "STOPPED",
            .running => "RUNNING",
        };
    }
};

/// RGBA color in the shell palette.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const green = Color{ .r = 0x3D, .g = 0xD6, .b = 0x7A };
    pub const yellow = Color{ .r = 0xE5, .g = 0xC0, .b = 0x07 };
    pub const red = Color{ .r = 0xE5, .g = 0x48, .b = 0x4B };
    pub const accent = Color{ .r = 0x6E, .g = 0x9E, .b = 0xFF };
    pub const muted = Color{ .r = 0x9A, .g = 0xA3, .b = 0xB2 };
};

/// Dark-mode palette plus spacing/typography knobs shared by all views.
pub const Theme = struct {
    bg: Color = .{ .r = 0x14, .g = 0x16, .b = 0x1B },
    surface: Color = .{ .r = 0x1D, .g = 0x20, .b = 0x27 },
    surface2: Color = .{ .r = 0x25, .g = 0x29, .b = 0x33 },
    border: Color = .{ .r = 0x32, .g = 0x37, .b = 0x43 },
    text: Color = .{ .r = 0xEC, .g = 0xEF, .b = 0xF3 },
    text_dim: Color = .{ .r = 0x9A, .g = 0xA3, .b = 0xB2 },
    /// Multiplier applied to every font size; backend multiplies by OS DPI.
    font_scale: f32 = 1.0,
    rounding: f32 = 8.0,
    spacing: f32 = 8.0,
};

pub const dark_theme: Theme = .{};

/// Responsive breakpoint. Wide windows show the top bar on one row and
/// multi-column view bodies; narrow windows stack vertically.
pub const Layout = enum {
    wide,
    narrow,

    pub fn forWidth(width_px: f32) Layout {
        return if (width_px < 760.0) .narrow else .wide;
    }
};

pub const Size = struct {
    w: f32,
    h: f32,
};

/// Backend-agnostic immediate-mode widget interface, one call per frame.
/// A DVUI backend implements each entry with real widgets; `nullUi()` drops
/// everything so the shell can run headless in smoke checks.
pub const Ui = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginFrame: *const fn (ptr: *anyopaque, width: f32, height: f32) void,
        endFrame: *const fn (ptr: *anyopaque) void,
        frameSize: *const fn (ptr: *anyopaque) Size,
        beginRow: *const fn (ptr: *anyopaque) void,
        endRow: *const fn (ptr: *anyopaque) void,
        beginCol: *const fn (ptr: *anyopaque) void,
        endCol: *const fn (ptr: *anyopaque) void,
        label: *const fn (ptr: *anyopaque, text: []const u8) void,
        button: *const fn (ptr: *anyopaque, text: []const u8) bool,
        /// Single-line edit of `buf[0..len.*]`; returns true when edited.
        textBox: *const fn (ptr: *anyopaque, buf: []u8, len: *usize) bool,
        dot: *const fn (ptr: *anyopaque, color: Color) void,
        copyToClipboard: *const fn (ptr: *anyopaque, text: []const u8) void,
    };

    pub fn beginFrame(self: Ui, width: f32, height: f32) void {
        self.vtable.beginFrame(self.ptr, width, height);
    }
    pub fn endFrame(self: Ui) void {
        self.vtable.endFrame(self.ptr);
    }
    pub fn frameSize(self: Ui) Size {
        return self.vtable.frameSize(self.ptr);
    }
    pub fn beginRow(self: Ui) void {
        self.vtable.beginRow(self.ptr);
    }
    pub fn endRow(self: Ui) void {
        self.vtable.endRow(self.ptr);
    }
    pub fn beginCol(self: Ui) void {
        self.vtable.beginCol(self.ptr);
    }
    pub fn endCol(self: Ui) void {
        self.vtable.endCol(self.ptr);
    }
    pub fn label(self: Ui, text: []const u8) void {
        self.vtable.label(self.ptr, text);
    }
    /// Returns true exactly on the frame the button is activated.
    pub fn button(self: Ui, text: []const u8) bool {
        return self.vtable.button(self.ptr, text);
    }
    pub fn textBox(self: Ui, buf: []u8, len: *usize) bool {
        return self.vtable.textBox(self.ptr, buf, len);
    }
    pub fn dot(self: Ui, color: Color) void {
        self.vtable.dot(self.ptr, color);
    }
    pub fn copyToClipboard(self: Ui, text: []const u8) void {
        self.vtable.copyToClipboard(self.ptr, text);
    }
};

const NullState = struct {};

fn nullBeginFrame(_: *anyopaque, _: f32, _: f32) void {}
fn nullEndFrame(_: *anyopaque) void {}
fn nullFrameSize(_: *anyopaque) Size {
    return .{ .w = 1280, .h = 800 };
}
fn nullBeginRow(_: *anyopaque) void {}
fn nullEndRow(_: *anyopaque) void {}
fn nullBeginCol(_: *anyopaque) void {}
fn nullEndCol(_: *anyopaque) void {}
fn nullLabel(_: *anyopaque, _: []const u8) void {}
fn nullButton(_: *anyopaque, _: []const u8) bool {
    return false;
}
fn nullTextBox(_: *anyopaque, _: []u8, _: *usize) bool {
    return false;
}
fn nullDot(_: *anyopaque, _: Color) void {}
fn nullCopy(_: *anyopaque, _: []const u8) void {}

const null_vtable: Ui.VTable = .{
    .beginFrame = nullBeginFrame,
    .endFrame = nullEndFrame,
    .frameSize = nullFrameSize,
    .beginRow = nullBeginRow,
    .endRow = nullEndRow,
    .beginCol = nullBeginCol,
    .endCol = nullEndCol,
    .label = nullLabel,
    .button = nullButton,
    .textBox = nullTextBox,
    .dot = nullDot,
    .copyToClipboard = nullCopy,
};

var null_state: NullState = .{};

/// Headless backend: renders nothing, clicks nothing. Used for smoke checks
/// and as the default before the window backend attaches.
pub fn nullUi() Ui {
    return .{ .ptr = &null_state, .vtable = &null_vtable };
}

/// Aggregated counters shown on the Dashboard metric cards. Key/provider
/// counts are recomputed from ProxyConfig by refresh; request counters are
/// bumped by the proxy agent via recordRequestStart/recordRequestServed.
pub const Metrics = struct {
    active_providers: usize = 0,
    total_keys: usize = 0,
    healthy_keys: usize = 0,
    active_requests: u32 = 0,
    total_requests: u64 = 0,
};

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,
};

/// Minimal spin mutex over `std.atomic` so the shell builds on Zig 0.13.x
/// and newer toolchains alike without chasing std sync moves.
const SpinLock = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinLock) void {
        while (self.flag.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

/// Fixed-capacity thread-safe ring log feeding the Console view.
/// Oldest entry is overwritten when full; never allocates after init.
pub const MemoryLog = struct {
    const capacity: usize = 64;
    const line_len: usize = 160;

    mutex: SpinLock = .{},
    lines: [capacity][line_len]u8 = [_][line_len]u8{[_]u8{0} ** line_len} ** capacity,
    lens: [capacity]usize = [_]usize{0} ** capacity,
    levels: [capacity]LogLevel = [_]LogLevel{.info} ** capacity,
    head: usize = 0,
    count: usize = 0,

    pub fn log(self: *MemoryLog, level: LogLevel, msg: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = self.head;
        const n = @min(msg.len, line_len);
        @memcpy(self.lines[slot][0..n], msg[0..n]);
        self.lens[slot] = n;
        self.levels[slot] = level;
        self.head = (self.head + 1) % capacity;
        self.count = @min(self.count + 1, capacity);
    }

    pub const Entry = struct {
        level: LogLevel,
        text: []const u8,
    };

    /// Oldest-first read: index 0 is the oldest retained entry.
    pub fn get(self: *MemoryLog, index: usize) ?Entry {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.count) return null;
        const slot = (self.head + capacity - self.count + index) % capacity;
        return .{ .level = self.levels[slot], .text = self.lines[slot][0..self.lens[slot]] };
    }

    pub fn len(self: *MemoryLog) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count;
    }
};

/// Hooks the proxy agent installs so the top-bar toggle controls the real
/// listener. All hooks are optional; without them the toggle only flips the
/// displayed status (useful for UI development).
pub const ServerHooks = struct {
    context: ?*anyopaque = null,
    start_fn: ?*const fn (context: ?*anyopaque, port: u16) bool = null,
    stop_fn: ?*const fn (context: ?*anyopaque) void = null,
    port_changed_fn: ?*const fn (context: ?*anyopaque, port: u16) void = null,
};

/// One render function per tab. View files owned by other agents assign
/// real implementations via `App.setViews`; unset tabs draw a stub card.
pub const ViewFn = *const fn (app: *App, root: Ui) void;

pub const Views = struct {
    dashboard: ?ViewFn = null,
    providers: ?ViewFn = null,
    models: ?ViewFn = null,
    console_settings: ?ViewFn = null,
};

/// Application shell state. `config` is borrowed (owned by main/config
/// agent); `allocator` is retained for owned formatting helpers only.
pub const App = struct {
    allocator: std.mem.Allocator,
    config: *models.ProxyConfig,
    theme: Theme = dark_theme,
    status: ServerStatus = .stopped,
    active_tab: Tab = .dashboard,
    layout: Layout = .wide,
    hooks: ServerHooks = .{},
    views: Views = .{},
    metrics: Metrics = .{},
    log: MemoryLog = .{},

    port_text: [8]u8 = [_]u8{0} ** 8,
    port_len: usize = 0,
    port_error: bool = false,
    status_text: [160]u8 = [_]u8{0} ** 160,
    status_len: usize = 0,

    const Self = @This();

    /// Borrow `config`; reflect its port in the port input field and derive
    /// initial metrics. Call `deinit` on shutdown to stop the server hook.
    pub fn init(allocator: std.mem.Allocator, config: *models.ProxyConfig) Self {
        var app: Self = .{ .allocator = allocator, .config = config };
        app.syncPortText();
        if (config.auto_start) app.status = .running;
        app.refreshMetrics();
        return app;
    }

    /// Window shutdown: stop the listener through the installed hook and
    /// mark the shell stopped. `config` remains owned by the caller.
    pub fn deinit(self: *Self) void {
        if (self.status == .running) {
            if (self.hooks.stop_fn) |stop| stop(self.hooks.context);
        }
        self.status = .stopped;
        self.hooks = .{};
        self.views = .{};
    }

    pub fn setViews(self: *Self, views: Views) void {
        self.views = views;
    }

    pub fn setHooks(self: *Self, hooks: ServerHooks) void {
        self.hooks = hooks;
    }

    pub fn switchTab(self: *Self, tab: Tab) void {
        self.active_tab = tab;
    }

    pub fn isRunning(self: *const Self) bool {
        return self.status == .running;
    }

    /// Start/Stop toggle shared by the top-bar button. Returns the new status.
    pub fn toggleServer(self: *Self) ServerStatus {
        if (self.status == .running) {
            if (self.hooks.stop_fn) |stop| stop(self.hooks.context);
            self.status = .stopped;
            self.setStatus("Proxy stopped.", .{});
            self.log.log(.warn, "proxy stopped from top bar");
        } else {
            var ok = true;
            if (self.hooks.start_fn) |start| ok = start(self.hooks.context, self.config.port);
            self.status = if (ok) .running else .stopped;
            if (ok) {
                self.setStatus("Proxy running on {s}:{d}.", .{ loopback, self.config.port });
                self.log.log(.info, "proxy started from top bar");
            } else {
                self.setStatus("Proxy failed to start.", .{});
                self.log.log(.err, "proxy failed to start from top bar");
            }
        }
        return self.status;
    }

    /// Copy of the configured port as editable text; called after external
    /// config loads so the input field shows the truth.
    pub fn syncPortText(self: *Self) void {
        const text = std.fmt.bufPrint(self.port_text[0..], "{d}", .{self.config.port}) catch {
            self.port_text[0] = '8';
            self.port_text[1] = '0';
            self.port_text[2] = '8';
            self.port_text[3] = '0';
            self.port_len = 4;
            return;
        };
        self.port_len = text.len;
        self.port_error = false;
    }

    /// Validate the port input and apply it to config. Keeps the old port
    /// and flags `port_error` on invalid input.
    pub fn applyPort(self: *Self) bool {
        const raw = self.port_text[0..self.port_len];
        const port = std.fmt.parseInt(u16, raw, 10) catch {
            self.port_error = true;
            self.setStatus("Invalid port '{s}': use 1-65535.", .{raw});
            return false;
        };
        if (port == 0) {
            self.port_error = true;
            self.setStatus("Invalid port '0': use 1-65535.", .{});
            return false;
        }
        self.config.port = port;
        self.port_error = false;
        if (self.hooks.port_changed_fn) |changed| changed(self.hooks.context, port);
        self.setStatus("Port set to {d}.", .{port});
        return true;
    }

    /// Format "http://127.0.0.1:<port>/v1" into `buf`. Owned-buffer variant
    /// for non-frame code paths; frame code should use `copyBaseUrl`.
    pub fn baseUrlAlloc(self: *Self, extra_path: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "http://{s}:{d}/v1{s}", .{ loopback, self.config.port, extra_path });
    }

    /// Copy the base URL to the clipboard and confirm in the status line.
    pub fn copyBaseUrl(self: *Self, ui: Ui) void {
        var buf: [64]u8 = undefined;
        const url = std.fmt.bufPrint(&buf, "http://{s}:{d}/v1", .{ loopback, self.config.port }) catch {
            self.setStatus("Base URL too long to copy.", .{});
            return;
        };
        ui.copyToClipboard(url);
        self.setStatus("Copied {s}", .{url});
    }

    pub fn setStatus(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(self.status_text[0..], fmt, args) catch {
            const fallback = "(status truncated)";
            @memcpy(self.status_text[0..fallback.len], fallback);
            self.status_len = fallback.len;
            return;
        };
        self.status_len = text.len;
    }

    pub fn statusText(self: *const Self) []const u8 {
        return self.status_text[0..self.status_len];
    }

    pub fn recordRequestStart(self: *Self) void {
        self.metrics.active_requests += 1;
    }

    pub fn recordRequestServed(self: *Self) void {
        self.metrics.active_requests -|= 1;
        self.metrics.total_requests += 1;
    }

    /// Recompute provider/key counters from the borrowed config. A provider
    /// counts as active only while it holds at least one healthy key, matching
    /// the Dashboard card definition ("providers with a usable key").
    pub fn refreshMetrics(self: *Self) void {
        var providers: usize = 0;
        var total: usize = 0;
        var healthy: usize = 0;
        for (providerSlice(self.config)) |*provider| {
            var healthy_here: usize = 0;
            for (keySlice(provider)) |*k| {
                total += 1;
                if (keyIsHealthy(k)) {
                    healthy += 1;
                    healthy_here += 1;
                }
            }
            if (healthy_here > 0) providers += 1;
        }
        self.metrics.active_providers = providers;
        self.metrics.total_keys = total;
        self.metrics.healthy_keys = healthy;
    }

    /// Per-frame entry point: `root` is the window's root widget/backend,
    /// `state` is this shell. Draws top bar, tab nav, then the active view.
    pub fn render(self: *Self, root: Ui) void {
        renderFrame(root, self);
    }

    fn renderTopBar(self: *Self, ui: Ui) void {
        const wide = self.layout == .wide;
        if (wide) ui.beginRow() else ui.beginCol();

        switch (self.status) {
            .running => ui.dot(Color.green),
            .stopped => ui.dot(Color.red),
        }

        var addr_buf: [48]u8 = undefined;
        const addr = std.fmt.bufPrint(&addr_buf, "{s} on {s}:{d}", .{
            self.status.badge(),
            loopback,
            self.config.port,
        }) catch "RUNNING";
        ui.label(addr);

        const toggle_text = if (self.status == .running) "Stop" else "Start";
        if (ui.button(toggle_text)) _ = self.toggleServer();

        if (!wide) {
            ui.beginRow();
        }
        ui.label("Port:");
        if (ui.textBox(self.port_text[0..], &self.port_len)) self.port_error = false;
        if (ui.button("Apply")) _ = self.applyPort();
        if (self.port_error) ui.label("port: 1-65535");
        if (ui.button("Copy Base URL")) self.copyBaseUrl(ui);
        if (!wide) {
            ui.endRow();
        }

        if (wide) ui.endRow() else ui.endCol();
    }

    fn renderTabs(self: *Self, ui: Ui) void {
        ui.beginRow();
        for (Tab.all) |tab| {
            var name_buf: [32]u8 = undefined;
            const name = if (tab == self.active_tab)
                std.fmt.bufPrint(&name_buf, "[{s}]", .{tab.title()}) catch tab.title()
            else
                tab.title();
            if (ui.button(name)) self.switchTab(tab);
        }
        ui.endRow();
    }

    fn renderActiveView(self: *Self, ui: Ui) void {
        ui.beginCol();
        switch (self.active_tab) {
            .dashboard => if (self.views.dashboard) |view| view(self, ui) else stubView(
                self,
                ui,
                "Dashboard",
                "Metric cards, traffic sparkline, activity feed.",
            ),
            .providers => if (self.views.providers) |view| view(self, ui) else stubView(
                self,
                ui,
                "Providers",
                "Provider cards, bulk key import, header editor.",
            ),
            .models => if (self.views.models) |view| view(self, ui) else stubView(
                self,
                ui,
                "Models",
                "Merged model catalog with search and filter.",
            ),
            .console_settings => if (self.views.console_settings) |view| view(self, ui) else stubView(
                self,
                ui,
                "Console+Settings",
                "Live request log, auto-start, cooldown, timeouts.",
            ),
        }
        ui.endCol();
    }
};

/// Alias so other agents can name the shell state either `App` or `AppState`.
pub const AppState = App;

/// Free-function frame entry so call sites can read `render(root, state)`.
pub fn renderFrame(root: Ui, state: *App) void {
    const size = root.frameSize();
    root.beginFrame(size.w, size.h);
    state.layout = Layout.forWidth(size.w);
    state.renderTopBar(root);
    state.renderTabs(root);
    state.renderActiveView(root);
    if (state.status_len > 0) root.label(state.statusText());
    state.refreshMetrics();
    root.endFrame();
}

/// Default card drawn for tabs whose view file has not been plugged in yet.
/// View owners replace this by assigning `App.views.<tab>` in main.
fn stubView(app: *App, ui: Ui, name: []const u8, blurb: []const u8) void {
    _ = app;
    ui.beginCol();
    ui.label(name);
    ui.label(blurb);
    ui.endCol();
}

/// Accept either `[]Provider` or `std.ArrayList(Provider)` for providers.
fn providerSlice(config: *models.ProxyConfig) []models.Provider {
    const info = @typeInfo(@TypeOf(config.providers));
    switch (info) {
        .pointer => return config.providers,
        .@"struct" => return config.providers.items,
        else => @compileError("ProxyConfig.providers must be a slice or ArrayList"),
    }
}

/// Accept either `[]Key` or `std.ArrayList(Key)` for a provider's key pool.
fn keySlice(provider: *models.Provider) []models.Key {
    const info = @typeInfo(@TypeOf(provider.keys));
    switch (info) {
        .pointer => return provider.keys,
        .@"struct" => return provider.keys.items,
        else => @compileError("Provider.keys must be a slice or ArrayList"),
    }
}

/// A key counts as healthy when enabled and its state tag is "Active".
/// Matched by tag name so the enum's type name may vary across agents.
fn keyIsHealthy(k: *const models.Key) bool {
    if (!k.enabled) return false;
    return std.mem.eql(u8, @tagName(k.state), "Active");
}

// ---------------------------------------------------------------------------
// Unit tests (headless: nullUi backend, no window, no network)
// ---------------------------------------------------------------------------

const TestHookCtx = struct {
    starts: u32 = 0,
    stops: u32 = 0,
    last_port: u16 = 0,
    fail_start: bool = false,
};

fn testHookStart(ctx: ?*anyopaque, port: u16) bool {
    const c: *TestHookCtx = @ptrCast(@alignCast(ctx.?));
    c.starts += 1;
    c.last_port = port;
    return !c.fail_start;
}

fn testHookStop(ctx: ?*anyopaque) void {
    const c: *TestHookCtx = @ptrCast(@alignCast(ctx.?));
    c.stops += 1;
}

fn testHookPortChanged(ctx: ?*anyopaque, port: u16) void {
    const c: *TestHookCtx = @ptrCast(@alignCast(ctx.?));
    c.last_port = port;
}

var test_view_calls: [4]u32 = .{ 0, 0, 0, 0 };

fn testViewDashboard(app: *App, root: Ui) void {
    _ = app;
    _ = root;
    test_view_calls[0] += 1;
}

fn testViewProviders(app: *App, root: Ui) void {
    _ = app;
    _ = root;
    test_view_calls[1] += 1;
}

fn testViewModels(app: *App, root: Ui) void {
    _ = app;
    _ = root;
    test_view_calls[2] += 1;
}

fn testViewConsole(app: *App, root: Ui) void {
    _ = app;
    _ = root;
    test_view_calls[3] += 1;
}

fn testApp(allocator: std.mem.Allocator, cfg: *models.ProxyConfig) App {
    return App.init(allocator, cfg);
}

test "shell port text syncs, validates, and applies" {
    const t = std.testing;
    var cfg = try models.ProxyConfig.defaultConfig(t.allocator);
    defer cfg.deinit(t.allocator);
    var app = testApp(t.allocator, &cfg);
    defer app.deinit();

    try t.expectEqualStrings("54321", app.port_text[0..app.port_len]);
    try t.expect(!app.port_error);

    @memcpy(app.port_text[0..3], "abc");
    app.port_len = 3;
    try t.expect(!app.applyPort());
    try t.expect(app.port_error);
    try t.expectEqual(@as(u16, 54321), cfg.port);

    @memcpy(app.port_text[0..1], "0");
    app.port_len = 1;
    try t.expect(!app.applyPort());
    try t.expectEqual(@as(u16, 54321), cfg.port);

    @memcpy(app.port_text[0..4], "9090");
    app.port_len = 4;
    try t.expect(app.applyPort());
    try t.expect(!app.port_error);
    try t.expectEqual(@as(u16, 9090), cfg.port);

    app.syncPortText();
    try t.expectEqualStrings("9090", app.port_text[0..app.port_len]);
}

test "shell server toggle flips status with and without hooks" {
    const t = std.testing;
    var cfg = try models.ProxyConfig.defaultConfig(t.allocator);
    defer cfg.deinit(t.allocator);

    // No hooks: toggle only flips the displayed status.
    var app = testApp(t.allocator, &cfg);
    defer app.deinit();
    try t.expect(!app.isRunning());
    try t.expectEqual(ServerStatus.running, app.toggleServer());
    try t.expect(app.isRunning());
    try t.expectEqual(ServerStatus.stopped, app.toggleServer());

    // Failing start hook keeps the shell stopped.
    var ctx = TestHookCtx{ .fail_start = true };
    var app2 = testApp(t.allocator, &cfg);
    defer app2.deinit();
    app2.setHooks(.{
        .context = @ptrCast(&ctx),
        .start_fn = testHookStart,
        .stop_fn = testHookStop,
        .port_changed_fn = testHookPortChanged,
    });
    try t.expectEqual(ServerStatus.stopped, app2.toggleServer());
    try t.expectEqual(@as(u32, 1), ctx.starts);

    // Healthy hook: start applies the port, stop runs on deinit.
    ctx.fail_start = false;
    try t.expectEqual(ServerStatus.running, app2.toggleServer());
    try t.expectEqual(@as(u16, 54321), ctx.last_port);
    _ = app2.applyPort();
    app2.deinit();
    try t.expectEqual(@as(u32, 1), ctx.stops);
    try t.expectEqual(ServerStatus.stopped, app2.status);
}

test "shell metrics recompute from provider key pools" {
    const t = std.testing;
    var cfg = try models.ProxyConfig.defaultConfig(t.allocator);
    defer cfg.deinit(t.allocator);
    var app = testApp(t.allocator, &cfg);
    defer app.deinit();

    // Preset pools are empty: no providers active, no keys.
    try t.expectEqual(@as(usize, 0), app.metrics.active_providers);
    try t.expectEqual(@as(usize, 0), app.metrics.total_keys);

    var stack_keys = [_]models.Key{
        .{ .key = "k1" },
        .{ .key = "k2", .state = .CoolingDown },
        .{ .key = "k3", .enabled = false },
    };
    const saved = cfg.providers[0].keys;
    cfg.providers[0].keys = &stack_keys;
    defer cfg.providers[0].keys = saved;
    app.refreshMetrics();
    try t.expectEqual(@as(usize, 1), app.metrics.active_providers);
    try t.expectEqual(@as(usize, 3), app.metrics.total_keys);
    try t.expectEqual(@as(usize, 1), app.metrics.healthy_keys);

    app.recordRequestStart();
    app.recordRequestStart();
    app.recordRequestServed();
    try t.expectEqual(@as(u32, 1), app.metrics.active_requests);
    try t.expectEqual(@as(u64, 1), app.metrics.total_requests);
    // Saturating decrement never underflows on extra completions.
    app.recordRequestServed();
    app.recordRequestServed();
    try t.expectEqual(@as(u32, 0), app.metrics.active_requests);
}

test "shell memory log keeps newest 64 lines oldest-first" {
    const t = std.testing;
    var log = MemoryLog{};
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 70) : (i += 1) {
        const line = try std.fmt.bufPrint(&buf, "line-{d:0>2}", .{i});
        log.log(.info, line);
    }
    try t.expectEqual(@as(usize, 64), log.len());
    try t.expectEqualStrings("line-06", log.get(0).?.text);
    try t.expectEqualStrings("line-69", log.get(63).?.text);
    try t.expect(log.get(64) == null);
    try t.expectEqual(LogLevel.info, log.get(0).?.level);
}

test "shell headless frame renders every tab with and without views" {
    const t = std.testing;
    var cfg = try models.ProxyConfig.defaultConfig(t.allocator);
    defer cfg.deinit(t.allocator);
    var app = testApp(t.allocator, &cfg);
    defer app.deinit();

    // No views plugged in: stub cards must not crash.
    for (Tab.all) |tab| {
        app.switchTab(tab);
        renderFrame(nullUi(), &app);
    }
    try t.expectEqual(Layout.wide, app.layout);
    try t.expectEqual(Tab.console_settings, app.active_tab);

    // Plugged views dispatch per tab exactly once per frame.
    test_view_calls = .{ 0, 0, 0, 0 };
    app.setViews(.{
        .dashboard = testViewDashboard,
        .providers = testViewProviders,
        .models = testViewModels,
        .console_settings = testViewConsole,
    });
    for (Tab.all) |tab| {
        app.switchTab(tab);
        app.render(nullUi());
    }
    try t.expectEqual([4]u32{ 1, 1, 1, 1 }, test_view_calls);
}

test "shell base url copy and alloc helpers agree" {
    const t = std.testing;
    var cfg = try models.ProxyConfig.defaultConfig(t.allocator);
    defer cfg.deinit(t.allocator);
    var app = testApp(t.allocator, &cfg);
    defer app.deinit();

    const owned = try app.baseUrlAlloc("/models");
    defer t.allocator.free(owned);
    try t.expectEqualStrings("http://127.0.0.1:54321/v1/models", owned);

    app.copyBaseUrl(nullUi());
    try t.expectEqualStrings("Copied http://127.0.0.1:54321/v1", app.statusText());
}

test "shell tabs, layout breakpoints, and status badges" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 4), Tab.all.len);
    try t.expectEqualStrings("Dashboard", Tab.dashboard.title());
    try t.expectEqualStrings("Providers", Tab.providers.title());
    try t.expectEqualStrings("Models", Tab.models.title());
    try t.expectEqualStrings("Console+Settings", Tab.console_settings.title());
    try t.expectEqual(Layout.narrow, Layout.forWidth(759.9));
    try t.expectEqual(Layout.wide, Layout.forWidth(760.0));
    try t.expectEqualStrings("STOPPED", ServerStatus.stopped.badge());
    try t.expectEqualStrings("RUNNING", ServerStatus.running.badge());
    try t.expectEqualStrings("127.0.0.1", loopback);
    try t.expectEqual(@as(u16, 54321), default_port);
}

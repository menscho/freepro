// src/dashboard.zig
//
// freepro local HTTP dashboard + JSON API (Wave 3).
//
// This file is owned by the dashboard agent. It plugs into src/proxy.zig via
// the DashboardHook surface (ProxyOptions.dashboard, dispatched first in
// routeRequest): returning non-null means fully handled, null falls through
// to the proxy's own routes. proxy.zig is never modified from here.
//
// Wiring (gui_main owns the rest):
//   var ctl = dashboard.Controller.init(alloc, io, &config, path, &log, &metrics, &proxy);
//   ctl.stop_fn = ...; ctl.start_fn = ...; (see fields below)
//   proxy.dashboard = ctl.hook();
// The hook runs on proxy worker threads. Config mutation goes through one
// shared applier (applyChange): stop, drain, mutate, validate, save,
// reinit-rotator-on-count-change, restart. Reads take Controller.mu briefly;
// the applier holds it only across mutate, validate and save.
//
// Response JSON shapes:
//   GET  /api/status            {running,port,bound_port,in_flight,total_served,
//                               providers,total_keys,healthy_keys,avg_latency_ms,
//                               total_errors,total_failovers}
//   POST /api/server            {action:start|stop} -> {running,port}
//   GET  /api/providers         {providers:[provider,...]}
//   POST /api/providers         {display_name,base_url,prefix[,description,headers]}
//                               -> 201 provider (prefix auto-gains trailing "/")
//   GET/PUT/DELETE /api/providers/{i}  (PUT keeps existing keys)
//   POST /api/providers/{i}/keys  {keys:[...]} and/or {key:"..."} -> {added,total}
//   DELETE/PATCH .../keys/{k}    (PATCH {enabled:bool} in place)
//   POST .../ping/{k}            -> {ok,status,latency_ms,models:[ids]}
//   GET/POST .../headers         POST {key,value} -> 201 {index,key,value}
//   GET/PUT/DELETE .../headers/{h}
//   GET  /api/models            {"object":"list","data":[{id,object,created,owned_by}]}
//   GET  /api/logs[/<n>]        {logs:[{seq,timestamp_ms,level,msg}],count}
//   GET/PUT /api/settings       {port,auto_start,cooldown_secs,timeout_ms} (PUT partial)
//
// Key material never leaves this file unmasked: provider payloads carry a
// masked key id plus state only. Inbound paths are query-stripped by proxy.zig,
// so GET /api/logs takes its count from /api/logs/<n> (default 100, cap 512).

const std = @import("std");
const builtin = @import("builtin");
const models = @import("models.zig");
const logger_mod = @import("logger.zig");
const metrics_mod = @import("metrics.zig");
const proxy_mod = @import("proxy.zig");
const freeproxy = @import("freeproxy.zig");
const config_mod = @import("config.zig");
const upstream = @import("upstream.zig");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Mutex + wall clock shims (same approach as logger.zig / proxy.zig)
// ---------------------------------------------------------------------------

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

fn posixClockMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divFloor(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn posixClockSec() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return ts.sec;
}

fn nowUnixSec() i64 {
    if (@hasDecl(std.time, "timestamp")) return std.time.timestamp();
    if (builtin.os.tag == .windows) {
        const ticks_100ns: i64 = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        return @divFloor(ticks_100ns, 10_000_000) - 11_644_473_600;
    }
    return posixClockSec();
}

fn nowUnixMs() i64 {
    if (@hasDecl(std.time, "milliTimestamp")) return std.time.milliTimestamp();
    if (builtin.os.tag == .windows) {
        const ticks_100ns: i64 = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        return @divFloor(ticks_100ns, 10_000) - 11_644_473_600_000;
    }
    return posixClockMs();
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

pub const Controller = struct {
    updater: ?*@import("updater.zig").Updater = null,
    kimi_config_path: []const u8 = "",
    quickadd_token: []const u8 = "",
    alloc: Allocator,
    io: std.Io,
    config: *models.ProxyConfig,
    /// Experimental free-proxy pool (may be null in headless mode).
    free_proxies: ?*freeproxy.Pool = null,
    config_path: []const u8,
    log: *logger_mod.Logger,
    metrics: *metrics_mod.Metrics,
    proxy: *proxy_mod.Proxy,
    /// Server control, wired by gui_main so this file never imports gui_main.
    /// Each takes the controller and defaults to the matching Proxy method
    /// when left null. Signatures are fixed here; gui_main adapts to them.
    stop_fn: ?*const fn (c: *Controller) void = null,
    start_fn: ?*const fn (c: *Controller) anyerror!void = null,
    is_running_fn: ?*const fn (c: *Controller) bool = null,
    in_flight_fn: ?*const fn (c: *Controller) usize = null,
    reinit_rotator_fn: ?*const fn (c: *Controller) void = null,
    /// Guards config reads and the mutate/validate/save section of the applier.
    mu: Mutex = .{},

    pub fn init(
        alloc: Allocator,
        io: std.Io,
        config: *models.ProxyConfig,
        config_path: []const u8,
        log: *logger_mod.Logger,
        metrics: *metrics_mod.Metrics,
        proxy: *proxy_mod.Proxy,
    ) Controller {
        return .{
            .alloc = alloc,
            .io = io,
            .config = config,
            .config_path = config_path,
            .log = log,
            .metrics = metrics,
            .proxy = proxy,
        };
    }

    pub fn hook(c: *Controller) proxy_mod.DashboardHook {
        return .{ .ctx = @ptrCast(c), .handle_fn = handle };
    }

    pub fn isRunning(c: *Controller) bool {
        if (c.is_running_fn) |f| return f(c);
        return c.proxy.isRunning();
    }

    /// Live connection count. The proxy counter includes the dashboard
    /// request itself; use othersInFlight() when the caller wants peers only.
    pub fn inFlight(c: *Controller) usize {
        if (c.in_flight_fn) |f| return f(c);
        return c.proxy.inFlightCount();
    }

    pub fn othersInFlight(c: *Controller) usize {
        const n = c.inFlight();
        return if (n > 0) n - 1 else 0;
    }

    pub fn stopServer(c: *Controller) void {
        if (c.stop_fn) |f| return f(c);
        c.proxy.stop();
    }

    pub fn startServer(c: *Controller) !void {
        if (c.start_fn) |f| return f(c);
        try c.proxy.start();
    }

    pub fn reinitRotator(c: *Controller) void {
        if (c.reinit_rotator_fn) |f| f(c);
    }
};

fn handle(
    ctx: *anyopaque,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    alloc: Allocator,
    writer: *std.Io.Writer,
) ?u16 {
    const c: *Controller = @ptrCast(@alignCast(ctx));
    return route(c, method, path, body, alloc, writer);
}

// ---------------------------------------------------------------------------
// Static assets (land via sibling agents; compile happens after all land)
// ---------------------------------------------------------------------------

const index_html: []const u8 = @embedFile("web/index.html");
const app_js: []const u8 = @embedFile("web/app.js");
const styles_css: []const u8 = @embedFile("web/styles.css");

// ---------------------------------------------------------------------------
// Response writers (mirror proxy.zig sendJson/sendStatus framing)
// ---------------------------------------------------------------------------

fn reasonPhrase(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        404 => "Not Found",
        409 => "Conflict",
        500 => "Internal Server Error",
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

fn sendStatic(writer: *std.Io.Writer, content_type: []const u8, body: []const u8) ?u16 {
    writer.print(
        "HTTP/1.1 200 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ reasonPhrase(200), content_type, body.len },
    ) catch {};
    writer.writeAll(body) catch {};
    return 200;
}

fn sendNoContent(writer: *std.Io.Writer) ?u16 {
    writer.writeAll("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n") catch {};
    return 204;
}

/// Error envelope shared with the proxy: {"error":{"message","type","code"}}.
/// Message must be static or an error name (never user content); success
/// bodies quote user strings via quoted().
fn sendError(writer: *std.Io.Writer, status: u16, message: []const u8) ?u16 {
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(
        &buf,
        "{{\"error\":{{\"message\":\"{s}\",\"type\":\"proxy_error\",\"code\":{d}}}}}",
        .{ message, status },
    ) catch "{\"error\":{\"message\":\"dashboard error\",\"type\":\"proxy_error\"}}";
    sendJson(writer, status, body) catch {};
    return status;
}

/// Serialize a std.json.Value (hasDecl shim mirrors proxy.zig/models.zig).
fn stringifyValueAlloc(alloc: Allocator, v: std.json.Value) ![]u8 {
    if (comptime @hasDecl(std.json.Stringify, "valueAlloc")) {
        return try std.json.Stringify.valueAlloc(alloc, v, .{});
    } else {
        return try std.json.stringifyAlloc(alloc, v, .{});
    }
}

/// JSON-quoted string for user-controlled content.
fn quoted(alloc: Allocator, s: []const u8) ![]u8 {
    return try stringifyValueAlloc(alloc, .{ .string = s });
}

fn appendQuoted(out: *std.ArrayList(u8), alloc: Allocator, s: []const u8) !void {
    const q = try quoted(alloc, s);
    defer alloc.free(q);
    try out.appendSlice(alloc, q);
}

// ---------------------------------------------------------------------------
// Request JSON helpers (bodies parse to std.json.Value)
// ---------------------------------------------------------------------------

const FieldError = error{BadField};

fn parseBody(alloc: Allocator, body: []const u8) ?std.json.Parsed(std.json.Value) {
    if (body.len == 0) return null;
    return std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch null;
}

fn objField(root: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (root) {
        .object => |o| o.get(name),
        else => null,
    };
}

fn reqString(root: std.json.Value, name: []const u8) FieldError![]const u8 {
    const v = objField(root, name) orelse return FieldError.BadField;
    return switch (v) {
        .string => |s| s,
        else => FieldError.BadField,
    };
}

fn optString(root: std.json.Value, name: []const u8) FieldError!?[]const u8 {
    const v = objField(root, name) orelse return null;
    return switch (v) {
        .string => |s| @as(?[]const u8, s),
        .null => null,
        else => FieldError.BadField,
    };
}

fn optBool(root: std.json.Value, name: []const u8) FieldError!?bool {
    const v = objField(root, name) orelse return null;
    return switch (v) {
        .bool => |b| @as(?bool, b),
        .null => null,
        else => FieldError.BadField,
    };
}

fn optInt(root: std.json.Value, comptime T: type, name: []const u8) FieldError!?T {
    const v = objField(root, name) orelse return null;
    const i = switch (v) {
        .integer => |n| n,
        .null => return null,
        else => return FieldError.BadField,
    };
    if (i < 0) return FieldError.BadField;
    const max: i128 = std.math.maxInt(T);
    if (@as(i128, i) > max) return FieldError.BadField;
    return @intCast(i);
}

// ---------------------------------------------------------------------------
// Path + pure helpers (unit-tested below)
// ---------------------------------------------------------------------------

fn stripTrailingSlash(path: []const u8) []const u8 {
    if (path.len > 1 and path[path.len - 1] == '/') return path[0 .. path.len - 1];
    return path;
}

fn splitSegments(path: []const u8, out: *[8][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (n >= out.len) break;
        out[n] = seg;
        n += 1;
    }
    return n;
}

fn parseIndex(s: []const u8) ?usize {
    if (s.len == 0) return null;
    return std.fmt.parseInt(usize, s, 10) catch null;
}

/// Masked key id for provider payloads: "***" plus up to the last 4 chars.
fn maskKeyId(key_material: []const u8, out: *[8]u8) []const u8 {
    const tail = if (key_material.len <= 4) key_material else key_material[key_material.len - 4 ..];
    var pos: usize = 0;
    for ("***") |ch| {
        out[pos] = ch;
        pos += 1;
    }
    for (tail) |ch| {
        if (pos >= out.len) break;
        out[pos] = ch;
        pos += 1;
    }
    return out[0..pos];
}

/// Owned copy of prefix with a trailing "/" appended when missing.
fn prefixWithSlash(alloc: Allocator, prefix: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, prefix, "/")) return try alloc.dupe(u8, prefix);
    return try std.fmt.allocPrint(alloc, "{s}/", .{prefix});
}

fn trimKey(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn isValidateError(err: anyerror) bool {
    return switch (err) {
        error.EmptyKeyMaterial,
        error.EmptyDisplayName,
        error.InvalidBaseUrl,
        error.EmptyPrefix,
        error.PrefixMissingTrailingSlash,
        error.DuplicatePrefix,
        error.DuplicateKeyMaterial,
        error.EmptyHeaderName,
        error.InvalidHeaderName,
        error.DuplicateHeaderName,
        error.InvalidPort,
        error.InvalidCooldown,
        error.InvalidTimeout,
        => true,
        else => false,
    };
}

fn firstUsableKey(prov: *const models.Provider, now: i64) ?usize {
    for (prov.keys, 0..) |*k, i| {
        if (k.isUsable(now)) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------

fn route(
    c: *Controller,
    method: []const u8,
    path: []const u8,
    body: []const u8,
    alloc: Allocator,
    writer: *std.Io.Writer,
) ?u16 {
    const is_get = std.ascii.eqlIgnoreCase(method, "GET");
    const is_post = std.ascii.eqlIgnoreCase(method, "POST");
    const is_put = std.ascii.eqlIgnoreCase(method, "PUT");
    const is_patch = std.ascii.eqlIgnoreCase(method, "PATCH");
    const is_delete = std.ascii.eqlIgnoreCase(method, "DELETE");

    const clean = stripTrailingSlash(path);
    if (std.mem.eql(u8, clean, "/api/update") and (is_get or is_post)) {
        const updater = c.updater orelse return sendError(writer, 400, "Updater unavailable.");
        if (is_post) {
            const parsed = std.json.parseFromSlice(struct { token: []const u8 }, alloc, body, .{}) catch return sendError(writer, 400, "Reload the dashboard and retry.");
            defer parsed.deinit();
            if (c.quickadd_token.len == 0 or !std.mem.eql(u8, parsed.value.token, c.quickadd_token)) return sendError(writer, 400, "Reload the dashboard and retry.");
            updater.begin() catch return sendError(writer, 409, "No update is ready or an update is already running.");
        }
        const result = updater.status(alloc) catch return sendError(writer, 500, "Out of memory");
        sendJson(writer, 200, result) catch {};
        return 200;
    }
    if (is_get and std.mem.eql(u8, clean, "/kimi-logo.png")) return sendStatic(writer, "image/png", @embedFile("web/kimi-logo.png"));
    if (std.mem.eql(u8, clean, "/api/quick-adds/kimi") and (is_get or is_post)) return handleKimiQuickAdd(c, is_post, body, alloc, writer);

    if (is_get and std.mem.eql(u8, clean, "/")) {
        return sendStatic(writer, "text/html", index_html);
    }
    if (is_get and std.mem.eql(u8, clean, "/app.js")) {
        return sendStatic(writer, "application/javascript", app_js);
    }
    if (is_get and std.mem.eql(u8, clean, "/styles.css")) {
        return sendStatic(writer, "text/css", styles_css);
    }
    if (is_get and std.mem.eql(u8, clean, "/favicon.ico")) {
        return sendNoContent(writer);
    }

    var segbuf: [8][]const u8 = undefined;
    const seglen = splitSegments(clean, &segbuf);
    const segs = segbuf[0..seglen];
    if (seglen < 3 or !std.mem.eql(u8, segs[1], "api")) return null;

    if (std.mem.eql(u8, segs[2], "status") and seglen == 3 and is_get) {
        return handleStatus(c, alloc, writer);
    }
    if (std.mem.eql(u8, segs[2], "server") and seglen == 3 and is_post) {
        return handleServer(c, body, alloc, writer);
    }
    if (std.mem.eql(u8, segs[2], "models")) {
        if (seglen == 3 and is_get) return handleModels(c, alloc, writer);
        if (seglen == 3 and is_post) return handleModelsRefresh(c, alloc, writer);
        // PATCH /api/models/{p}/{m}: toggle model m of provider p.
        if (seglen == 5 and is_patch) return handleModelPatch(c, segs[3], segs[4], body, alloc, writer);
        return null;
    }
    if (std.mem.eql(u8, segs[2], "logs") and is_get) {
        return handleLogs(c, segs, alloc, writer);
    }
    if (std.mem.eql(u8, segs[2], "usage") and seglen == 3 and is_get) {
        return handleUsageGet(c, alloc, writer);
    }
    if (std.mem.eql(u8, segs[2], "settings") and seglen == 3 and (is_get or is_put)) {
        if (is_get) return handleSettingsGet(c, alloc, writer);
        return handleSettingsPut(c, body, alloc, writer);
    }
    if (std.mem.eql(u8, segs[2], "providers")) {
        return routeProviders(c, segs, is_get, is_post, is_put, is_patch, is_delete, body, alloc, writer);
    }
    return null;
}

fn handleKimiQuickAdd(c: *Controller, post: bool, body: []const u8, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    const quickadd = @import("quickadd.zig");
    if (c.kimi_config_path.len == 0 or c.quickadd_token.len == 0) return sendError(writer, 400, "Kimi Code home directory is unavailable.");
    c.mu.lock();
    defer c.mu.unlock();
    if (!post) {
        const payload = std.json.Stringify.valueAlloc(alloc, .{ .path = c.kimi_config_path, .token = c.quickadd_token }, .{}) catch return sendError(writer, 500, "Out of memory");
        sendJson(writer, 200, payload) catch {};
        return 200;
    }
    const parsed = std.json.parseFromSlice(struct { token: []const u8 }, alloc, body, .{}) catch return sendError(writer, 400, "Reload this page and try again.");
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.token, c.quickadd_token)) return sendError(writer, 400, "Reload this page and try again.");
    // Kimi must be pointed at the port that is actually serving: start() falls
    // back to a free port above the configured one, so the config port alone
    // can name a port nothing listens on.
    var snapshot = c.config.*;
    if (c.isRunning()) snapshot.port = c.proxy.boundPort();
    const result = quickadd.apply(alloc, c.io, c.kimi_config_path, snapshot) catch |err| {
        const msg = switch (err) {
            error.UnsafeToml => "This config uses an unsupported or ambiguous TOML layout. No changes were made.",
            error.NoEnabledModels => "Enable at least one model in the model library first.",
            error.ConfigChanged => "Kimi config changed during the update. Please try again.",
            else => "Could not update Kimi config. Check file permissions and available disk space.",
        };
        return sendError(writer, 400, msg);
    };
    const payload = std.json.Stringify.valueAlloc(alloc, result, .{}) catch return sendError(writer, 500, "Out of memory");
    sendJson(writer, 200, payload) catch {};
    return 200;
}

fn routeProviders(
    c: *Controller,
    segs: [][]const u8,
    is_get: bool,
    is_post: bool,
    is_put: bool,
    is_patch: bool,
    is_delete: bool,
    body: []const u8,
    alloc: Allocator,
    writer: *std.Io.Writer,
) ?u16 {
    if (segs.len == 3) {
        if (is_get) return handleProvidersGet(c, alloc, writer);
        if (is_post) return handleProviderCreate(c, body, alloc, writer);
        return null;
    }
    if (segs.len == 4) {
        const idx = parseIndex(segs[3]) orelse return sendError(writer, 404, "bad provider index");
        if (is_get) return handleProviderGet(c, idx, alloc, writer);
        if (is_put) return handleProviderPut(c, idx, body, alloc, writer);
        if (is_delete) return handleProviderDelete(c, idx, alloc, writer);
        return null;
    }
    if (segs.len == 5) {
        const idx = parseIndex(segs[3]) orelse return sendError(writer, 404, "bad provider index");
        if (std.mem.eql(u8, segs[4], "keys") and is_post) {
            return handleKeysAdd(c, idx, body, alloc, writer);
        }
        if (std.mem.eql(u8, segs[4], "headers")) {
            if (is_get) return handleHeadersGet(c, idx, alloc, writer);
            if (is_post) return handleHeaderCreate(c, idx, body, alloc, writer);
        }
        return null;
    }
    if (segs.len == 6) {
        const idx = parseIndex(segs[3]) orelse return sendError(writer, 404, "bad provider index");
        if (std.mem.eql(u8, segs[4], "keys")) {
            const kidx = parseIndex(segs[5]) orelse return sendError(writer, 404, "bad key index");
            if (is_delete) return handleKeyDelete(c, idx, kidx, alloc, writer);
            if (is_patch) return handleKeyPatch(c, idx, kidx, body, alloc, writer);
            return null;
        }
        if (std.mem.eql(u8, segs[4], "headers")) {
            const hidx = parseIndex(segs[5]) orelse return sendError(writer, 404, "bad header index");
            if (is_get) return handleHeaderGet(c, idx, hidx, alloc, writer);
            if (is_put) return handleHeaderPut(c, idx, hidx, body, alloc, writer);
            if (is_delete) return handleHeaderDelete(c, idx, hidx, alloc, writer);
            return null;
        }
        if (std.mem.eql(u8, segs[4], "ping") and is_post) {
            const kidx = parseIndex(segs[5]) orelse return sendError(writer, 404, "bad key index");
            return handlePing(c, idx, kidx, alloc, writer);
        }
        return null;
    }
    if (segs.len == 7 and is_post) {
        // Alias matching the frontend shape: /providers/{i}/keys/{k}/ping.
        const idx = parseIndex(segs[3]) orelse return sendError(writer, 404, "bad provider index");
        if (std.mem.eql(u8, segs[4], "keys") and std.mem.eql(u8, segs[6], "ping")) {
            const kidx = parseIndex(segs[5]) orelse return sendError(writer, 404, "bad key index");
            return handlePing(c, idx, kidx, alloc, writer);
        }
        return null;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Shared applier: stop, drain, mutate, validate, save, reinit, restart
// ---------------------------------------------------------------------------

const OpFn = *const fn (c: *Controller, op_ctx: *const anyopaque, req_alloc: Allocator) anyerror![]u8;

fn waitForDrain(c: *Controller) void {
    const t0 = nowUnixMs();
    while (c.othersInFlight() > 0) {
        if (nowUnixMs() - t0 > 5000) break;
        std.Thread.yield() catch {};
    }
}

/// Worker-side stop: signal exit, wait for peer requests to drain, close
/// the listener. Never joins the pool, so a dashboard handler (which runs
/// on a pool worker) cannot deadlock itself the way a full Proxy.stop()
/// would. Group reclamation happens on the next non-worker stop().
fn workerStop(c: *Controller) void {
    c.proxy.initiateStop();
    waitForDrain(c);
    c.proxy.closeListener();
}

/// Worker-side (re)start. Proxy.start() binds and spawns without joining,
/// so it is safe from a worker once the old socket is closed.
fn workerStart(c: *Controller) !void {
    try c.proxy.start();
}

fn applyChange(
    c: *Controller,
    req_alloc: Allocator,
    writer: *std.Io.Writer,
    success_status: u16,
    op: OpFn,
    op_ctx: *const anyopaque,
) ?u16 {
    if (c.isRunning() and c.othersInFlight() > 0) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "server busy: {d} requests in flight", .{c.othersInFlight()}) catch "server busy";
        return sendError(writer, 409, msg);
    }

    const was_running = c.isRunning();
    if (was_running) workerStop(
        c,
    );

    c.mu.lock();
    const before_count = c.config.providers.len;
    const op_body = op(c, op_ctx, req_alloc) catch |err| {
        c.mu.unlock();
        if (was_running) workerStart(
            c,
        ) catch {};
        if (isValidateError(err)) return sendError(writer, 400, @errorName(err));
        if (err == FieldError.BadField) return sendError(writer, 400, "invalid field");
        return sendError(writer, 500, @errorName(err));
    };
    c.config.validate() catch |err| {
        c.mu.unlock();
        c.log.err("dashboard: config invalid after apply: {s}", .{@errorName(err)});
        if (was_running) workerStart(
            c,
        ) catch {};
        return sendError(writer, 500, @errorName(err));
    };
    c.metrics.syncConfig(c.alloc, c.config) catch {};
    config_mod.saveToPath(c.alloc, c.io, c.config, c.config_path) catch |err| {
        const after_fail = c.config.providers.len;
        c.mu.unlock();
        c.log.err("dashboard: config save failed: {s}", .{@errorName(err)});
        if (after_fail != before_count) c.reinitRotator();
        if (was_running) workerStart(
            c,
        ) catch {};
        return sendError(writer, 500, @errorName(err));
    };
    const after_count = c.config.providers.len;
    c.mu.unlock();

    if (after_count != before_count) c.reinitRotator();
    if (was_running) {
        workerStart(
            c,
        ) catch |err| {
            c.log.err("dashboard: restart failed after save: {s}", .{@errorName(err)});
            return sendError(writer, 500, @errorName(err));
        };
    }
    sendJson(writer, success_status, op_body) catch {};
    return success_status;
}

// ---------------------------------------------------------------------------
// JSON body builders (arena-owned; caller sends after unlocking)
// ---------------------------------------------------------------------------

fn effectiveKeyState(key: *const models.Key, now_unix: i64) models.KeyState {
    // An expired cooldown reads as Active to the UI: the rotator promotes
    // lazily on the next pick, so the stored state lags behind.
    if (key.state == .CoolingDown and now_unix >= key.cooldown_until) return .Active;
    return key.state;
}

fn appendKeyJson(out: *std.ArrayList(u8), alloc: Allocator, key: *const models.Key, index: usize, now_unix: i64) !void {
    var maskbuf: [8]u8 = undefined;
    const masked = maskKeyId(key.key, &maskbuf);
    const qid = try quoted(alloc, masked);
    defer alloc.free(qid);
    var numbuf: [32]u8 = undefined;
    const idx_s = try std.fmt.bufPrint(&numbuf, "{d}", .{index});
    try out.appendSlice(alloc, "{\"index\":");
    try out.appendSlice(alloc, idx_s);
    try out.appendSlice(alloc, ",\"id\":");
    try out.appendSlice(alloc, qid);
    try out.appendSlice(alloc, ",\"state\":\"");
    try out.appendSlice(alloc, @tagName(effectiveKeyState(key, now_unix)));
    try out.appendSlice(alloc, "\",\"enabled\":");
    try out.appendSlice(alloc, if (key.enabled) "true" else "false");
    try out.appendSlice(alloc, "}");
}

fn appendHeaderJson(out: *std.ArrayList(u8), alloc: Allocator, h: *const models.CustomHeader, index: usize) !void {
    var numbuf: [32]u8 = undefined;
    const idx_s = try std.fmt.bufPrint(&numbuf, "{d}", .{index});
    try out.appendSlice(alloc, "{\"index\":");
    try out.appendSlice(alloc, idx_s);
    try out.appendSlice(alloc, ",\"key\":");
    try appendQuoted(out, alloc, h.key);
    try out.appendSlice(alloc, ",\"value\":");
    try appendQuoted(out, alloc, h.value);
    try out.appendSlice(alloc, "}");
}

fn appendProviderJson(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    prov: *const models.Provider,
    index: usize,
    now: i64,
) !void {
    var numbuf: [64]u8 = undefined;
    const idx_s = try std.fmt.bufPrint(&numbuf, "{d}", .{index});
    try out.appendSlice(alloc, "{\"index\":");
    try out.appendSlice(alloc, idx_s);
    try out.appendSlice(alloc, ",\"display_name\":");
    try appendQuoted(out, alloc, prov.display_name);
    try out.appendSlice(alloc, ",\"base_url\":");
    try appendQuoted(out, alloc, prov.base_url);
    try out.appendSlice(alloc, ",\"prefix\":");
    try appendQuoted(out, alloc, prov.prefix);
    try out.appendSlice(alloc, ",\"description\":");
    try appendQuoted(out, alloc, prov.description);
    try out.appendSlice(alloc, ",\"note\":");
    try appendQuoted(out, alloc, prov.note);
    try out.appendSlice(alloc, ",\"site_url\":");
    try appendQuoted(out, alloc, prov.site_url);
    try out.appendSlice(alloc, ",\"use_free_proxy\":");
    try out.appendSlice(alloc, if (prov.use_free_proxy) "true" else "false");
    var countbuf: [64]u8 = undefined;
    // NOTE: each slice must be consumed before the next bufPrint reuses the
    // buffer; a second print into the same buffer overwrites the first slice.
    const kc = try std.fmt.bufPrint(&countbuf, "{d}", .{prov.keys.len});
    try out.appendSlice(alloc, ",\"key_count\":");
    try out.appendSlice(alloc, kc);
    const hc = try std.fmt.bufPrint(&countbuf, "{d}", .{prov.usableKeyCount(now)});
    try out.appendSlice(alloc, ",\"healthy_keys\":");
    try out.appendSlice(alloc, hc);
    try out.appendSlice(alloc, ",\"keys\":[");
    for (prov.keys, 0..) |*k, ki| {
        if (ki != 0) try out.appendSlice(alloc, ",");
        try appendKeyJson(out, alloc, k, ki, now);
    }
    try out.appendSlice(alloc, "],\"headers\":[");
    for (prov.headers, 0..) |*h, hi| {
        if (hi != 0) try out.appendSlice(alloc, ",");
        try appendHeaderJson(out, alloc, h, hi);
    }
    try out.appendSlice(alloc, "]}");
}

fn appendSettingsJson(out: *std.ArrayList(u8), alloc: Allocator, cfg: *const models.ProxyConfig) !void {
    const body = try std.fmt.allocPrint(
        alloc,
        "{{\"port\":{d},\"auto_start\":{s},\"cooldown_secs\":{d},\"timeout_ms\":{d},\"free_mode\":{s},\"hide_paid\":{s}}}",
        .{
            cfg.port,
            if (cfg.auto_start) "true" else "false",
            cfg.cooldown_secs,
            cfg.timeout_ms,
            if (cfg.free_mode) "true" else "false",
            if (cfg.hide_paid) "true" else "false",
        },
    );
    try out.appendSlice(alloc, body);
}

// ---------------------------------------------------------------------------
// GET /api/status
// ---------------------------------------------------------------------------

fn handleStatus(c: *Controller, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    const snap = c.metrics.snapshot();
    c.mu.lock();
    const port = c.config.port;
    const now = nowUnixSec();
    var providers: usize = 0;
    var total_keys: usize = 0;
    var healthy_keys: usize = 0;
    for (c.config.providers) |*p| {
        providers += 1;
        total_keys += p.keys.len;
        healthy_keys += p.usableKeyCount(now);
    }
    c.mu.unlock();

    const running = c.isRunning();
    const bound = c.proxy.boundPort();
    const inflight = snap.active_inflight;
    const served = c.proxy.totalServedCount();
    var proxies_alive: usize = 0;
    var pool_diag_tracked: usize = 0;
    var pool_capacity: [5]usize = @splat(0);
    var pool_diag_working = false;
    var pool_diag_error: []const u8 = "";
    if (c.free_proxies) |pool| {
        proxies_alive = pool.alive();
        const dg = pool.diag();
        pool_diag_tracked = dg.tracked;
        pool_capacity = .{ dg.ready, dg.busy, dg.blocked, dg.waiting, dg.candidates };
        pool_diag_working = dg.working;
        pool_diag_error = dg.last_error;
    }

    const body = std.fmt.allocPrint(
        alloc,
        "{{\"running\":{s},\"port\":{d},\"bound_port\":{d},\"pool_tracked\":{d},\"pool_working\":{s},\"in_flight\":{d}," ++
            "\"total_served\":{d},\"providers\":{d},\"total_keys\":{d},\"healthy_keys\":{d}," ++
            "\"avg_latency_ms\":{d},\"total_errors\":{d},\"total_failovers\":{d},\"proxies_alive\":{d},\"pool_ready\":{d},\"pool_busy\":{d},\"pool_blocked\":{d},\"pool_waiting\":{d},\"pool_candidates\":{d},\"active_connections\":{d},\"connection_limit\":{d}}}",
        .{
            if (running) "true" else "false",
            port,
            bound,
            pool_diag_tracked,
            if (pool_diag_working) "true" else "false",
            inflight,
            served,
            providers,
            total_keys,
            healthy_keys,
            snap.avg_latency_ms,
            snap.total_errors,
            snap.total_failovers,
            proxies_alive,
            pool_capacity[0],
            pool_capacity[1],
            pool_capacity[2],
            pool_capacity[3],
            pool_capacity[4],
            c.proxy.activeConnectionCount(),
            c.proxy.pool_threads,
        },
    ) catch return sendError(writer, 500, "out of memory");
    sendJson(writer, 200, body) catch {};
    return 200;
}

// ---------------------------------------------------------------------------
// POST /api/server
// ---------------------------------------------------------------------------

fn handleServer(c: *Controller, body: []const u8, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    if (body.len == 0) return sendError(writer, 400, "missing request body");
    const parsed = parseBody(alloc, body) orelse return sendError(writer, 400, "malformed JSON");
    defer parsed.deinit();
    const action = reqString(parsed.value, "action") catch return sendError(writer, 400, "invalid action");

    if (std.ascii.eqlIgnoreCase(action, "start")) {
        if (!c.isRunning()) {
            workerStart(
                c,
            ) catch |err| {
                c.log.err("dashboard: start failed: {s}", .{@errorName(err)});
                return sendError(writer, 500, @errorName(err));
            };
        }
    } else if (std.ascii.eqlIgnoreCase(action, "stop")) {
        if (c.isRunning()) workerStop(
            c,
        );
    } else {
        return sendError(writer, 400, "invalid action");
    }

    c.mu.lock();
    const port = c.config.port;
    c.mu.unlock();
    const running = c.isRunning();
    const resp = std.fmt.allocPrint(
        alloc,
        "{{\"running\":{s},\"port\":{d}}}",
        .{ if (running) "true" else "false", port },
    ) catch return sendError(writer, 500, "out of memory");
    sendJson(writer, 200, resp) catch {};
    return 200;
}

// ---------------------------------------------------------------------------
// Providers collection
// ---------------------------------------------------------------------------

fn handleProvidersGet(c: *Controller, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(alloc, "{\"providers\":[") catch return sendError(writer, 500, "out of memory");
    c.mu.lock();
    const now = nowUnixSec();
    for (c.config.providers, 0..) |*p, i| {
        if (i != 0) out.appendSlice(alloc, ",") catch {
            c.mu.unlock();
            return sendError(writer, 500, "out of memory");
        };
        appendProviderJson(&out, alloc, p, i, now) catch {
            c.mu.unlock();
            return sendError(writer, 500, "out of memory");
        };
    }
    c.mu.unlock();
    out.appendSlice(alloc, "]}") catch return sendError(writer, 500, "out of memory");
    sendJson(writer, 200, out.items) catch {};
    return 200;
}

const CreateProviderArgs = struct {
    display_name: []const u8,
    base_url: []const u8,
    prefix: []const u8,
    description: []const u8,
    headers: []const HeaderPair,
};

const HeaderPair = struct {
    key: []const u8,
    value: []const u8,
};

fn handleProviderCreate(c: *Controller, body: []const u8, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    if (body.len == 0) return sendError(writer, 400, "missing request body");
    const parsed = parseBody(alloc, body) orelse return sendError(writer, 400, "malformed JSON");
    defer parsed.deinit();
    const root = parsed.value;

    const display_name = reqString(root, "display_name") catch return sendError(writer, 400, "invalid field");
    const base_url = reqString(root, "base_url") catch return sendError(writer, 400, "invalid field");
    const prefix = reqString(root, "prefix") catch return sendError(writer, 400, "invalid field");
    const description = optString(root, "description") catch return sendError(writer, 400, "invalid field");

    var pairs: std.ArrayList(HeaderPair) = .empty;
    if (objField(root, "headers")) |hv| {
        const arr = switch (hv) {
            .array => |a| a.items,
            else => return sendError(writer, 400, "invalid field"),
        };
        for (arr) |item| {
            const k = reqString(item, "key") catch return sendError(writer, 400, "invalid field");
            const v = reqString(item, "value") catch return sendError(writer, 400, "invalid field");
            pairs.append(alloc, .{ .key = k, .value = v }) catch return sendError(writer, 500, "out of memory");
        }
    }

    var args = CreateProviderArgs{
        .display_name = display_name,
        .base_url = base_url,
        .prefix = prefix,
        .description = description orelse "",
        .headers = pairs.items,
    };
    return applyChange(c, alloc, writer, 201, opCreateProvider, @ptrCast(&args));
}

fn opCreateProvider(c: *Controller, ctx: *const anyopaque, req_alloc: Allocator) anyerror![]u8 {
    const args: *const CreateProviderArgs = @ptrCast(@alignCast(ctx));
    const gpa = c.alloc;

    const display_name = try gpa.dupe(u8, args.display_name);
    errdefer gpa.free(display_name);
    const base_url = try gpa.dupe(u8, args.base_url);
    errdefer gpa.free(base_url);
    const prefix = try prefixWithSlash(gpa, args.prefix);
    errdefer gpa.free(prefix);
    const description = try gpa.dupe(u8, args.description);
    errdefer gpa.free(description);

    const headers = try gpa.alloc(models.CustomHeader, args.headers.len);
    errdefer gpa.free(headers);
    var hfilled: usize = 0;
    errdefer {
        for (headers[0..hfilled]) |*h| h.deinit(gpa);
    }
    for (args.headers) |pair| {
        headers[hfilled] = .{
            .key = try gpa.dupe(u8, pair.key),
            .value = try gpa.dupe(u8, pair.value),
        };
        hfilled += 1;
    }
    const keys = try gpa.alloc(models.Key, 0);

    var prov = models.Provider{
        .display_name = display_name,
        .base_url = base_url,
        .prefix = prefix,
        .description = description,
        .keys = keys,
        .headers = headers,
    };
    try prov.validate();

    const old = c.config.providers;
    const grown = try gpa.alloc(models.Provider, old.len + 1);
    @memcpy(grown[0..old.len], old);
    grown[old.len] = prov;
    c.config.providers = grown;
    if (old.len != 0) gpa.free(old);

    errdefer {
        // Roll back the append when full-config validation fails below.
        var last = &c.config.providers[c.config.providers.len - 1];
        last.deinit(gpa);
        const shrunk = c.config.providers[0 .. c.config.providers.len - 1];
        gpa.free(c.config.providers);
        c.config.providers = shrunk;
    }
    try c.config.validate();

    var out: std.ArrayList(u8) = .empty;
    try appendProviderJson(&out, req_alloc, &c.config.providers[c.config.providers.len - 1], c.config.providers.len - 1, nowUnixSec());
    return out.items;
}

// ---------------------------------------------------------------------------
// Single provider
// ---------------------------------------------------------------------------

fn providerCount(c: *Controller) usize {
    c.mu.lock();
    defer c.mu.unlock();
    return c.config.providers.len;
}

fn handleProviderGet(c: *Controller, idx: usize, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    var out: std.ArrayList(u8) = .empty;
    c.mu.lock();
    if (idx >= c.config.providers.len) {
        c.mu.unlock();
        return sendError(writer, 404, "bad provider index");
    }
    appendProviderJson(&out, alloc, &c.config.providers[idx], idx, nowUnixSec()) catch {
        c.mu.unlock();
        return sendError(writer, 500, "out of memory");
    };
    c.mu.unlock();
    sendJson(writer, 200, out.items) catch {};
    return 200;
}

fn handleProviderPut(c: *Controller, idx: usize, body: []const u8, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    if (idx >= providerCount(
        c,
    )) return sendError(writer, 404, "bad provider index");
    if (body.len == 0) return sendError(writer, 400, "missing request body");
    const parsed = parseBody(alloc, body) orelse return sendError(writer, 400, "malformed JSON");
    defer parsed.deinit();
    const root = parsed.value;

    const display_name = optString(root, "display_name") catch return sendError(writer, 400, "invalid field");
    const base_url = optString(root, "base_url") catch return sendError(writer, 400, "invalid field");
    const prefix = optString(root, "prefix") catch return sendError(writer, 400, "invalid field");
    const description = optString(root, "description") catch return sendError(writer, 400, "invalid field");

    var pairs: std.ArrayList(HeaderPair) = .empty;
    const headers_present = objField(root, "headers") != null;
    if (objField(root, "headers")) |hv| {
        const arr = switch (hv) {
            .array => |a| a.items,
            else => return sendError(writer, 400, "invalid field"),
        };
        for (arr) |item| {
            const k = reqString(item, "key") catch return sendError(writer, 400, "invalid field");
            const v = reqString(item, "value") catch return sendError(writer, 400, "invalid field");
            pairs.append(alloc, .{ .key = k, .value = v }) catch return sendError(writer, 500, "out of memory");
        }
    }

    var args = PutProviderArgs{
        .index = idx,
        .display_name = display_name,
        .base_url = base_url,
        .prefix = prefix,
        .description = description,
        .note = optString(root, "note") catch return sendError(writer, 400, "invalid field"),
        .site_url = optString(root, "site_url") catch return sendError(writer, 400, "invalid field"),
        .use_free_proxy = optBool(root, "use_free_proxy") catch return sendError(writer, 400, "invalid field"),
        .headers = pairs.items,
        .headers_present = headers_present,
    };
    return applyChange(c, alloc, writer, 200, opPutProvider, @ptrCast(&args));
}

const PutProviderArgs = struct {
    index: usize,
    display_name: ?[]const u8,
    base_url: ?[]const u8,
    prefix: ?[]const u8,
    description: ?[]const u8,
    note: ?[]const u8,
    site_url: ?[]const u8,
    use_free_proxy: ?bool,
    headers: []const HeaderPair,
    headers_present: bool,
};

fn opPutProvider(c: *Controller, ctx: *const anyopaque, req_alloc: Allocator) anyerror![]u8 {
    const args: *const PutProviderArgs = @ptrCast(@alignCast(ctx));
    const gpa = c.alloc;
    if (args.index >= c.config.providers.len) return error.BadProviderIndex;
    const prov = &c.config.providers[args.index];

    const display_name = try gpa.dupe(u8, args.display_name orelse prov.display_name);
    errdefer gpa.free(display_name);
    const base_url = try gpa.dupe(u8, args.base_url orelse prov.base_url);
    errdefer gpa.free(base_url);
    const prefix = if (args.prefix) |p| try prefixWithSlash(gpa, p) else try gpa.dupe(u8, prov.prefix);
    errdefer gpa.free(prefix);
    const description = try gpa.dupe(u8, args.description orelse prov.description);
    errdefer gpa.free(description);

    var new_headers: []models.CustomHeader = &.{};
    var hfilled: usize = 0;
    if (args.headers_present) {
        new_headers = try gpa.alloc(models.CustomHeader, args.headers.len);
        errdefer {
            for (new_headers[0..hfilled]) |*h| h.deinit(gpa);
            gpa.free(new_headers);
        }
        for (args.headers) |pair| {
            new_headers[hfilled] = .{
                .key = try gpa.dupe(u8, pair.key),
                .value = try gpa.dupe(u8, pair.value),
            };
            hfilled += 1;
        }
    }

    // Validate the candidate against the live keys before committing.
    const new_note = try gpa.dupe(u8, args.note orelse prov.note);
    errdefer gpa.free(new_note);
    const new_site = try gpa.dupe(u8, args.site_url orelse prov.site_url);
    errdefer gpa.free(new_site);
    const candidate = models.Provider{
        .display_name = display_name,
        .base_url = base_url,
        .prefix = prefix,
        .description = description,
        .note = new_note,
        .site_url = new_site,
        .keys = prov.keys,
        .headers = if (args.headers_present) new_headers else prov.headers,
    };
    try candidate.validate();

    // Swap in with full-config rollback on duplicate prefixes.
    const old_display = prov.display_name;
    const old_base = prov.base_url;
    const old_prefix = prov.prefix;
    const old_desc = prov.description;
    const old_note = prov.note;
    const old_site = prov.site_url;
    const old_headers = prov.headers;
    prov.display_name = display_name;
    prov.base_url = base_url;
    prov.prefix = prefix;
    prov.description = description;
    prov.note = new_note;
    prov.site_url = new_site;
    prov.use_free_proxy = args.use_free_proxy orelse prov.use_free_proxy;
    if (prov.use_free_proxy) {
        if (c.free_proxies) |pool| pool.maybeRefresh();
    }
    if (args.headers_present) prov.headers = new_headers;
    errdefer {
        prov.display_name = old_display;
        prov.base_url = old_base;
        prov.prefix = old_prefix;
        prov.description = old_desc;
        prov.note = old_note;
        prov.site_url = old_site;
        if (args.headers_present) prov.headers = old_headers;
    }
    c.config.validate() catch |err| {
        return err;
    };

    gpa.free(old_display);
    gpa.free(old_base);
    gpa.free(old_prefix);
    gpa.free(old_desc);
    gpa.free(old_note);
    gpa.free(old_site);
    if (args.headers_present) {
        for (old_headers) |*h| h.deinit(gpa);
        if (old_headers.len != 0) gpa.free(old_headers);
    } else {
        for (new_headers) |*h| h.deinit(gpa);
    }

    var out: std.ArrayList(u8) = .empty;
    try appendProviderJson(&out, req_alloc, prov, args.index, nowUnixSec());
    return out.items;
}

const IndexArg = struct {
    index: usize,
};

fn handleProviderDelete(c: *Controller, idx: usize, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    if (idx >= providerCount(
        c,
    )) return sendError(writer, 404, "bad provider index");
    var args = IndexArg{ .index = idx };
    return applyChange(c, alloc, writer, 200, opDeleteProvider, @ptrCast(&args));
}

fn removeProviderAt(c: *Controller, idx: usize) void {
    const gpa = c.alloc;
    var items = c.config.providers;
    items[idx].deinit(gpa);
    std.mem.copyForwards(models.Provider, items[idx .. items.len - 1], items[idx + 1 ..]);
    if (items.len - 1 == 0) {
        gpa.free(items);
        c.config.providers = gpa.alloc(models.Provider, 0) catch &.{};
        return;
    }
    c.config.providers = gpa.realloc(items, items.len - 1) catch items[0 .. items.len - 1];
}

fn opDeleteProvider(c: *Controller, ctx: *const anyopaque, req_alloc: Allocator) anyerror![]u8 {
    const args: *const IndexArg = @ptrCast(@alignCast(ctx));
    if (args.index >= c.config.providers.len) return error.BadProviderIndex;
    removeProviderAt(c, args.index);
    try c.config.validate();
    return try std.fmt.allocPrint(req_alloc, "{{\"deleted\":true,\"index\":{d}}}", .{args.index});
}

// ---------------------------------------------------------------------------
// Provider keys
// ---------------------------------------------------------------------------

const AddKeysArgs = struct {
    index: usize,
    single: ?[]const u8,
    bulk: []const []const u8,
};

fn handleKeysAdd(c: *Controller, idx: usize, body: []const u8, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    if (idx >= providerCount(
        c,
    )) return sendError(writer, 404, "bad provider index");
    if (body.len == 0) return sendError(writer, 400, "missing request body");
    const parsed = parseBody(alloc, body) orelse return sendError(writer, 400, "malformed JSON");
    defer parsed.deinit();
    const root = parsed.value;

    const single = optString(root, "key") catch return sendError(writer, 400, "invalid field");
    var bulk: std.ArrayList([]const u8) = .empty;
    if (objField(root, "keys")) |kv| {
        const arr = switch (kv) {
            .array => |a| a.items,
            else => return sendError(writer, 400, "invalid field"),
        };
        for (arr) |item| {
            const s = switch (item) {
                .string => |str| str,
                else => return sendError(writer, 400, "invalid field"),
            };
            bulk.append(alloc, s) catch return sendError(writer, 500, "out of memory");
        }
    }
    if (single == null and bulk.items.len == 0) return sendError(writer, 400, "invalid field");

    var args = AddKeysArgs{ .index = idx, .single = single, .bulk = bulk.items };
    return applyChange(c, alloc, writer, 200, opAddKeys, @ptrCast(&args));
}

fn opAddKeys(c: *Controller, ctx: *const anyopaque, req_alloc: Allocator) anyerror![]u8 {
    const args: *const AddKeysArgs = @ptrCast(@alignCast(ctx));
    const gpa = c.alloc;
    if (args.index >= c.config.providers.len) return error.BadProviderIndex;
    const prov = &c.config.providers[args.index];

    var added: usize = 0;
    if (args.single) |one| {
        if (appendKeyIfNew(gpa, prov, trimKey(one))) added += 1;
    }
    for (args.bulk) |raw| {
        if (appendKeyIfNew(gpa, prov, trimKey(raw))) added += 1;
    }
    try c.config.validate();
    return try std.fmt.allocPrint(req_alloc, "{{\"added\":{d},\"total\":{d}}}", .{ added, prov.keys.len });
}

/// Trimmed, non-empty, non-duplicate key material is appended (owned). Returns
/// true when a key was added. The provider slice grows in place.
fn appendKeyIfNew(gpa: Allocator, prov: *models.Provider, material: []const u8) bool {
    const clean = trimKey(material);
    if (clean.len == 0) return false;
    for (prov.keys) |*k| {
        if (std.mem.eql(u8, k.key, clean)) return false;
    }
    const owned = gpa.dupe(u8, clean) catch return false;
    const grown = gpa.alloc(models.Key, prov.keys.len + 1) catch {
        gpa.free(owned);
        return false;
    };
    @memcpy(grown[0..prov.keys.len], prov.keys);
    grown[prov.keys.len] = models.Key.init(owned);
    if (prov.keys.len != 0) gpa.free(prov.keys);
    prov.keys = grown;
    return true;
}

const KeyIndexArg = struct {
    provider: usize,
    key: usize,
};

fn handleKeyDelete(c: *Controller, idx: usize, kidx: usize, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    if (idx >= providerCount(
        c,
    )) return sendError(writer, 404, "bad provider index");
    var args = KeyIndexArg{ .provider = idx, .key = kidx };
    return applyChange(c, alloc, writer, 200, opDeleteKey, @ptrCast(&args));
}

fn opDeleteKey(c: *Controller, ctx: *const anyopaque, req_alloc: Allocator) anyerror![]u8 {
    const args: *const KeyIndexArg = @ptrCast(@alignCast(ctx));
    const gpa = c.alloc;
    if (args.provider >= c.config.providers.len) return error.BadProviderIndex;
    const prov = &c.config.providers[args.provider];
    if (args.key >= prov.keys.len) return error.BadKeyIndex;
    prov.keys[args.key].deinit(gpa);
    std.mem.copyForwards(models.Key, prov.keys[args.key .. prov.keys.len - 1], prov.keys[args.key + 1 ..]);
    if (prov.keys.len - 1 == 0) {
        gpa.free(prov.keys);
        prov.keys = try gpa.alloc(models.Key, 0);
    } else {
        prov.keys = try gpa.realloc(prov.keys, prov.keys.len - 1);
    }
    try c.config.validate();
    return try std.fmt.allocPrint(req_alloc, "{{\"removed\":true,\"total\":{d}}}", .{prov.keys.len});
}

fn handleKeyPatch(c: *Controller, idx: usize, kidx: usize, body: []const u8, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    if (idx >= providerCount(
        c,
    )) return sendError(writer, 404, "bad provider index");
    if (body.len == 0) return sendError(writer, 400, "missing request body");
    const parsed = parseBody(alloc, body) orelse return sendError(writer, 400, "malformed JSON");
    defer parsed.deinit();
    const enabled = optBool(parsed.value, "enabled") catch return sendError(writer, 400, "invalid field");
    if (enabled == null) return sendError(writer, 400, "invalid field");
    var args = PatchKeyArgs{ .provider = idx, .key = kidx, .enabled = enabled.? };
    return applyChange(c, alloc, writer, 200, opPatchKey, @ptrCast(&args));
}

const PatchKeyArgs = struct {
    provider: usize,
    key: usize,
    enabled: bool,
};

fn opPatchKey(c: *Controller, ctx: *const anyopaque, req_alloc: Allocator) anyerror![]u8 {
    const args: *const PatchKeyArgs = @ptrCast(@alignCast(ctx));
    if (args.provider >= c.config.providers.len) return error.BadProviderIndex;
    const prov = &c.config.providers[args.provider];
    if (args.key >= prov.keys.len) return error.BadKeyIndex;
    // In-place flag flip: no realloc, key material untouched. Re-enabling
    // also revives a Dead/CoolingDown key so the user's explicit choice wins.
    prov.keys[args.key].enabled = args.enabled;
    if (args.enabled) {
        prov.keys[args.key].state = .Active;
        prov.keys[args.key].consecutive_errors = 0;
        prov.keys[args.key].cooldown_until = 0;
    }
    try c.config.validate();
    var out: std.ArrayList(u8) = .empty;
    try appendKeyJson(&out, req_alloc, &prov.keys[args.key], args.key, nowUnixSec());
    return out.items;
}

// ---------------------------------------------------------------------------
// POST /api/providers/{i}/ping/{k} (read-only, bypasses the applier)
// ---------------------------------------------------------------------------

fn handlePing(c: *Controller, idx: usize, kidx: usize, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    c.mu.lock();
    if (idx >= c.config.providers.len) {
        c.mu.unlock();
        return sendError(writer, 404, "bad provider index");
    }
    const src = &c.config.providers[idx];
    if (kidx >= src.keys.len) {
        c.mu.unlock();
        return sendError(writer, 404, "bad key index");
    }
    var cloned = src.clone(alloc) catch {
        c.mu.unlock();
        return sendError(writer, 500, "out of memory");
    };
    const timeout = c.config.timeout_ms;
    c.mu.unlock();
    defer cloned.deinit(alloc);

    const key_material = cloned.keys[kidx].key;
    var result = upstream.fetchModelsWithIo(alloc, c.io, &cloned, key_material, timeout) catch {
        return sendError(writer, 500, "out of memory");
    };
    defer result.models.deinit();

    const ok = models.isHealthyStatus(result.status);
    var out: std.ArrayList(u8) = .empty;
    const head = std.fmt.allocPrint(
        alloc,
        "{{\"ok\":{s},\"status\":{d},\"latency_ms\":{d},\"models\":[",
        .{ if (ok) "true" else "false", result.status, result.elapsed_ms },
    ) catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, head) catch return sendError(writer, 500, "out of memory");
    for (result.models.items, 0..) |*entry, i| {
        if (i != 0) out.appendSlice(alloc, ",") catch return sendError(writer, 500, "out of memory");
        appendQuoted(&out, alloc, entry.id) catch return sendError(writer, 500, "out of memory");
    }
    out.appendSlice(alloc, "]}") catch return sendError(writer, 500, "out of memory");
    sendJson(writer, 200, out.items) catch {};
    return 200;
}

// ---------------------------------------------------------------------------
// Provider headers
// ---------------------------------------------------------------------------

fn handleHeadersGet(c: *Controller, idx: usize, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(alloc, "{\"headers\":[") catch return sendError(writer, 500, "out of memory");
    c.mu.lock();
    if (idx >= c.config.providers.len) {
        c.mu.unlock();
        return sendError(writer, 404, "bad provider index");
    }
    const prov = &c.config.providers[idx];
    for (prov.headers, 0..) |*h, hi| {
        if (hi != 0) out.appendSlice(alloc, ",") catch {
            c.mu.unlock();
            return sendError(writer, 500, "out of memory");
        };
        appendHeaderJson(&out, alloc, h, hi) catch {
            c.mu.unlock();
            return sendError(writer, 500, "out of memory");
        };
    }
    c.mu.unlock();
    out.appendSlice(alloc, "]}") catch return sendError(writer, 500, "out of memory");
    sendJson(writer, 200, out.items) catch {};
    return 200;
}

fn handleHeaderGet(c: *Controller, idx: usize, hidx: usize, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    var out: std.ArrayList(u8) = .empty;
    c.mu.lock();
    if (idx >= c.config.providers.len) {
        c.mu.unlock();
        return sendError(writer, 404, "bad provider index");
    }
    const prov = &c.config.providers[idx];
    if (hidx >= prov.headers.len) {
        c.mu.unlock();
        return sendError(writer, 404, "bad header index");
    }
    appendHeaderJson(&out, alloc, &prov.headers[hidx], hidx) catch {
        c.mu.unlock();
        return sendError(writer, 500, "out of memory");
    };
    c.mu.unlock();
    sendJson(writer, 200, out.items) catch {};
    return 200;
}

const HeaderUpsertArgs = struct {
    provider: usize,
    header: usize,
    key: []const u8,
    value: []const u8,
};

fn parseHeaderBody(root: std.json.Value) FieldError!HeaderPair {
    // Accept "name" as an alias for "key" (frontend sends "name").
    const key = reqString(root, "key") catch reqString(root, "name") catch return FieldError.BadField;
    return .{
        .key = key,
        .value = try reqString(root, "value"),
    };
}

fn handleHeaderCreate(c: *Controller, idx: usize, body: []const u8, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    if (idx >= providerCount(
        c,
    )) return sendError(writer, 404, "bad provider index");
    if (body.len == 0) return sendError(writer, 400, "missing request body");
    const parsed = parseBody(alloc, body) orelse return sendError(writer, 400, "malformed JSON");
    defer parsed.deinit();
    const pair = parseHeaderBody(parsed.value) catch return sendError(writer, 400, "invalid field");
    var args = HeaderUpsertArgs{ .provider = idx, .header = 0, .key = pair.key, .value = pair.value };
    return applyChange(c, alloc, writer, 201, opCreateHeader, @ptrCast(&args));
}

fn opCreateHeader(c: *Controller, ctx: *const anyopaque, req_alloc: Allocator) anyerror![]u8 {
    const args: *const HeaderUpsertArgs = @ptrCast(@alignCast(ctx));
    const gpa = c.alloc;
    if (args.provider >= c.config.providers.len) return error.BadProviderIndex;
    const prov = &c.config.providers[args.provider];

    const name = try gpa.dupe(u8, args.key);
    errdefer gpa.free(name);
    const val = try gpa.dupe(u8, args.value);
    errdefer gpa.free(val);
    const cand = models.CustomHeader{ .key = name, .value = val };
    try cand.validate();

    const old = prov.headers;
    const grown = try gpa.alloc(models.CustomHeader, old.len + 1);
    @memcpy(grown[0..old.len], old);
    grown[old.len] = cand;
    prov.headers = grown;
    if (old.len != 0) gpa.free(old);

    errdefer {
        var last = &prov.headers[prov.headers.len - 1];
        last.deinit(gpa);
        const shrunk = prov.headers[0 .. prov.headers.len - 1];
        gpa.free(prov.headers);
        prov.headers = shrunk;
    }
    try c.config.validate();

    var out: std.ArrayList(u8) = .empty;
    try appendHeaderJson(&out, req_alloc, &prov.headers[prov.headers.len - 1], prov.headers.len - 1);
    return out.items;
}

fn handleHeaderPut(c: *Controller, idx: usize, hidx: usize, body: []const u8, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    if (idx >= providerCount(
        c,
    )) return sendError(writer, 404, "bad provider index");
    if (body.len == 0) return sendError(writer, 400, "missing request body");
    const parsed = parseBody(alloc, body) orelse return sendError(writer, 400, "malformed JSON");
    defer parsed.deinit();
    const pair = parseHeaderBody(parsed.value) catch return sendError(writer, 400, "invalid field");
    var args = HeaderUpsertArgs{ .provider = idx, .header = hidx, .key = pair.key, .value = pair.value };
    return applyChange(c, alloc, writer, 200, opPutHeader, @ptrCast(&args));
}

fn opPutHeader(c: *Controller, ctx: *const anyopaque, req_alloc: Allocator) anyerror![]u8 {
    const args: *const HeaderUpsertArgs = @ptrCast(@alignCast(ctx));
    const gpa = c.alloc;
    if (args.provider >= c.config.providers.len) return error.BadProviderIndex;
    const prov = &c.config.providers[args.provider];
    if (args.header >= prov.headers.len) return error.BadHeaderIndex;

    const name = try gpa.dupe(u8, args.key);
    errdefer gpa.free(name);
    const val = try gpa.dupe(u8, args.value);
    errdefer gpa.free(val);
    const cand = models.CustomHeader{ .key = name, .value = val };
    try cand.validate();

    const slot = &prov.headers[args.header];
    const old_name = slot.key;
    const old_val = slot.value;
    slot.key = name;
    slot.value = val;
    errdefer {
        slot.key = old_name;
        slot.value = old_val;
    }
    try c.config.validate();
    gpa.free(old_name);
    gpa.free(old_val);

    var out: std.ArrayList(u8) = .empty;
    try appendHeaderJson(&out, req_alloc, slot, args.header);
    return out.items;
}

const HeaderIndexArg = struct {
    provider: usize,
    header: usize,
};

fn handleHeaderDelete(c: *Controller, idx: usize, hidx: usize, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    if (idx >= providerCount(
        c,
    )) return sendError(writer, 404, "bad provider index");
    var args = HeaderIndexArg{ .provider = idx, .header = hidx };
    return applyChange(c, alloc, writer, 200, opDeleteHeader, @ptrCast(&args));
}

fn opDeleteHeader(c: *Controller, ctx: *const anyopaque, req_alloc: Allocator) anyerror![]u8 {
    const args: *const HeaderIndexArg = @ptrCast(@alignCast(ctx));
    const gpa = c.alloc;
    if (args.provider >= c.config.providers.len) return error.BadProviderIndex;
    const prov = &c.config.providers[args.provider];
    if (args.header >= prov.headers.len) return error.BadHeaderIndex;
    prov.headers[args.header].deinit(gpa);
    std.mem.copyForwards(models.CustomHeader, prov.headers[args.header .. prov.headers.len - 1], prov.headers[args.header + 1 ..]);
    if (prov.headers.len - 1 == 0) {
        gpa.free(prov.headers);
        prov.headers = try gpa.alloc(models.CustomHeader, 0);
    } else {
        prov.headers = try gpa.realloc(prov.headers, prov.headers.len - 1);
    }
    try c.config.validate();
    return try std.fmt.allocPrint(req_alloc, "{{\"deleted\":true,\"index\":{d}}}", .{args.header});
}

// ---------------------------------------------------------------------------
// GET /api/models (lightweight mirror of proxy handleModels)
// ---------------------------------------------------------------------------

fn handleModels(c: *Controller, alloc: Allocator, writer: *std.Io.Writer) ?u16 {

    // Catalog JSON mirrors the proxy /v1/models surface plus enabled flags:
    //   {"free_mode":bool,"providers":[{"index":i,"display_name":"..","prefix":"oc/",
    //                  "models":[{"id":"oc/x","upstream_id":"x","context_window":N,"enabled":bool}]}]}
    // With free_mode on, non-free models are hidden from the listing.
    var out: std.ArrayList(u8) = .empty;
    c.mu.lock();
    const free_mode = c.config.free_mode;
    const hide_paid = c.config.hide_paid;
    c.mu.unlock();
    out.appendSlice(alloc, "{\"free_mode\":") catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, if (free_mode) "true" else "false") catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, ",\"hide_paid\":") catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, if (hide_paid) "true" else "false") catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, ",\"providers\":[") catch return sendError(writer, 500, "out of memory");
    c.mu.lock();
    var first = true;
    for (c.config.providers, 0..) |*p, pi| {
        if (p.models.len == 0) continue;
        if (!first) out.appendSlice(alloc, ",") catch {
            c.mu.unlock();
            return sendError(writer, 500, "out of memory");
        };
        first = false;
        out.appendSlice(alloc, "{\"index\":") catch {
            c.mu.unlock();
            return sendError(writer, 500, "out of memory");
        };
        out.appendSlice(alloc, std.fmt.allocPrint(alloc, "{d}", .{pi}) catch {
            c.mu.unlock();
            return sendError(writer, 500, "out of memory");
        }) catch {
            c.mu.unlock();
            return sendError(writer, 500, "out of memory");
        };
        out.appendSlice(alloc, ",\"display_name\":") catch {
            c.mu.unlock();
            return sendError(writer, 500, "out of memory");
        };
        appendQuoted(&out, alloc, p.display_name) catch {
            c.mu.unlock();
            return sendError(writer, 500, "out of memory");
        };
        out.appendSlice(alloc, ",\"prefix\":") catch {
            c.mu.unlock();
            return sendError(writer, 500, "out of memory");
        };
        appendQuoted(&out, alloc, p.prefix) catch {
            c.mu.unlock();
            return sendError(writer, 500, "out of memory");
        };
        out.appendSlice(alloc, ",\"models\":[") catch {
            c.mu.unlock();
            return sendError(writer, 500, "out of memory");
        };
        var m_first = true;
        for (p.models, 0..) |*m, mi| {
            // Hide-paid / free mode hide non-free models from the listing;
            // /v1/models itself filters by enabled.
            if ((hide_paid or free_mode) and !m.isFree()) continue;
            if (!m_first) out.appendSlice(alloc, ",") catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            m_first = false;
            out.appendSlice(alloc, "{\"index\":") catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            out.appendSlice(alloc, std.fmt.allocPrint(alloc, "{d}", .{mi}) catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            }) catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            out.appendSlice(alloc, ",\"id\":") catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            appendQuoted(&out, alloc, m.id) catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            out.appendSlice(alloc, ",\"upstream_id\":") catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            appendQuoted(&out, alloc, m.upstream_id) catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            out.appendSlice(alloc, ",\"context_window\":") catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            out.appendSlice(alloc, std.fmt.allocPrint(alloc, "{d}", .{m.context_window}) catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            }) catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            out.appendSlice(alloc, ",\"enabled\":") catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            out.appendSlice(alloc, if (m.enabled) "true" else "false") catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            out.appendSlice(alloc, ",\"is_free\":") catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            out.appendSlice(alloc, if (m.isFree()) "true" else "false") catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            out.appendSlice(alloc, ",\"reasoning\":") catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            out.appendSlice(alloc, if (m.supports_reasoning) "true" else "false") catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            out.appendSlice(alloc, ",\"reasoning_levels\":") catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
            if (m.reasoning_levels.len != 0 and !models.isLegacyReasoningLevels(m.reasoning_levels)) {
                appendQuoted(&out, alloc, m.reasoning_levels) catch {
                    c.mu.unlock();
                    return sendError(writer, 500, "out of memory");
                };
            } else {
                // Legacy cache entries: serve the default set.
                appendQuoted(&out, alloc, proxy_mod.default_reasoning_levels) catch {
                    c.mu.unlock();
                    return sendError(writer, 500, "out of memory");
                };
            }
            out.appendSlice(alloc, "}") catch {
                c.mu.unlock();
                return sendError(writer, 500, "out of memory");
            };
        }
        out.appendSlice(alloc, "]}") catch {
            c.mu.unlock();
            return sendError(writer, 500, "out of memory");
        };
    }
    c.mu.unlock();
    out.appendSlice(alloc, "]}") catch return sendError(writer, 500, "out of memory");
    sendJson(writer, 200, out.items) catch {};
    return 200;
}

/// PATCH /api/models/{p}/{m}  body {"enabled":bool} and/or
/// {"context_window":N} (direct in-place fields; persisted immediately).
fn handleModelPatch(c: *Controller, p_raw: []const u8, m_raw: []const u8, body: []const u8, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    const p_idx = parseIndex(p_raw) orelse return sendError(writer, 404, "bad provider index");
    const m_idx = parseIndex(m_raw) orelse return sendError(writer, 404, "bad model index");
    if (body.len == 0) return sendError(writer, 400, "missing request body");
    const parsed = parseBody(alloc, body) orelse return sendError(writer, 400, "malformed JSON");
    defer parsed.deinit();
    const enabled = optBool(parsed.value, "enabled") catch return sendError(writer, 400, "invalid field");
    const ctx = optInt(parsed.value, u64, "context_window") catch return sendError(writer, 400, "invalid field");
    const levels = optString(parsed.value, "reasoning_levels") catch return sendError(writer, 400, "invalid field");
    if (enabled == null and ctx == null and levels == null) return sendError(writer, 400, "invalid field");
    if (ctx != null and ctx.? > 10_000_000) return sendError(writer, 400, "invalid field");

    c.mu.lock();
    if (p_idx >= c.config.providers.len) {
        c.mu.unlock();
        return sendError(writer, 404, "bad provider index");
    }
    const prov = &c.config.providers[p_idx];
    if (m_idx >= prov.models.len) {
        c.mu.unlock();
        return sendError(writer, 404, "bad model index");
    }
    const model = &prov.models[m_idx];
    const id_copy = alloc.dupe(u8, model.id) catch {
        c.mu.unlock();
        return sendError(writer, 500, "out of memory");
    };
    const old_enabled = model.enabled;
    const old_ctx = model.context_window;
    const old_levels = model.reasoning_levels;
    if (enabled) |e| model.enabled = e;
    if (ctx) |x| model.context_window = x;
    if (levels) |lv| {
        // Normalize: split on commas, trim, drop empties, lowercase, join.
        const gpa2 = c.alloc;
        const owned = normalizeLevels(gpa2, lv) catch {
            c.mu.unlock();
            alloc.free(id_copy);
            return sendError(writer, 500, "out of memory");
        };
        model.reasoning_levels = owned;
        if (owned.len != 0) model.supports_reasoning = true;
    }
    c.config.validate() catch {
        c.mu.unlock();
        alloc.free(id_copy);
        return sendError(writer, 500, "invalid config after patch");
    };
    // Persist immediately (no restart: all fields are read per request).
    c.metrics.syncConfig(c.alloc, c.config) catch {};
    config_mod.saveToPath(c.alloc, c.io, c.config, c.config_path) catch |err| {
        // Roll back in-memory fields; the freshly normalized levels string
        // is owned by us, the restored one lives on.
        if (levels) |lv| {
            const new_owned = model.reasoning_levels;
            model.reasoning_levels = old_levels;
            if (new_owned.ptr != old_levels.ptr) c.alloc.free(new_owned);
            _ = lv;
        }
        model.enabled = old_enabled;
        model.context_window = old_ctx;
        c.mu.unlock();
        alloc.free(id_copy);
        c.log.err("dashboard: model patch save failed: {s}", .{@errorName(err)});
        return sendError(writer, 500, @errorName(err));
    };
    // Save succeeded: the replaced levels string is no longer referenced.
    if (levels != null and old_levels.len != 0 and old_levels.ptr != model.reasoning_levels.ptr) {
        c.alloc.free(old_levels);
    }
    c.mu.unlock();
    defer alloc.free(id_copy);
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(alloc, "{\"id\":") catch return sendError(writer, 500, "out of memory");
    appendQuoted(&out, alloc, id_copy) catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, std.fmt.allocPrint(alloc, ",\"enabled\":{s},\"context_window\":{d},\"reasoning_levels\":", .{
        if (enabled orelse old_enabled) "true" else "false",
        ctx orelse old_ctx,
    }) catch return sendError(writer, 500, "out of memory")) catch return sendError(writer, 500, "out of memory");
    // Snapshot the (possibly new) levels under a short lock for the reply.
    c.mu.lock();
    const levels_reply = alloc.dupe(u8, model.reasoning_levels) catch "";
    c.mu.unlock();
    appendQuoted(&out, alloc, levels_reply) catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, "}") catch return sendError(writer, 500, "out of memory");
    sendJson(writer, 200, out.items) catch {};
    return 200;
}

/// Normalize a comma-separated reasoning level list: trim, drop empties,
/// lowercase, dedupe (first wins), join with commas. Owned by gpa.
fn normalizeLevels(gpa: Allocator, raw: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var it = std.mem.splitScalar(u8, raw, ',');
    var seen: [16][]const u8 = undefined;
    var seen_n: usize = 0;
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t");
        if (part.len == 0) continue;
        var dup = false;
        for (seen[0..seen_n]) |s| {
            if (std.ascii.eqlIgnoreCase(s, part)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (seen_n < seen.len) {
            seen[seen_n] = part;
            seen_n += 1;
        }
        if (buf.items.len != 0) try buf.appendSlice(gpa, ",");
        for (part) |ch| try buf.append(gpa, std.ascii.toLower(ch));
    }
    return buf.toOwnedSlice(gpa);
}

/// One parallel fetch job: one provider, one upstream /models document.
const FetchJob = struct {
    c: *Controller,
    p_idx: usize,
    ki: ?usize,
    alloc: Allocator,
    body: ?[]u8 = null,
    failed: bool = false,
};

fn fetchJobTask(j: *FetchJob) void {
    j.body = proxy_mod.fetchModelsBody(j.c.proxy, j.alloc, j.p_idx, j.ki) catch {
        j.failed = true;
        return;
    };
}

/// Refresh every provider's model catalog. Fetches run in parallel on the
/// pool (one task per provider), so the total wait is the slowest single
/// provider, not the sum. Catalog swaps stay serialized on the proxy
/// catalog mutex. Never aborts on one bad provider.
fn refreshModelsInline(c: *Controller, alloc: Allocator) !usize {
    const n_providers = c.config.providers.len;
    if (n_providers == 0 or n_providers > 64) return 0;

    const jobs = try alloc.alloc(FetchJob, n_providers);
    const futures = try alloc.alloc(std.Io.Future(void), n_providers);

    for (c.config.providers, 0..) |*prov, p_idx| {
        jobs[p_idx] = .{
            .c = c,
            .p_idx = p_idx,
            .ki = firstUsableKey(prov, nowUnixSec()),
            .alloc = alloc,
        };
        // Fire each fetch on the pool; failures are recorded on the job.
        futures[p_idx] = std.Io.async(c.io, fetchJobTask, .{&jobs[p_idx]});
    }
    // Drain: each await blocks this worker until its fetch lands.
    for (futures) |*fut| fut.await(c.io);
    var total: usize = 0;
    for (jobs) |*j| {
        const prov = &c.config.providers[j.p_idx];
        if (j.failed) {
            c.log.warn("models refresh \"{s}\" failed", .{prov.display_name});
            continue;
        }
        defer if (j.body) |b| alloc.free(b);
        // Rebuild the cache from the raw body (preserves enabled flags and
        // user-edited reasoning levels).
        const n = proxy_mod.updateProviderCatalog(c.proxy, j.p_idx, j.body.?, alloc) catch |err| {
            c.log.warn("models refresh \"{s}\" cache update failed: {s}", .{ prov.display_name, @errorName(err) });
            continue;
        };
        total += n;
    }
    // Re-assert the paid-model policy on freshly fetched entries.
    if (c.config.hide_paid or c.config.free_mode) sweepFreeOnly(c, true);
    return total;
}

/// POST /api/models: refresh catalogs in place. No stop/start cycle: the
/// catalog swap is guarded by the proxy catalog mutex and the config file
/// save is atomic, so the proxy keeps serving throughout.
fn handleModelsRefresh(c: *Controller, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    const total = refreshModelsInline(c, alloc) catch |err|
        return sendError(writer, 500, @errorName(err));
    c.mu.lock();
    c.metrics.syncConfig(c.alloc, c.config) catch {};
    config_mod.saveToPath(c.alloc, c.io, c.config, c.config_path) catch |err| {
        c.mu.unlock();
        c.log.warn("models refresh save failed: {s}", .{@errorName(err)});
        const body = std.fmt.allocPrint(alloc, "{{\"refreshed\":true,\"total\":{d},\"saved\":false}}", .{total}) catch "{}";
        sendJson(writer, 200, body) catch {};
        return 200;
    };
    c.mu.unlock();
    const body = std.fmt.allocPrint(alloc, "{{\"refreshed\":true,\"total\":{d}}}", .{total}) catch "{}";
    sendJson(writer, 200, body) catch {};
    return 200;
}

// ---------------------------------------------------------------------------
// GET /api/usage: lifetime token totals + per-day buckets
// ---------------------------------------------------------------------------

fn handleUsageGet(c: *Controller, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    var days_buf: [metrics_mod.usage_days_cap]metrics_mod.UsageDay = undefined;
    const snap = c.metrics.usageSnapshot(&days_buf);
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(alloc, "{\"total_in\":") catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, std.fmt.allocPrint(alloc, "{d}", .{snap.total_in}) catch {
        return sendError(writer, 500, "out of memory");
    }) catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, ",\"total_out\":") catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, std.fmt.allocPrint(alloc, "{d}", .{snap.total_out}) catch {
        return sendError(writer, 500, "out of memory");
    }) catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, ",\"total_cached\":") catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, std.fmt.allocPrint(alloc, "{d}", .{snap.total_cached}) catch {
        return sendError(writer, 500, "out of memory");
    }) catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, ",\"total_requests\":") catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, std.fmt.allocPrint(alloc, "{d}", .{snap.total_requests}) catch {
        return sendError(writer, 500, "out of memory");
    }) catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, ",\"days\":[") catch return sendError(writer, 500, "out of memory");
    for (snap.days, 0..) |d, i| {
        if (i != 0) out.appendSlice(alloc, ",") catch return sendError(writer, 500, "out of memory");
        const day_json = std.fmt.allocPrint(
            alloc,
            "{{\"day\":{d},\"in\":{d},\"out\":{d},\"cached\":{d},\"requests\":{d}}}",
            .{ d.day, d.input, d.output, d.cached, d.requests },
        ) catch return sendError(writer, 500, "out of memory");
        out.appendSlice(alloc, day_json) catch return sendError(writer, 500, "out of memory");
    }
    out.appendSlice(alloc, "],\"models\":") catch return sendError(writer, 500, "out of memory");
    const model_usage = c.metrics.modelUsageSnapshot(alloc) catch return sendError(writer, 500, "out of memory");
    const model_json = std.json.Stringify.valueAlloc(alloc, model_usage, .{}) catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, model_json) catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, "}") catch return sendError(writer, 500, "out of memory");
    sendJson(writer, 200, out.items) catch {};
    return 200;
}

// ---------------------------------------------------------------------------
// GET /api/logs[/<n>]
// ---------------------------------------------------------------------------

fn handleLogs(c: *Controller, segs: [][]const u8, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    var want: usize = 100;
    if (segs.len == 4) {
        want = parseIndex(segs[3]) orelse return sendError(writer, 400, "invalid log count");
    } else if (segs.len != 3) {
        return null;
    }
    want = @min(want, logger_mod.capacity);

    const lines = alloc.alloc(logger_mod.LogLine, want) catch return sendError(writer, 500, "out of memory");
    const n = c.log.latest(lines[0..want]);

    var out: std.ArrayList(u8) = .empty;
    const head = std.fmt.allocPrint(alloc, "{{\"logs\":[", .{}) catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, head) catch return sendError(writer, 500, "out of memory");
    for (lines[0..n], 0..) |*line, i| {
        if (i != 0) out.appendSlice(alloc, ",") catch return sendError(writer, 500, "out of memory");
        const entry_head = std.fmt.allocPrint(
            alloc,
            "{{\"seq\":{d},\"timestamp_ms\":{d},\"level\":\"{s}\",\"msg\":",
            .{ line.seq, line.timestamp_ms, line.level.tag() },
        ) catch return sendError(writer, 500, "out of memory");
        out.appendSlice(alloc, entry_head) catch return sendError(writer, 500, "out of memory");
        appendQuoted(&out, alloc, line.text()) catch return sendError(writer, 500, "out of memory");
        out.appendSlice(alloc, "}") catch return sendError(writer, 500, "out of memory");
    }
    const tail = std.fmt.allocPrint(alloc, "],\"count\":{d}}}", .{n}) catch return sendError(writer, 500, "out of memory");
    out.appendSlice(alloc, tail) catch return sendError(writer, 500, "out of memory");
    sendJson(writer, 200, out.items) catch {};
    return 200;
}

// ---------------------------------------------------------------------------
// GET/PUT /api/settings
// ---------------------------------------------------------------------------

fn handleSettingsGet(c: *Controller, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    var out: std.ArrayList(u8) = .empty;
    c.mu.lock();
    appendSettingsJson(&out, alloc, c.config) catch {
        c.mu.unlock();
        return sendError(writer, 500, "out of memory");
    };
    c.mu.unlock();
    sendJson(writer, 200, out.items) catch {};
    return 200;
}

const SettingsArgs = struct {
    port: ?u16,
    auto_start: ?bool,
    cooldown_secs: ?u64,
    timeout_ms: ?u32,
    free_mode: ?bool,
    hide_paid: ?bool,
};

fn handleSettingsPut(c: *Controller, body: []const u8, alloc: Allocator, writer: *std.Io.Writer) ?u16 {
    if (body.len == 0) return sendError(writer, 400, "missing request body");
    const parsed = parseBody(alloc, body) orelse return sendError(writer, 400, "malformed JSON");
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return sendError(writer, 400, "invalid field");

    var args = SettingsArgs{
        .port = optInt(root, u16, "port") catch return sendError(writer, 400, "invalid field"),
        .auto_start = optBool(root, "auto_start") catch return sendError(writer, 400, "invalid field"),
        .cooldown_secs = optInt(root, u64, "cooldown_secs") catch return sendError(writer, 400, "invalid field"),
        .timeout_ms = optInt(root, u32, "timeout_ms") catch return sendError(writer, 400, "invalid field"),
        .free_mode = optBool(root, "free_mode") catch return sendError(writer, 400, "invalid field"),
        .hide_paid = optBool(root, "hide_paid") catch return sendError(writer, 400, "invalid field"),
    };
    _ = &args;
    return applyChange(c, alloc, writer, 200, opPutSettings, @ptrCast(&args));
}

/// One sweep of the model catalog: when `only_free` is on, every non-free
/// model is deactivated; when off, everything is re-enabled.
fn sweepFreeOnly(c: *Controller, only_free: bool) void {
    for (c.config.providers) |*prov| {
        for (prov.models) |*m| {
            if (only_free) {
                if (!m.isFree()) m.enabled = false;
            } else {
                m.enabled = true;
            }
        }
    }
}

fn opPutSettings(c: *Controller, ctx: *const anyopaque, req_alloc: Allocator) anyerror![]u8 {
    const args: *const SettingsArgs = @ptrCast(@alignCast(ctx));
    const old_port = c.config.port;
    const old_auto = c.config.auto_start;
    const old_cool = c.config.cooldown_secs;
    const old_timeout = c.config.timeout_ms;
    const old_free = c.config.free_mode;
    const old_hide = c.config.hide_paid;
    if (args.port) |p| c.config.port = p;
    if (args.auto_start) |a| c.config.auto_start = a;
    if (args.cooldown_secs) |s| c.config.cooldown_secs = s;
    if (args.timeout_ms) |t| c.config.timeout_ms = t;
    if (args.free_mode) |f| {
        const was = c.config.free_mode;
        c.config.free_mode = f;
        if (f and !was) sweepFreeOnly(c, true);
        if (!f and was) sweepFreeOnly(c, false);
    }
    if (args.hide_paid) |h| {
        const was = c.config.hide_paid;
        c.config.hide_paid = h;
        if (h and !was) sweepFreeOnly(c, true);
        if (!h and was) sweepFreeOnly(c, false);
    }
    errdefer {
        c.config.port = old_port;
        c.config.auto_start = old_auto;
        c.config.cooldown_secs = old_cool;
        c.config.timeout_ms = old_timeout;
        c.config.free_mode = old_free;
        c.config.hide_paid = old_hide;
    }
    // Full validation: a bad port or timeout rolls the scalars back above.
    // The port rebind itself happens in applyChange via stop/start.
    try c.config.validate();
    var out: std.ArrayList(u8) = .empty;
    try appendSettingsJson(&out, req_alloc, c.config);
    return out.items;
}

// ---------------------------------------------------------------------------
// Unit tests (pure helpers only, no sockets)
// ---------------------------------------------------------------------------

test "stripTrailingSlash keeps root and trims one level" {
    try std.testing.expectEqualStrings("/", stripTrailingSlash("/"));
    try std.testing.expectEqualStrings("/api/logs", stripTrailingSlash("/api/logs/"));
    try std.testing.expectEqualStrings("/api/logs", stripTrailingSlash("/api/logs"));
}

test "splitSegments and parseIndex cover routing shapes" {
    var buf: [8][]const u8 = undefined;
    const n = splitSegments("/api/providers/3/keys/1", &buf);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualStrings("providers", buf[2]);
    try std.testing.expectEqualStrings("1", buf[5]);
    try std.testing.expectEqual(@as(?usize, 3), parseIndex("3"));
    try std.testing.expectEqual(@as(?usize, null), parseIndex(""));
    try std.testing.expectEqual(@as(?usize, null), parseIndex("3x"));
    try std.testing.expectEqual(@as(?usize, null), parseIndex("-1"));
}

test "maskKeyId hides all but the last four chars" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("***1234", maskKeyId("sk-abcdef1234", &buf));
    try std.testing.expectEqualStrings("***ab", maskKeyId("ab", &buf));
    try std.testing.expectEqualStrings("***", maskKeyId("", &buf));
}

test "prefixWithSlash appends a missing trailing slash" {
    const alloc = std.testing.allocator;
    const a = try prefixWithSlash(alloc, "kilo");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("kilo/", a);
    const b = try prefixWithSlash(alloc, "oc/");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("oc/", b);
}

test "trimKey drops surrounding whitespace" {
    try std.testing.expectEqualStrings("abc", trimKey("  abc \t\r\n"));
    try std.testing.expectEqualStrings("", trimKey("   "));
}

test "isValidateError separates config errors from runtime errors" {
    try std.testing.expect(isValidateError(error.DuplicatePrefix));
    try std.testing.expect(isValidateError(error.InvalidPort));
    try std.testing.expect(isValidateError(error.EmptyHeaderName));
    try std.testing.expect(!isValidateError(error.OutOfMemory));
    try std.testing.expect(!isValidateError(FieldError.BadField));
}

test "appendKeyJson never emits full key material" {
    const alloc = std.testing.allocator;
    var key = models.Key{ .key = "sk-super-secret-9876", .state = .Active, .enabled = true };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendKeyJson(&out, alloc, &key, 0, nowUnixSec());
    try std.testing.expect(std.mem.indexOf(u8, out.items, "sk-super-secret-9876") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "***9876") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"Active\"") != null);
}

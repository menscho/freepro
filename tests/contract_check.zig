// tests/contract_check.zig — Wave3-Task08: cross-module shared-contract checks.
//
// Asserts that the contracts shared across modules still match: models
// Key/Provider/ProxyConfig fields, rotator nextHealthyKey/reportResult arity,
// upstream ForwardResult/Endpoint, metrics snapshot/sparkline, logger failover
// format, and the app Views/ViewFn/ServerHooks shell contract.
//
// RUN (from the project root, D:/freepro):
//   zig test --dep rotator --dep metrics --dep logger -Mmain=tests/contract_check.zig -Mrotator=src/rotator.zig -Mmetrics=src/metrics.zig -Mlogger=src/logger.zig
//
// Named imports match the convention documented in build.zig ("test roots may
// use either relative or @import(\"<name>\") style"). Plain
// `zig test tests/contract_check.zig` cannot work: on Zig 0.16 a test root is
// confined to its own directory, so `../src/*.zig` escapes are rejected.
//
// Import strategy (forced by two toolchain rules, both verified by probe):
//   * A module rooted under src/ui/ cannot `@import("../*.zig")`, so
//     src/ui/app.zig and src/ui/views_*.zig are unimportable as modules. Their
//     contract surface is pinned by source-text markers instead.
//   * One file may belong to only one module, so a single test binary can
//     import at most ONE of models/rotator/upstream/config (each pulls in
//     src/models.zig). This file imports rotator: its private models copy is
//     the same file the proxy actually rotates on, and every models shape is
//     re-pinned here both as a type check (via introspection) and as a source
//     marker on src/models.zig. Upstream is pinned by source markers.

const std = @import("std");
const rotator = @import("rotator");
const metrics = @import("metrics");
const logger = @import("logger");

const testing = std.testing;

// Models types as seen by the rotator (same src/models.zig file, proxy-facing
// copy). Shape checks below keep this copy pinned to the models contract.
const RCfg = @typeInfo(@typeInfo(@TypeOf(rotator.Rotator.init)).@"fn".params[1].type.?).pointer.child;
const RProv = @typeInfo(@FieldType(RCfg, "providers")).pointer.child;
const RKey = @typeInfo(@FieldType(RProv, "keys")).pointer.child;
const RKeyState = rotator.KeyState;

// ---------------------------------------------------------------------------
// Compile-time contract assertions. A violation fails the build with the
// message below, pointing at the module pair that drifted.
// ---------------------------------------------------------------------------

comptime {
    // -- models.Key (via the rotator's copy of src/models.zig) --
    for ([_][]const u8{ "key", "state", "last_used", "cooldown_until", "consecutive_errors", "enabled" }) |f| {
        if (!@hasField(RKey, f)) @compileError("contract: models.Key field missing");
    }
    if (@FieldType(RKey, "key") != []const u8) @compileError("contract: models.Key.key must be []const u8");
    if (@FieldType(RKey, "last_used") != i64) @compileError("contract: models.Key.last_used must be i64");
    if (@FieldType(RKey, "cooldown_until") != i64) @compileError("contract: models.Key.cooldown_until must be i64");
    if (@FieldType(RKey, "consecutive_errors") != u32) @compileError("contract: models.Key.consecutive_errors must be u32");
    if (@FieldType(RKey, "enabled") != bool) @compileError("contract: models.Key.enabled must be bool");
    if (!@hasField(RKeyState, "Active")) @compileError("contract: models.KeyState.Active missing");
    if (!@hasField(RKeyState, "CoolingDown")) @compileError("contract: models.KeyState.CoolingDown missing");
    if (!@hasField(RKeyState, "Dead")) @compileError("contract: models.KeyState.Dead missing");
    for ([_][]const u8{ "init", "validate", "isUsable", "tryPromote", "markSuccess", "markCooldown", "markDead", "clone", "deinit" }) |m| {
        if (!@hasDecl(RKey, m)) @compileError("contract: models.Key method missing");
    }
    if (@typeInfo(@TypeOf(RKey.isUsable)).@"fn".params.len != 2) @compileError("contract: Key.isUsable arity");
    if (@typeInfo(@TypeOf(RKey.isUsable)).@"fn".return_type.? != bool) @compileError("contract: Key.isUsable must return bool");
    if (@typeInfo(@TypeOf(RKey.markCooldown)).@"fn".params.len != 3) @compileError("contract: Key.markCooldown arity");

    // -- models.Provider --
    for ([_][]const u8{ "display_name", "base_url", "prefix", "description", "keys", "headers" }) |f| {
        if (!@hasField(RProv, f)) @compileError("contract: models.Provider field missing");
    }
    for ([_][]const u8{ "validate", "activeKeyCount", "usableKeyCount", "findHeader", "claimsModel", "stripPrefix", "clone", "deinit" }) |m| {
        if (!@hasDecl(RProv, m)) @compileError("contract: models.Provider method missing");
    }

    // -- models.ProxyConfig --
    for ([_][]const u8{ "port", "providers", "auto_start", "cooldown_secs", "timeout_ms" }) |f| {
        if (!@hasField(RCfg, f)) @compileError("contract: models.ProxyConfig field missing");
    }
    if (@FieldType(RCfg, "port") != u16) @compileError("contract: ProxyConfig.port must be u16");
    if (@FieldType(RCfg, "auto_start") != bool) @compileError("contract: ProxyConfig.auto_start must be bool");
    if (@FieldType(RCfg, "cooldown_secs") != u64) @compileError("contract: ProxyConfig.cooldown_secs must be u64");
    if (@FieldType(RCfg, "timeout_ms") != u32) @compileError("contract: ProxyConfig.timeout_ms must be u32");
    for ([_][]const u8{ "validate", "findProviderForModel", "routeModel", "clone", "deinit", "defaultConfig" }) |m| {
        if (!@hasDecl(RCfg, m)) @compileError("contract: models.ProxyConfig method missing");
    }

    // -- rotator surface + arity --
    if (!@hasDecl(rotator, "Rotator")) @compileError("contract: rotator.Rotator missing");
    if (!@hasDecl(rotator, "KeySelection")) @compileError("contract: rotator.KeySelection missing");
    if (!@hasDecl(rotator, "HealthCounts")) @compileError("contract: rotator.HealthCounts missing");
    if (rotator.default_max_consecutive_errors != 3) @compileError("contract: default_max_consecutive_errors must be 3");
    if (@FieldType(rotator.KeySelection, "provider_index") != usize) @compileError("contract: KeySelection.provider_index must be usize");
    if (@FieldType(rotator.KeySelection, "key_index") != usize) @compileError("contract: KeySelection.key_index must be usize");
    const R = rotator.Rotator;
    for ([_][]const u8{ "init", "deinit", "nextHealthyKey", "nextHealthy", "reportHttpStatus", "reportTimeout", "reportTransportError", "reportResult", "healthCounts", "snapshotKey", "setClock", "reviveKey", "forceCooldown", "markDead" }) |m| {
        if (!@hasDecl(R, m)) @compileError("contract: rotator.Rotator method missing");
    }
    {
        const sig = @typeInfo(@TypeOf(R.nextHealthyKey)).@"fn";
        if (sig.params.len != 2) @compileError("contract: nextHealthyKey(provider_index) arity");
        if (sig.params[1].type.? != usize) @compileError("contract: nextHealthyKey takes usize provider_index");
        if (sig.return_type.? != ?usize) @compileError("contract: nextHealthyKey must return ?usize");
    }
    {
        const sig = @typeInfo(@TypeOf(R.nextHealthy)).@"fn";
        if (sig.params.len != 2) @compileError("contract: nextHealthy(provider_index) arity");
        if (sig.return_type.? != ?rotator.KeySelection) @compileError("contract: nextHealthy must return ?KeySelection");
    }
    {
        const sig = @typeInfo(@TypeOf(R.reportResult)).@"fn";
        if (sig.params.len != 4) @compileError("contract: reportResult(provider,key,status) arity");
        if (sig.params[1].type.? != usize) @compileError("contract: reportResult provider_index must be usize");
        if (sig.params[2].type.? != usize) @compileError("contract: reportResult key_index must be usize");
        if (sig.params[3].type.? != ?u16) @compileError("contract: reportResult status must be ?u16");
        if (sig.return_type.? != void) @compileError("contract: reportResult must return void");
    }
    {
        const sig = @typeInfo(@TypeOf(R.reportHttpStatus)).@"fn";
        if (sig.params.len != 4) @compileError("contract: reportHttpStatus(provider,key,status) arity");
        if (sig.params[3].type.? != u16) @compileError("contract: reportHttpStatus status must be u16");
    }

    // -- metrics surface --
    if (!@hasDecl(metrics, "Metrics")) @compileError("contract: metrics.Metrics missing");
    if (!@hasDecl(metrics, "Snapshot")) @compileError("contract: metrics.Snapshot missing");
    if (metrics.max_providers != 16) @compileError("contract: max_providers must be 16");
    if (metrics.latency_cap != 120) @compileError("contract: latency_cap must be 120");
    const Snap = metrics.Snapshot;
    for ([_][]const u8{ "total_requests", "active_inflight", "total_errors", "total_failovers", "provider_count", "per_provider", "samples", "avg_latency_ms", "max_latency_ms", "last_latency_ms" }) |f| {
        if (!@hasField(Snap, f)) @compileError("contract: metrics.Snapshot field missing");
    }
    if (@FieldType(Snap, "avg_latency_ms") != f64) @compileError("contract: Snapshot.avg_latency_ms must be f64");
    const M = metrics.Metrics;
    for ([_][]const u8{ "init", "setProviderCount", "begin", "end", "record", "noteFailover", "total", "inflight", "snapshot", "sparkline", "copyLatencies", "reset" }) |m| {
        if (!@hasDecl(M, m)) @compileError("contract: metrics.Metrics method missing");
    }
    {
        const sig = @typeInfo(@TypeOf(M.snapshot)).@"fn";
        if (sig.params.len != 1) @compileError("contract: snapshot() arity");
        if (sig.return_type.? != Snap) @compileError("contract: snapshot() must return Snapshot");
    }
    {
        const sig = @typeInfo(@TypeOf(M.sparkline)).@"fn";
        if (sig.params.len != 2) @compileError("contract: sparkline(out) arity");
        if (sig.params[1].type.? != []f32) @compileError("contract: sparkline takes []f32");
        if (sig.return_type.? != usize) @compileError("contract: sparkline must return usize");
    }

    // -- logger surface --
    if (!@hasDecl(logger, "Logger")) @compileError("contract: logger.Logger missing");
    if (!@hasDecl(logger, "Subscriber")) @compileError("contract: logger.Subscriber missing");
    if (!@hasDecl(logger, "LogLine")) @compileError("contract: logger.LogLine missing");
    if (!@hasDecl(logger, "Level")) @compileError("contract: logger.Level missing");
    if (logger.capacity != 512) @compileError("contract: logger capacity must be 512");
    if (logger.max_msg_len != 256) @compileError("contract: logger max_msg_len must be 256");
    for ([_][]const u8{ "info", "request", "failover", "warn", "err" }) |v| {
        if (!@hasField(logger.Level, v)) @compileError("contract: logger.Level variant missing");
    }
    for ([_][]const u8{ "seq", "timestamp_ms", "level", "len", "msg" }) |f| {
        if (!@hasField(logger.LogLine, f)) @compileError("contract: logger.LogLine field missing");
    }
    const L = logger.Logger;
    for ([_][]const u8{ "init", "push", "info", "warn", "err", "failover", "logRequest", "len", "latest", "drainSince", "subscriber" }) |m| {
        if (!@hasDecl(L, m)) @compileError("contract: logger.Logger method missing");
    }
    {
        const sig = @typeInfo(@TypeOf(L.failover)).@"fn";
        if (sig.params.len != 4) @compileError("contract: failover(from,status,to) arity");
        if (sig.params[1].type.? != usize) @compileError("contract: failover from_key must be usize");
        if (sig.params[2].type.? != u16) @compileError("contract: failover status must be u16");
        if (sig.params[3].type.? != usize) @compileError("contract: failover to_key must be usize");
    }
    if (!@hasDecl(logger.Subscriber, "poll")) @compileError("contract: Subscriber.poll missing");
    if (!@hasDecl(logger.Subscriber, "skipBacklog")) @compileError("contract: Subscriber.skipBacklog missing");
    if (!@hasDecl(logger, "formatTimeOfDay")) @compileError("contract: formatTimeOfDay missing");
}

// ---------------------------------------------------------------------------
// Runtime contract tests.
// ---------------------------------------------------------------------------

test "models: key state machine matches the rotation contract" {
    var k = RKey.init("sk-test-1");
    try testing.expect(k.isUsable(1_000));
    try testing.expectEqual(RKeyState.Active, k.state);
    try testing.expect(k.enabled);

    k.markCooldown(1_000, 60);
    try testing.expectEqual(RKeyState.CoolingDown, k.state);
    try testing.expect(!k.isUsable(1_030));
    try testing.expect(k.tryPromote(1_060));
    try testing.expectEqual(RKeyState.Active, k.state);

    k.markDead(2_000);
    try testing.expectEqual(RKeyState.Dead, k.state);
    try testing.expect(!k.isUsable(99_999_999));

    k.markSuccess(3_000);
    try testing.expectEqual(RKeyState.Active, k.state);
    try testing.expectEqual(@as(u32, 0), k.consecutive_errors);
    try testing.expectEqual(@as(i64, 3_000), k.last_used);
}

var contract_now: i64 = 1_700_000_000;

fn contractClock() i64 {
    return contract_now;
}

fn makeTwoKeyConfig(alloc: std.mem.Allocator) !struct { cfg: RCfg, keys: []RKey, provs: []RProv } {
    var keys = try alloc.alloc(RKey, 2);
    errdefer alloc.free(keys);
    keys[0] = .{ .key = "sk-a" };
    keys[1] = .{ .key = "sk-b" };
    var provs = try alloc.alloc(RProv, 1);
    errdefer alloc.free(provs);
    provs[0] = .{
        .display_name = "T",
        .base_url = "https://example.invalid/",
        .prefix = "t/",
        .description = "t",
        .keys = keys,
        .headers = &.{},
    };
    return .{
        .cfg = .{
            .port = 8080,
            .providers = provs,
            .auto_start = false,
            .cooldown_secs = 60,
            .timeout_ms = 5_000,
        },
        .keys = keys,
        .provs = provs,
    };
}

test "rotator: selection and reporting honor the shared classifiers" {
    const alloc = testing.allocator;
    const R = rotator.Rotator;

    var fix = try makeTwoKeyConfig(alloc);
    defer alloc.free(fix.keys);
    defer alloc.free(fix.provs);

    contract_now = 1_700_000_000;
    var rot = try R.init(alloc, &fix.cfg);
    defer rot.deinit();
    rot.setClock(contractClock);

    // Round-robin over healthy keys.
    try testing.expectEqual(@as(?usize, 0), rot.nextHealthyKey(0));
    try testing.expectEqual(@as(?usize, 1), rot.nextHealthyKey(0));
    const sel = rot.nextHealthy(0).?;
    try testing.expectEqual(@as(usize, 0), sel.provider_index);
    try testing.expectEqual(@as(usize, 0), sel.key_index);

    // 429 cools down: skipped, then reactivated after expiry.
    rot.reportResult(0, 0, 429);
    try testing.expectEqual(RKeyState.CoolingDown, rot.snapshotKey(0, 0).?.state);
    try testing.expectEqual(@as(?usize, 1), rot.nextHealthyKey(0));
    contract_now += 61;
    // Promotion is lazy: the next selection reactivates the expired cooldown.
    try testing.expectEqual(@as(?usize, 0), rot.nextHealthyKey(0));
    try testing.expectEqual(RKeyState.Active, rot.snapshotKey(0, 0).?.state);

    // 401 kills permanently; null (timeout) cools down; the 0 sentinel (shared
    // with upstream.status_timeout) cools down like a timeout.
    rot.reportResult(0, 0, 401);
    try testing.expectEqual(RKeyState.Dead, rot.snapshotKey(0, 0).?.state);
    rot.reportResult(0, 1, null);
    try testing.expect(rot.nextHealthyKey(0) == null);
    rot.reviveKey(0, 1);
    rot.reportHttpStatus(0, 1, 0);
    try testing.expectEqual(RKeyState.CoolingDown, rot.snapshotKey(0, 1).?.state);

    // Health roll-up stays consistent.
    const c = rot.totalHealthCounts();
    try testing.expectEqual(@as(usize, 2), c.total);
    try testing.expectEqual(c.total, c.active + c.cooling_down + c.dead + c.disabled);
}

test "models: provider routing claims prefixes and strips them" {
    const alloc = testing.allocator;
    var fix = try makeTwoKeyConfig(alloc);
    defer alloc.free(fix.keys);
    defer alloc.free(fix.provs);
    fix.provs[0].prefix = "oc/";

    try testing.expect(fix.cfg.providers[0].claimsModel("oc/deepseek-r1"));
    try testing.expectEqualStrings("deepseek-r1", fix.cfg.providers[0].stripPrefix("oc/deepseek-r1"));
    const routed = fix.cfg.routeModel("oc/deepseek-r1").?;
    try testing.expectEqual(@as(usize, 0), routed.provider_index);
    try testing.expectEqualStrings("deepseek-r1", routed.upstream_model);
    try testing.expect(fix.cfg.routeModel("nope/model") == null);
}

test "metrics: snapshot fields and sparkline normalization" {
    var m = metrics.Metrics.init();
    m.setProviderCount(2);

    var empty: [8]f32 = undefined;
    try testing.expectEqual(@as(usize, 0), m.sparkline(empty[0..]));

    m.record(0, 100, 200);
    m.record(1, 300, 429);
    m.noteFailover();
    const s = m.snapshot();
    try testing.expectEqual(@as(u64, 2), s.total_requests);
    try testing.expectEqual(@as(u64, 0), s.active_inflight);
    try testing.expectEqual(@as(u64, 1), s.total_errors);
    try testing.expectEqual(@as(u64, 1), s.total_failovers);
    try testing.expectEqual(@as(u64, 1), s.per_provider[0]);
    try testing.expectEqual(@as(u64, 1), s.per_provider[1]);
    try testing.expectEqual(@as(usize, 2), s.samples);
    try testing.expectEqual(@as(f64, 200.0), s.avg_latency_ms);
    try testing.expectEqual(@as(u64, 300), s.max_latency_ms);
    try testing.expectEqual(@as(u64, 300), s.last_latency_ms);

    var out: [8]f32 = undefined;
    try testing.expectEqual(@as(usize, 2), m.sparkline(out[0..]));
    try testing.expectApproxEqAbs(@as(f32, 100.0 / 300.0), out[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out[1], 1e-5);

    var lat: [8]u64 = undefined;
    try testing.expectEqual(@as(usize, 2), m.copyLatencies(lat[0..]));
    try testing.expectEqual(@as(u64, 100), lat[0]);
    try testing.expectEqual(@as(u64, 300), lat[1]);
}

test "logger: failover wire format, request lines, levels, subscriber" {
    var l = logger.Logger.init();
    l.failover(2, 429, 3);
    l.logRequest("POST", "/v1/chat/completions", 200, 42);

    var lines: [4]logger.LogLine = undefined;
    try testing.expectEqual(@as(usize, 2), l.latest(lines[0..]));
    try testing.expectEqual(logger.Level.failover, lines[0].level);
    try testing.expectEqualStrings("[FAILOVER] Key #2 hit 429 -> Rotating to Key #3", lines[0].text());
    try testing.expectEqual(logger.Level.request, lines[1].level);
    try testing.expectEqualStrings("POST /v1/chat/completions -> 200 (42ms)", lines[1].text());

    try testing.expectEqualStrings("INFO", logger.Level.info.tag());
    try testing.expectEqualStrings("REQ", logger.Level.request.tag());
    try testing.expectEqualStrings("FAILOVER", logger.Level.failover.tag());
    try testing.expectEqualStrings("WARN", logger.Level.warn.tag());
    try testing.expectEqualStrings("ERROR", logger.Level.err.tag());

    var clock_buf: [8]u8 = undefined;
    try testing.expectEqualStrings("00:00:00", logger.formatTimeOfDay(0, &clock_buf));
    try testing.expectEqualStrings("01:02:03", logger.formatTimeOfDay(3_723_000, &clock_buf));

    var sub = l.subscriber();
    var got: [4]logger.LogLine = undefined;
    try testing.expectEqual(@as(usize, 2), sub.poll(got[0..]));
    try testing.expectEqual(@as(usize, 0), sub.poll(got[0..]));
    l.info("hello {s}", .{"world"});
    try testing.expectEqual(@as(usize, 1), sub.poll(got[0..]));
    try testing.expectEqualStrings("hello world", got[0].text());
}

// ---------------------------------------------------------------------------
// Source-text contracts for modules this binary cannot import (see the header
// note): models field shapes + defaults, rotator signatures, upstream
// ForwardResult/Endpoint, and the app Views/ViewFn/ServerHooks shell. Files
// are read relative to the project root. A missing marker means the owning
// modules drifted apart.
// ---------------------------------------------------------------------------

fn readSource(alloc: std.mem.Allocator, rel_path: []const u8) ![]u8 {
    const io = testing.io;
    return std.Io.Dir.cwd().readFileAlloc(io, rel_path, alloc, .limited(1 << 20)) catch |err| {
        std.debug.print("contract_check: cannot open {s} ({s}); run zig test from the project root\n", .{ rel_path, @errorName(err) });
        return err;
    };
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("contract_check: missing marker: {s}\n", .{needle});
        return error.ContractMarkerMissing;
    }
}

test "models source: Key/Provider/ProxyConfig fields, defaults, presets" {
    const alloc = testing.allocator;
    const text = try readSource(alloc, "src/models.zig");
    defer alloc.free(text);

    try expectContains(text, "pub const Key = struct {");
    try expectContains(text, "key: []const u8,");
    try expectContains(text, "state: KeyState = .Active,");
    try expectContains(text, "last_used: i64 = 0,");
    try expectContains(text, "cooldown_until: i64 = 0,");
    try expectContains(text, "consecutive_errors: u32 = 0,");
    try expectContains(text, "enabled: bool = true,");
    try expectContains(text, "pub const Provider = struct {");
    try expectContains(text, "display_name: []const u8,");
    try expectContains(text, "base_url: []const u8,");
    try expectContains(text, "prefix: []const u8,");
    try expectContains(text, "description: []const u8,");
    try expectContains(text, "keys: []Key,");
    try expectContains(text, "headers: []CustomHeader,");
    try expectContains(text, "pub const ProxyConfig = struct {");
    try expectContains(text, "port: u16 = default_port,");
    try expectContains(text, "providers: []Provider = &.{},");
    try expectContains(text, "auto_start: bool = false,");
    try expectContains(text, "cooldown_secs: u64 = default_cooldown_secs,");
    try expectContains(text, "timeout_ms: u32 = default_timeout_ms,");
    try expectContains(text, "pub const default_port: u16 = 8080;");
    try expectContains(text, "pub const default_cooldown_secs: u64 = 60;");
    try expectContains(text, "pub const default_timeout_ms: u32 = 30_000;");
    try expectContains(text, "pub const opencode_prefix: []const u8 = \"oc/\";");
    try expectContains(text, "pub const kilo_prefix: []const u8 = \"kilo/\";");
    try expectContains(text, "pub const opencode_base_url: []const u8 = \"https://opencode.ai/zen/v1/\";");
    try expectContains(text, "pub const kilo_base_url: []const u8 = \"https://api.kilo.ai/api/gateway\";");
    try expectContains(text, "pub fn isUsable(self: Key, now_unix: i64) bool {");
    try expectContains(text, "pub fn markCooldown(self: *Key, now_unix: i64, cooldown_secs: u64) void {");
    try expectContains(text, "pub fn routeModel(self: ProxyConfig, model: []const u8) ?RoutedModel {");
    try expectContains(text, "pub fn findProviderForModel(self: ProxyConfig, model: []const u8) ?usize {");
}

test "rotator source: selection/reporting signatures" {
    const alloc = testing.allocator;
    const text = try readSource(alloc, "src/rotator.zig");
    defer alloc.free(text);

    try expectContains(text, "pub fn nextHealthyKey(self: *Self, provider_index: usize) ?usize {");
    try expectContains(text, "pub fn nextHealthy(self: *Self, provider_index: usize) ?KeySelection {");
    try expectContains(text, "pub fn reportResult(self: *Self, provider_index: usize, key_index: usize, status: ?u16) void {");
    try expectContains(text, "pub fn reportHttpStatus(self: *Self, provider_index: usize, key_index: usize, status: u16) void {");
    try expectContains(text, "pub fn reportTimeout(self: *Self, provider_index: usize, key_index: usize) void {");
    try expectContains(text, "pub const default_max_consecutive_errors: u32 = 3;");
    try expectContains(text, "pub const KeySelection = struct {");
    try expectContains(text, "pub const HealthCounts = struct {");
}

test "upstream source: ForwardResult, Endpoint, entry points" {
    const alloc = testing.allocator;
    const text = try readSource(alloc, "src/upstream.zig");
    defer alloc.free(text);

    try expectContains(text, "pub const ForwardResult = struct {");
    try expectContains(text, "status: u16,");
    try expectContains(text, "elapsed_ms: i64,");
    try expectContains(text, "bytes_relayed: usize = 0,");
    try expectContains(text, "saw_done: bool = false,");
    try expectContains(text, "truncated: bool = false,");
    try expectContains(text, "error_body: ?[]u8 = null,");
    try expectContains(text, "pub const Endpoint = enum {");
    try expectContains(text, ".chat => \"/chat/completions\",");
    try expectContains(text, ".plain => \"/completions\",");
    try expectContains(text, "pub const status_timeout: u16 = 0;");
    try expectContains(text, "pub const status_transport_error: u16 = 502;");
    try expectContains(text, "pub const ModelEntry = struct {");
    try expectContains(text, "id: []const u8,");
    try expectContains(text, "upstream_id: []const u8,");
    try expectContains(text, "provider_name: []const u8,");
    try expectContains(text, "pub const FetchModelsResult = struct {");
    try expectContains(text, "pub const Stopwatch = struct {");
    try expectContains(text, "pub fn forwardChatCompletions(");
    try expectContains(text, "pub fn forwardCompletions(");
    try expectContains(text, "pub fn fetchModels(");
    try expectContains(text, "pub fn parseModelsBody");
    try expectContains(text, "provider: *const models.Provider,");
}

test "app shell: Views, ViewFn and ServerHooks declarations" {
    const alloc = testing.allocator;
    const text = try readSource(alloc, "src/ui/app.zig");
    defer alloc.free(text);

    try expectContains(text, "pub const ViewFn = *const fn (app: *App, root: Ui) void;");
    try expectContains(text, "pub const Views = struct {");
    try expectContains(text, "dashboard: ?ViewFn = null,");
    try expectContains(text, "providers: ?ViewFn = null,");
    try expectContains(text, "models: ?ViewFn = null,");
    try expectContains(text, "console_settings: ?ViewFn = null,");
    try expectContains(text, "pub const ServerHooks = struct {");
    try expectContains(text, "start_fn: ?*const fn (context: ?*anyopaque, port: u16) bool = null,");
    try expectContains(text, "stop_fn: ?*const fn (context: ?*anyopaque) void = null,");
    try expectContains(text, "port_changed_fn: ?*const fn (context: ?*anyopaque, port: u16) void = null,");
    try expectContains(text, "pub const App = struct {");
    try expectContains(text, "pub const AppState = App;");
    try expectContains(text, "pub fn setViews");
    try expectContains(text, "pub fn toggleServer");
    try expectContains(text, "pub fn renderFrame(root: Ui, state: *App) void");
    try expectContains(text, ".dashboard => \"Dashboard\",");
    try expectContains(text, ".providers => \"Providers\",");
    try expectContains(text, ".models => \"Models\",");
    try expectContains(text, ".console_settings => \"Console+Settings\",");
    try expectContains(text, ".stopped => \"STOPPED\",");
    try expectContains(text, ".running => \"RUNNING\",");
}

test "views: cross-module type references used by dashboard, providers, console" {
    const alloc = testing.allocator;

    const dash = try readSource(alloc, "src/ui/views_dashboard.zig");
    defer alloc.free(dash);
    try expectContains(dash, "pub const DashboardStats = struct {");
    try expectContains(dash, "pub const DashboardView = struct {");
    try expectContains(dash, "pub fn isUsableKey(key: *const models.Key) bool");
    try expectContains(dash, "pub fn collectStats(providers: []const models.Provider, snap: *const metrics.Snapshot) DashboardStats");

    const prov = try readSource(alloc, "src/ui/views_providers.zig");
    defer alloc.free(prov);
    try expectContains(prov, "pub const ProvidersView = struct {");
    try expectContains(prov, "pub fn badgeFor(key: *const models.Key) KeyBadge");
    try expectContains(prov, "pub fn summarizeProvider(provider: *const models.Provider) HealthSummary");
    try expectContains(prov, "pub fn addBulkKeys");

    const mc = try readSource(alloc, "src/ui/views_models_console.zig");
    defer alloc.free(mc);
    try expectContains(mc, "pub const ModelsView = struct {");
    try expectContains(mc, "pub const ConsoleView = struct {");
    try expectContains(mc, "pub const SettingsState = struct {");
    try expectContains(mc, "pub const RouteStatus = enum {");
}

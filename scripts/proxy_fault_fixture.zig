const std = @import("std");
const engine = @import("engine");
pub const std_options: std.Options = .{ .unexpected_error_tracing = false };
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (init.environ_map.get("TEST_CATALOG_PROXY_PORT")) |port| {
        const ok = engine.freeproxy.timed(bool, init.io, 1500, engine.freeproxy.probeOriginOk, .{ init.io, "http://origin.invalid/v1/", "unused", "127.0.0.1", try std.fmt.parseInt(u16, port, 10) }) catch false;
        try std.Io.File.stdout().writeStreamingAll(init.io, if (ok) "true" else "false");
        return;
    }
    var pool = engine.freeproxy.Pool.init(init.gpa, init.io);
    defer pool.deinit();
    pool.stopping = true; // Fixture routes only: no public list fetches.
    var ports = std.mem.splitScalar(u8, init.environ_map.get("TEST_ROUTES").?, ',');
    var hosts = std.mem.splitScalar(u8, init.environ_map.get("TEST_HOSTS") orelse "", ',');
    while (ports.next()) |port| {
        const host = hosts.next() orelse "127.0.0.1";
        try pool.entries.append(init.gpa, .{ .host = try init.gpa.dupe(u8, if (host.len == 0) "127.0.0.1" else host), .port = try std.fmt.parseInt(u16, port, 10) });
    }
    var keys = [_]engine.models.Key{.{ .key = "fixture-key" }};
    var providers = [_]engine.models.Provider{.{ .display_name = "Fixture", .base_url = "http://origin.invalid/v1/", .prefix = "test/", .description = "fixture", .keys = &keys, .headers = &.{}, .use_free_proxy = true }};
    var config: engine.models.ProxyConfig = .{ .port = try std.fmt.parseInt(u16, init.environ_map.get("TEST_PORT").?, 10), .timeout_ms = try std.fmt.parseInt(u32, init.environ_map.get("TEST_TIMEOUT").?, 10), .providers = &providers };
    var rotator = try engine.rotator.Rotator.init(init.gpa, &config);
    defer rotator.deinit();
    var log = engine.logger.Logger.init();
    var proxy = engine.proxy.Proxy.init(init.gpa, &config, .{ .io = init.io, .logger = engine.proxy.Logger.wrap(&log), .free_proxies = &pool, .rotator = &rotator, .dashboard = .{ .ctx = &pool, .handle_fn = stateHook } });
    try proxy.start();
    var buffer: [128]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &buffer);
    _ = try stdin.interface.takeDelimiter('\n');
    proxy.stop();
    var lines: [32]engine.logger.LogLine = undefined;
    const count = log.latest(&lines);
    var messages: [32][]const u8 = undefined;
    for (lines[0..count], 0..) |line, i| messages[i] = lines[i].msg[0..line.len];
    const output = try std.json.Stringify.valueAlloc(a, .{ .key_state = @tagName(keys[0].state), .cooldown = keys[0].cooldown_until, .remaining_routes = pool.entries.items.len, .logs = messages[0..count] }, .{});
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
}

fn stateHook(ctx: *anyopaque, method: []const u8, path: []const u8, body: []const u8, alloc: std.mem.Allocator, writer: *std.Io.Writer) ?u16 {
    _ = method;
    _ = body;
    if (!std.mem.eql(u8, path, "/fixture/state")) return null;
    const pool: *engine.freeproxy.Pool = @ptrCast(@alignCast(ctx));
    const json = std.json.Stringify.valueAlloc(alloc, pool.diag(), .{}) catch return 500;
    writer.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ json.len, json }) catch return 500;
    return 200;
}

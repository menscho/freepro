const std = @import("std");
const engine = @import("engine");
pub const std_options: std.Options = .{ .unexpected_error_tracing = false };
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var pool = engine.freeproxy.Pool.init(init.gpa, init.io);
    defer pool.deinit();
    pool.stopping = true; // Fixture routes only: no public list fetches.
    var ports = std.mem.splitScalar(u8, init.environ_map.get("TEST_ROUTES").?, ',');
    while (ports.next()) |port| try pool.entries.append(init.gpa, .{ .host = try init.gpa.dupe(u8, "127.0.0.1"), .port = try std.fmt.parseInt(u16, port, 10) });
    var keys = [_]engine.models.Key{.{ .key = "fixture-key" }};
    var providers = [_]engine.models.Provider{.{ .display_name = "Fixture", .base_url = "http://origin.invalid/v1/", .prefix = "test/", .description = "fixture", .keys = &keys, .headers = &.{}, .use_free_proxy = true }};
    var config: engine.models.ProxyConfig = .{ .port = try std.fmt.parseInt(u16, init.environ_map.get("TEST_PORT").?, 10), .timeout_ms = try std.fmt.parseInt(u32, init.environ_map.get("TEST_TIMEOUT").?, 10), .providers = &providers };
    var proxy = engine.proxy.Proxy.init(init.gpa, &config, .{ .io = init.io, .free_proxies = &pool });
    try proxy.start();
    var buffer: [128]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &buffer);
    _ = try stdin.interface.takeDelimiter('\n');
    proxy.stop();
    const output = try std.json.Stringify.valueAlloc(a, .{ .key_state = @tagName(keys[0].state), .cooldown = keys[0].cooldown_until, .remaining_routes = pool.entries.items.len }, .{});
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
}

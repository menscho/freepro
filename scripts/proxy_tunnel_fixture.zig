const std = @import("std");
const Client = @import("http_client");
pub fn main(init: std.process.Init) !void {
    const port = try std.fmt.parseInt(u16, init.environ_map.get("TEST_PROXY_PORT").?, 10);
    var proxy: Client.Proxy = .{ .protocol = .plain, .host = try std.Io.net.HostName.init("127.0.0.1"), .port = port, .authorization = null, .supports_connect = true };
    var client: Client = .{ .allocator = init.gpa, .io = init.io, .https_proxy = &proxy };
    defer client.deinit();
    var request = client.request(.POST, try std.Uri.parse("https://origin.invalid/v1/responses"), .{ .headers = .{ .authorization = .{ .override = "Bearer fixture-secret" } } }) catch return;
    defer request.deinit();
    try request.sendBodiless();
}

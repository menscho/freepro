//! GitHub release updater. One check at startup; verified, staged, opt-in install.
const std = @import("std");
const builtin = @import("builtin");
const timed = @import("freeproxy.zig").timed;
const A = std.mem.Allocator;
pub const version = "0.1.3";
const repository = "https://github.com/menscho/freepro/releases/download/";
const latest_url = "https://api.github.com/repos/menscho/freepro/releases/latest";
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

const max_binary = 128 * 1024 * 1024;

pub fn platform() []const u8 {
    return switch (builtin.os.tag) {
        .windows => if (builtin.cpu.arch == .x86_64) "windows-x86_64.exe" else "unsupported",
        .linux => if (builtin.cpu.arch == .aarch64) "linux-arm64" else if (builtin.cpu.arch == .x86_64) "linux-x86_64" else "unsupported",
        .macos => if (builtin.cpu.arch == .aarch64) "macos-arm64" else if (builtin.cpu.arch == .x86_64) "macos-x86_64" else "unsupported",
        else => "unsupported",
    };
}
pub fn newer(tag: []const u8) bool {
    const v = std.SemanticVersion.parse(std.mem.trimStart(u8, tag, "v")) catch return false;
    const current = std.SemanticVersion.parse(version) catch unreachable;
    return v.pre == null and v.order(current) == .gt;
}
const Release = struct { tag_name: []const u8, draft: bool = false, prerelease: bool = false, assets: []const Asset };
const Asset = struct { name: []const u8, browser_download_url: []const u8 };
const Selection = struct { tag: []const u8, binary_url: []const u8, checksum_url: []const u8, name: []const u8 };
pub fn selectRelease(a: A, data: []const u8) !?Selection {
    const release = try std.json.parseFromSlice(Release, a, data, .{ .ignore_unknown_fields = true });
    const r = release.value;
    if (r.draft or r.prerelease or !newer(r.tag_name)) return null;
    for (r.tag_name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-') return error.InvalidRelease;
    const name = try std.fmt.allocPrint(a, "freepro-{s}-{s}", .{ r.tag_name, platform() });
    const url = try std.fmt.allocPrint(a, "{s}{s}/{s}", .{ repository, r.tag_name, name });
    const sums = try std.fmt.allocPrint(a, "{s}{s}/SHA256SUMS", .{ repository, r.tag_name });
    var binary = false;
    var checksum = false;
    for (r.assets) |asset| {
        if (std.mem.eql(u8, asset.name, name) and std.mem.eql(u8, asset.browser_download_url, url)) binary = true;
        if (std.mem.eql(u8, asset.name, "SHA256SUMS") and std.mem.eql(u8, asset.browser_download_url, sums)) checksum = true;
    }
    if (!binary or !checksum) return null;
    return .{ .tag = r.tag_name, .binary_url = url, .checksum_url = sums, .name = name };
}
fn download(a: A, io: std.Io, url: []const u8, limit: usize) ![]u8 {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var req = try client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = @enumFromInt(5),
        .headers = .{ .user_agent = .{ .override = "freepro/" ++ version }, .accept_encoding = .{ .override = "identity" } },
    });
    defer req.deinit();
    try req.sendBodiless();
    var redirects: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirects);
    if (response.head.status == .not_found) return error.NoRelease;
    if (response.head.status != .ok) return error.DownloadFailed;
    if (response.head.content_length) |len| if (len > limit) return error.FileTooLarge;
    var buffer: [8192]u8 = undefined;
    return response.reader(&buffer).allocRemaining(a, .limited(limit));
}
pub fn verify(bytes: []const u8, sums: []const u8, name: []const u8) !void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    var lines = std.mem.tokenizeAny(u8, sums, "\r\n");
    var found = false;
    while (lines.next()) |line| {
        if (line.len < 66) continue;
        const file = std.mem.trimStart(u8, line[64..], " *\t");
        if (!std.mem.eql(u8, file, name)) continue;
        if (found) return error.InvalidChecksum;
        var expected: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&expected, line[0..64]) catch return error.InvalidChecksum;
        if (!std.mem.eql(u8, &expected, &hash)) return error.InvalidChecksum;
        found = true;
    }
    if (!found) return error.InvalidChecksum;
}
fn write(io: std.Io, path: []const u8, data: []const u8, executable: bool) !void {
    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer f.close(io);
    var buffer: [8192]u8 = undefined;
    var writer = f.writer(io, &buffer);
    try writer.interface.writeAll(data);
    try writer.flush();
    if (executable) try f.setPermissions(io, if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o755));
    try f.sync(io);
}
pub const Updater = struct {
    a: A,
    io: std.Io,
    mu: Mutex = .{},
    phase: enum { checking, idle, available, downloading, ready, failed } = .checking,
    selection: ?Selection = null,
    arena: std.heap.ArenaAllocator,
    thread: ?std.Thread = null,
    target: []const u8 = "",
    stage: []const u8 = "",
    marker: []const u8 = "",
    error_message: []const u8 = "",
    pub fn init(a: A, io: std.Io) Updater {
        return .{ .a = a, .io = io, .arena = std.heap.ArenaAllocator.init(a) };
    }
    pub fn deinit(self: *Updater) void {
        if (self.thread) |t| t.join();
        self.arena.deinit();
    }
    pub fn startCheck(self: *Updater) void {
        self.thread = std.Thread.spawn(.{}, checkThread, .{self}) catch {
            self.phase = .idle;
            return;
        };
    }
    fn checkThread(self: *Updater) void {
        const a = self.arena.allocator();
        const data = timed([]u8, self.io, 12_000, download, .{ a, self.io, latest_url, @as(usize, 1024 * 1024) }) catch {
            self.mu.lock();
            defer self.mu.unlock();
            self.phase = .idle;
            return;
        };
        const selection = selectRelease(a, data) catch null;
        self.mu.lock();
        defer self.mu.unlock();
        self.selection = selection;
        self.phase = if (selection != null) .available else .idle;
    }
    pub fn status(self: *Updater, a: A) ![]u8 {
        self.mu.lock();
        defer self.mu.unlock();
        return std.json.Stringify.valueAlloc(a, .{ .current = version, .available = self.selection != null, .version = if (self.selection) |s| s.tag else "", .phase = @tagName(self.phase), .message = self.error_message }, .{});
    }
    pub fn begin(self: *Updater) !void {
        self.mu.lock();
        if (self.phase != .available and self.phase != .failed) {
            self.mu.unlock();
            return error.NotAvailable;
        }
        if (self.selection == null) {
            self.mu.unlock();
            return error.NotAvailable;
        }
        self.phase = .downloading;
        self.error_message = "";
        self.mu.unlock();
        if (self.thread) |t| t.join();
        self.thread = null;
        self.thread = std.Thread.spawn(.{}, installThread, .{self}) catch |err| {
            self.fail("Could not start the updater. Please try again.");
            return err;
        };
    }
    fn fail(self: *Updater, message: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.phase = .failed;
        self.error_message = message;
    }
    pub fn ready(self: *Updater) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.phase == .ready;
    }
    fn installThread(self: *Updater) void {
        self.prepare() catch |err| {
            self.fail(switch (err) {
                error.InvalidChecksum => "Download verification failed. Your app is unchanged; retry the update.",
                error.AccessDenied => "The app folder is not writable. Move freepro to a folder you own and retry.",
                else => "Update download or preparation failed. Your app is unchanged; retry the update.",
            });
            return;
        };
        self.mu.lock();
        defer self.mu.unlock();
        self.phase = .ready;
    }
    fn prepare(self: *Updater) !void {
        const a = self.arena.allocator();
        const s = self.selection.?;
        const sums = try timed([]u8, self.io, 30_000, download, .{ a, self.io, s.checksum_url, @as(usize, 128 * 1024) });
        const bytes = try timed([]u8, self.io, 180_000, download, .{ a, self.io, s.binary_url, @as(usize, max_binary) });
        try verify(bytes, sums, s.name);
        self.target = try std.process.executablePathAlloc(self.io, a);
        var nonce: [8]u8 = undefined;
        self.io.random(&nonce);
        self.stage = try std.fmt.allocPrint(a, "{s}.update-{x}{s}", .{ self.target, nonce, if (builtin.os.tag == .windows) ".exe" else "" });
        self.marker = try std.fmt.allocPrint(a, "{s}.ready", .{self.stage});
        try write(self.io, self.stage, bytes, true);
        errdefer std.Io.Dir.cwd().deleteFile(self.io, self.stage) catch {};
        // The helper waits for the marker written only after the final config save.
        _ = try std.process.spawn(self.io, .{ .argv = &.{ self.stage, "--apply-update", self.target, self.marker }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = true });
    }
    pub fn activate(self: *Updater) !void {
        try write(self.io, self.marker, "saved", false);
    }
    pub fn saveFailed(self: *Updater) void {
        self.fail("Could not save settings. Update cancelled; fix storage permissions and retry.");
    }
};

/// Runs from the verified staged executable; no shell or user-supplied commands.
pub fn applyUpdate(a: A, io: std.Io, target: []const u8, marker: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const stage = try std.process.executablePathAlloc(io, a);
    defer a.free(stage);
    if (!std.fs.path.isAbsolute(target) or !std.mem.startsWith(u8, stage, target) or !std.mem.startsWith(u8, marker, stage)) return error.InvalidPath;
    var signalled = false;
    for (0..2400) |_| {
        const f = cwd.openFile(io, marker, .{}) catch {
            try std.Io.sleep(io, .fromMilliseconds(100), .awake);
            continue;
        };
        f.close(io);
        signalled = true;
        break;
    }
    if (!signalled) return error.UpdateCancelled;
    defer cwd.deleteFile(io, marker) catch {};
    const backup = try std.fmt.allocPrint(a, "{s}.previous", .{target});
    defer a.free(backup);
    // Windows holds the old executable until its process exits.
    var moved = false;
    for (0..300) |_| {
        cwd.rename(target, cwd, backup, io) catch {
            try std.Io.sleep(io, .fromMilliseconds(100), .awake);
            continue;
        };
        moved = true;
        break;
    }
    if (!moved) return error.ReplaceFailed;
    cwd.copyFile(stage, cwd, target, io, .{}) catch |err| {
        cwd.rename(backup, cwd, target, io) catch {};
        _ = std.process.spawn(io, .{ .argv = &.{ target, "--background" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = true }) catch {};
        return err;
    };
    _ = std.process.spawn(io, .{ .argv = &.{ target, "--background" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = true }) catch |err| {
        cwd.deleteFile(io, target) catch {};
        cwd.rename(backup, cwd, target, io) catch {};
        _ = std.process.spawn(io, .{ .argv = &.{ target, "--background" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = true }) catch {};
        return err;
    };
    // POSIX can unlink its helper; on Windows the next startup cleans it.
    cwd.deleteFile(io, stage) catch {};
}

test "release versions exclude current older malformed and prereleases" {
    try std.testing.expect(newer("v0.1.4"));
    try std.testing.expect(newer("v1.0.0"));
    for ([_][]const u8{ "v0.1.3", "v0.1.0", "v0.0.9", "nope", "v0.2.0-beta.1" }) |v| try std.testing.expect(!newer(v));
}
test "checksums reject tampering and absent assets" {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("hello", &hash, .{});
    const sums = try std.fmt.allocPrint(std.testing.allocator, "{x}  app\n", .{hash});
    defer std.testing.allocator.free(sums);
    try verify("hello", sums, "app");
    try std.testing.expectError(error.InvalidChecksum, verify("changed", sums, "app"));
    try std.testing.expectError(error.InvalidChecksum, verify("hello", sums, "other"));
}

test "release selection requires exact repository assets and checksum manifest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const name = try std.fmt.allocPrint(a, "freepro-v0.1.4-{s}", .{platform()});
    const url = try std.fmt.allocPrint(a, "{s}v0.1.4/{s}", .{ repository, name });
    const valid = try std.json.Stringify.valueAlloc(a, .{ .tag_name = "v0.1.4", .assets = .{ .{ .name = name, .browser_download_url = url }, .{ .name = "SHA256SUMS", .browser_download_url = repository ++ "v0.1.4/SHA256SUMS" } } }, .{});
    try std.testing.expect((try selectRelease(a, valid)) != null);
    const missing = try std.json.Stringify.valueAlloc(a, .{ .tag_name = "v0.1.4", .assets = .{.{ .name = name, .browser_download_url = url }} }, .{});
    try std.testing.expect((try selectRelease(a, missing)) == null);
    const foreign = try std.json.Stringify.valueAlloc(a, .{ .tag_name = "v0.1.4", .assets = .{ .{ .name = name, .browser_download_url = "https://example.com/foreign" }, .{ .name = "SHA256SUMS", .browser_download_url = repository ++ "v0.1.4/SHA256SUMS" } } }, .{});
    try std.testing.expect((try selectRelease(a, foreign)) == null);
}

// src/config.zig — freepro configuration persistence.
//
// Owned by the Wave 1 config task. This file owns the OS-standard config
// location, JSON load/save of `freepro_config.json`, atomic writes
// (same-directory tmp file + rename), and construction of the default
// config seeded from the product presets (OpenCode Zen + Kilo Gateway,
// see plan.md section 3.C).
//
// Toolchain note: this file targets the Zig toolchain installed in this
// environment (0.16.x), where file I/O goes through threaded `std.Io`
// (`std.fs` no longer hosts the file API) and environment access goes
// through `std.process.Environ`. The architecture, file layout, JSON
// schema, and function names match the 0.13-era spec; only the platform
// plumbing changed. No third-party packages are required, so this file
// adds no build dependencies.
//
// Expected `models.zig` surface (owned by the models task):
//   KeyState: enum { Active, CoolingDown, Dead }
//   Key: struct { key: []u8, state: KeyState, last_used: i64,
//                 cooldown_until: i64, consecutive_errors: u32,
//                 enabled: bool }
//   CustomHeader: struct { key: []u8, value: []u8 }
//   Provider: struct { display_name: []u8, base_url: []u8, prefix: []u8,
//                      description: []u8, keys: []Key,
//                      headers: []CustomHeader }
//             + fn deinit(self: *Provider, allocator: Allocator) void
//   ProxyConfig: struct { port: u16, providers: []Provider,
//                         auto_start: bool, cooldown_secs: u64,
//                         timeout_ms: u32 }
//             + fn deinit(self: *ProxyConfig, allocator: Allocator) void
//   Default scalars: default_port: u16, default_cooldown_secs: u64,
//                    default_timeout_ms: u32
//   Preset helpers (optional; config.zig embeds the same preset values so
//   it also works if those helpers change): defaultOpenCodeProvider,
//   defaultKiloProvider, opencode_*/kilo_* string constants.
// All strings are heap-duplicated `[]u8` and every slice is
// allocator-owned (even when empty), so a single `deinit` call releases
// a loaded or default config.
//
// On-disk layout: `<base>/freepro/freepro_config.json` where `<base>` is
// `%APPDATA%` (Windows), `~/Library/Application Support` (macOS), or
// `$XDG_CONFIG_HOME` / `~/.config` (Linux/other).
//
// Allocator ownership: every function that returns a config or a path
// hands ownership to the caller. Loaded/default configs must be released
// with `models.ProxyConfig.deinit`; returned paths with `allocator.free`.
// `std.Io` and `std.process.Environ.Map` are borrowed, never retained.

const std = @import("std");
const builtin = @import("builtin");
const models = @import("models.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const fs_path = Io.Dir.path;

/// Directory name of this application inside the OS config base.
pub const APP_DIR_NAME = "freepro";
/// File name of the persisted configuration.
pub const CONFIG_FILE_NAME = "freepro_config.json";

/// Default proxy listen port (spec section 3).
pub const DEFAULT_PORT: u16 = models.default_port;
/// The port that was the default before v0.1.4. Configs still holding it were
/// never pointed at it deliberately, so they migrate to `DEFAULT_PORT`.
pub const LEGACY_DEFAULT_PORT: u16 = 8080;
/// Default per-key cooldown after a 429/401/403 (seconds).
pub const DEFAULT_COOLDOWN_SECS: u64 = models.default_cooldown_secs;
/// Default upstream request timeout (milliseconds).
pub const DEFAULT_TIMEOUT_MS: u32 = models.default_timeout_ms;
/// Whether the proxy starts with the app on a fresh config.
pub const DEFAULT_AUTO_START: bool = false;

/// Upper bound for a single config file read. Configs are small (keys and
/// headers); anything larger is treated as corruption, not loaded.
pub const MAX_CONFIG_BYTES: usize = 16 * 1024 * 1024;

/// Resolves the OS-standard freepro config directory, e.g.
/// `%APPDATA%\freepro` on Windows or `~/.config/freepro` on Linux.
/// Reads variable values from `env` (normally `main`'s `environ_map`).
/// Caller owns the returned slice.
pub fn configDirPath(gpa: Allocator, env: *const std.process.Environ.Map) ![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            if (env.get("APPDATA")) |appdata| {
                return fs_path.join(gpa, &.{ appdata, APP_DIR_NAME });
            }
            if (env.get("USERPROFILE")) |home| {
                return fs_path.join(gpa, &.{ home, "AppData", "Roaming", APP_DIR_NAME });
            }
            return error.EnvironmentVariableMissing;
        },
        .macos => {
            const home = env.get("HOME") orelse return error.EnvironmentVariableMissing;
            return fs_path.join(gpa, &.{ home, "Library", "Application Support", APP_DIR_NAME });
        },
        else => {
            if (env.get("XDG_CONFIG_HOME")) |xdg| {
                if (xdg.len > 0) return fs_path.join(gpa, &.{ xdg, APP_DIR_NAME });
            }
            const home = env.get("HOME") orelse return error.EnvironmentVariableMissing;
            return fs_path.join(gpa, &.{ home, ".config", APP_DIR_NAME });
        },
    }
}

/// Resolves the full path of `freepro_config.json`. Caller owns the
/// returned slice.
pub fn configFilePath(gpa: Allocator, env: *const std.process.Environ.Map) ![]u8 {
    const dir = try configDirPath(gpa, env);
    defer gpa.free(dir);
    return fs_path.join(gpa, &.{ dir, CONFIG_FILE_NAME });
}

/// Moves a config off the pre-v0.1.4 default port so installs written by
/// older builds pick up the new default — and with it the free-port fallback
/// at launch — instead of staying pinned to the old number. Returns true when
/// the port was changed, so the caller can log or force a save.
pub fn migrateLegacyDefaultPort(cfg: *models.ProxyConfig) bool {
    if (cfg.port != LEGACY_DEFAULT_PORT) return false;
    cfg.port = DEFAULT_PORT;
    return true;
}

/// Creates the parent directory of `file_path` and any missing ancestors
/// (`mkdir -p`). Accepts absolute paths as well as paths relative to the
/// process working directory. A bare file name (no parent) is a no-op.
pub fn ensureParentDir(io: Io, file_path: []const u8) !void {
    const parent = fs_path.dirname(file_path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return;
    if (fs_path.isAbsolute(parent)) return mkdirPAbsolute(io, parent);
    return Io.Dir.cwd().createDirPath(io, parent);
}

/// Recursive directory creation for absolute paths. Every prefix is
/// created in order; existing prefixes are skipped.
fn mkdirPAbsolute(io: Io, abs_dir: []const u8) !void {
    var i: usize = 0;
    const n = abs_dir.len;
    // Skip the filesystem root: "/" on POSIX, "D:/" (or "D:") on Windows.
    if (n >= 1 and (abs_dir[0] == '/' or abs_dir[0] == '\\')) {
        i = 1;
    } else if (n >= 2 and abs_dir[1] == ':' and std.ascii.isAlphabetic(abs_dir[0])) {
        i = 2;
        if (n > 2 and (abs_dir[2] == '/' or abs_dir[2] == '\\')) i = 3;
    }
    while (i < n) {
        while (i < n and abs_dir[i] != '/' and abs_dir[i] != '\\') : (i += 1) {}
        const prefix = abs_dir[0..i];
        Io.Dir.createDirAbsolute(io, prefix, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        while (i < n and (abs_dir[i] == '/' or abs_dir[i] == '\\')) : (i += 1) {}
    }
}

const opencode_headers: []const [2][]const u8 = &.{
    .{ "User-Agent", "opencode/1.18.29" },
    .{ "x-opencode-project", "global" },
    .{ "x-opencode-session", "ses_19f6c1805ffe2ziZ0G3WZCdgAW" },
    .{ "x-opencode-request", "msg_8c4e2a91b7d03f5e" },
    .{ "x-opencode-client", "cli" },
};

/// Duplicates static key/value pairs into an allocator-owned header slice.
fn dupeHeaders(gpa: Allocator, pairs: []const [2][]const u8) ![]models.CustomHeader {
    const headers = try gpa.alloc(models.CustomHeader, pairs.len);
    errdefer gpa.free(headers);
    var done: usize = 0;
    errdefer {
        for (headers[0..done]) |*h| {
            gpa.free(h.key);
            gpa.free(h.value);
        }
    }
    for (pairs) |pair| {
        headers[done] = .{
            .key = try gpa.dupe(u8, pair[0]),
            .value = try gpa.dupe(u8, pair[1]),
        };
        done += 1;
    }
    return headers;
}

fn freeHeaders(gpa: Allocator, headers: []models.CustomHeader) void {
    for (headers) |*h| {
        gpa.free(h.key);
        gpa.free(h.value);
    }
    gpa.free(headers);
}

/// Builds one preset provider with an empty key pool. Takes ownership of
/// `headers` in all cases.
fn makeProvider(
    gpa: Allocator,
    display_name: []const u8,
    base_url: []const u8,
    prefix: []const u8,
    description: []const u8,
    headers: []models.CustomHeader,
) !models.Provider {
    errdefer freeHeaders(gpa, headers);
    const owned_name = try gpa.dupe(u8, display_name);
    errdefer gpa.free(owned_name);
    const owned_url = try gpa.dupe(u8, base_url);
    errdefer gpa.free(owned_url);
    const owned_prefix = try gpa.dupe(u8, prefix);
    errdefer gpa.free(owned_prefix);
    const owned_desc = try gpa.dupe(u8, description);
    errdefer gpa.free(owned_desc);
    // Notes and site URLs come from the shared models.zig preset constants
    // so the dashboard shows the same copy for seeded providers.
    const owned_note = try gpa.dupe(u8, models.noteForPrefix(prefix));
    errdefer gpa.free(owned_note);
    const owned_site = try gpa.dupe(u8, models.siteUrlForPrefix(prefix));
    errdefer gpa.free(owned_site);
    const keys = try gpa.alloc(models.Key, 0);
    return .{
        .display_name = owned_name,
        .base_url = owned_url,
        .prefix = owned_prefix,
        .description = owned_desc,
        .keys = keys,
        .headers = headers,
        .note = owned_note,
        .site_url = owned_site,
    };
}

fn defaultOpenCodeProvider(gpa: Allocator) !models.Provider {
    return makeProvider(
        gpa,
        "OpenCode Zen",
        "https://opencode.ai/zen/v1/",
        "oc/",
        "Free tier endpoints via OpenCode Zen gateway.",
        try dupeHeaders(gpa, opencode_headers),
    );
}

fn defaultKiloProvider(gpa: Allocator) !models.Provider {
    return makeProvider(
        gpa,
        "Kilo Gateway",
        "https://api.kilo.ai/api/gateway",
        "kilo/",
        "High-throughput community gateway.",
        try dupeHeaders(gpa, &.{}),
    );
}

/// Builds the fresh-install config: default network settings plus the two
/// preset providers with empty key pools. Caller owns the result and must
/// call `models.ProxyConfig.deinit`.
pub fn defaultConfig(gpa: Allocator) !models.ProxyConfig {
    const providers = try gpa.alloc(models.Provider, 6);
    errdefer gpa.free(providers);
    providers[0] = try defaultOpenCodeProvider(gpa);
    errdefer providers[0].deinit(gpa);
    providers[1] = try defaultKiloProvider(gpa);
    errdefer providers[1].deinit(gpa);
    providers[2] = try models.defaultBaiProvider(gpa);
    errdefer providers[2].deinit(gpa);
    providers[3] = try models.defaultBareTokenRouter(gpa);
    errdefer providers[3].deinit(gpa);
    providers[4] = try models.defaultBareCline(gpa);
    errdefer providers[4].deinit(gpa);
    providers[5] = try models.defaultBareNous(gpa);
    return models.ProxyConfig{
        .port = DEFAULT_PORT,
        .providers = providers,
        .auto_start = DEFAULT_AUTO_START,
        .cooldown_secs = DEFAULT_COOLDOWN_SECS,
        .timeout_ms = DEFAULT_TIMEOUT_MS,
    };
}

/// Loads and parses the config at `sub_path` relative to `dir`. A missing
/// file (or an empty one) yields `defaultConfig` instead of an error, so
/// first launch just works. Absolute `sub_path` values are resolved
/// against the process working directory. Caller owns the result.
pub fn loadFromDir(dir: Io.Dir, io: Io, gpa: Allocator, sub_path: []const u8) !models.ProxyConfig {
    if (fs_path.isAbsolute(sub_path)) return loadFromPath(gpa, io, sub_path);
    const data = dir.readFileAlloc(io, sub_path, gpa, Io.Limit.limited(MAX_CONFIG_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return defaultConfig(gpa),
        else => return err,
    };
    defer gpa.free(data);
    if (std.mem.trim(u8, data, " \t\r\n").len == 0) return defaultConfig(gpa);
    // alloc_always: the returned config must own every string because `data`
    // is freed below; the default alloc_if_needed would borrow from it.
    return std.json.parseFromSliceLeaky(models.ProxyConfig, gpa, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Loads and parses the config at `file_path` (absolute, or relative to
/// the process working directory). Same missing/empty fallback as
/// `loadFromDir`. Caller owns the result.
pub fn loadFromPath(gpa: Allocator, io: Io, file_path: []const u8) !models.ProxyConfig {
    const data = Io.Dir.cwd().readFileAlloc(io, file_path, gpa, Io.Limit.limited(MAX_CONFIG_BYTES)) catch |err| switch (err) {
        error.FileNotFound => return defaultConfig(gpa),
        else => return err,
    };
    defer gpa.free(data);
    if (std.mem.trim(u8, data, " \t\r\n").len == 0) return defaultConfig(gpa);
    // alloc_always: see loadFromDir.
    return std.json.parseFromSliceLeaky(models.ProxyConfig, gpa, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Loads the config from the OS-standard location. Caller owns the result.
pub fn load(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) !models.ProxyConfig {
    const path = try configFilePath(gpa, env);
    defer gpa.free(path);
    return loadFromPath(gpa, io, path);
}

/// Writes `cfg` as indented JSON to `sub_path` (relative to `dir`) with
/// atomic tmp-file + rename semantics. Callers must create parents first.
fn writeConfigFile(dir: Io.Dir, io: Io, gpa: Allocator, cfg: *const models.ProxyConfig, sub_path: []const u8) !void {
    const tmp_sub = try std.fmt.allocPrint(gpa, "{s}.tmp", .{sub_path});
    defer gpa.free(tmp_sub);
    errdefer dir.deleteFile(io, tmp_sub) catch {};
    {
        var file = try dir.createFile(io, tmp_sub, .{});
        defer file.close(io);
        var wbuf: [4096]u8 = undefined;
        var fw = file.writer(io, &wbuf);
        var js: std.json.Stringify = .{ .writer = &fw.interface, .options = .{ .whitespace = .indent_2 } };
        try js.write(cfg.*);
        try fw.flush();
        try file.sync(io);
    }
    try dir.rename(tmp_sub, dir, sub_path, io);
}

/// Serializes `cfg` as indented JSON into `sub_path` relative to `dir`,
/// creating missing parents. The write is atomic: content goes to
/// `<name>.tmp` in the same directory, is synced, then renamed over the
/// target, so a crash can never leave a half-written config. Absolute
/// `sub_path` values are handled via `saveToPath`.
pub fn saveToDir(dir: Io.Dir, io: Io, gpa: Allocator, cfg: *const models.ProxyConfig, sub_path: []const u8) !void {
    if (fs_path.isAbsolute(sub_path)) return saveToPath(gpa, io, cfg, sub_path);
    if (fs_path.dirname(sub_path)) |parent| {
        if (parent.len != 0 and !std.mem.eql(u8, parent, ".")) {
            try dir.createDirPath(io, parent);
        }
    }
    return writeConfigFile(dir, io, gpa, cfg, sub_path);
}

/// Serializes `cfg` to `file_path` (absolute, or relative to the process
/// working directory) with the same atomicity guarantees as `saveToDir`.
pub fn saveToPath(gpa: Allocator, io: Io, cfg: *const models.ProxyConfig, file_path: []const u8) !void {
    try ensureParentDir(io, file_path);
    const parent = fs_path.dirname(file_path);
    if (parent == null or parent.?.len == 0 or std.mem.eql(u8, parent.?, ".")) {
        return writeConfigFile(Io.Dir.cwd(), io, gpa, cfg, fs_path.basename(file_path));
    }
    var owned: ?Io.Dir = null;
    defer if (owned) |*d| d.close(io);
    const dir: Io.Dir = if (fs_path.isAbsolute(parent.?))
        try Io.Dir.openDirAbsolute(io, parent.?, .{})
    else
        try Io.Dir.cwd().openDir(io, parent.?, .{});
    owned = dir;
    return writeConfigFile(dir, io, gpa, cfg, fs_path.basename(file_path));
}

/// Persists `cfg` to the OS-standard location.
pub fn save(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, cfg: *const models.ProxyConfig) !void {
    const path = try configFilePath(gpa, env);
    defer gpa.free(path);
    return saveToPath(gpa, io, cfg, path);
}

// ---------------------------------------------------------------------------
// Unit tests. Filesystem tests use throwaway directories (never the real
// config location) and always clean up after themselves.
// ---------------------------------------------------------------------------

test "defaults ship the OpenCode and Kilo presets" {
    const gpa = std.testing.allocator;
    var cfg = try defaultConfig(gpa);
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(DEFAULT_PORT, cfg.port);
    try std.testing.expectEqual(DEFAULT_COOLDOWN_SECS, cfg.cooldown_secs);
    try std.testing.expectEqual(DEFAULT_TIMEOUT_MS, cfg.timeout_ms);
    try std.testing.expectEqual(DEFAULT_AUTO_START, cfg.auto_start);
    try std.testing.expectEqual(@as(usize, 6), cfg.providers.len);

    const oc = cfg.providers[0];
    try std.testing.expectEqualStrings("OpenCode Zen", oc.display_name);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1/", oc.base_url);
    try std.testing.expectEqualStrings("oc/", oc.prefix);
    try std.testing.expectEqualStrings("Free tier endpoints via OpenCode Zen gateway.", oc.description);
    try std.testing.expectEqual(@as(usize, 0), oc.keys.len);
    try std.testing.expectEqual(@as(usize, 5), oc.headers.len);
    try std.testing.expectEqualStrings("User-Agent", oc.headers[0].key);
    try std.testing.expectEqualStrings("opencode/1.18.29", oc.headers[0].value);
    try std.testing.expectEqualStrings("x-opencode-project", oc.headers[1].key);
    try std.testing.expectEqualStrings("global", oc.headers[1].value);
    try std.testing.expectEqualStrings("x-opencode-client", oc.headers[4].key);
    try std.testing.expectEqualStrings("cli", oc.headers[4].value);

    const kilo = cfg.providers[1];
    try std.testing.expectEqualStrings("Kilo Gateway", kilo.display_name);
    try std.testing.expectEqualStrings("https://api.kilo.ai/api/gateway", kilo.base_url);
    try std.testing.expectEqualStrings("kilo/", kilo.prefix);
    try std.testing.expectEqualStrings("High-throughput community gateway.", kilo.description);
    try std.testing.expectEqual(@as(usize, 0), kilo.keys.len);
    try std.testing.expectEqual(@as(usize, 0), kilo.headers.len);
}

test "configs left on the legacy default port migrate to the current one" {
    const gpa = std.testing.allocator;
    var cfg = try defaultConfig(gpa);
    defer cfg.deinit(gpa);

    cfg.port = LEGACY_DEFAULT_PORT;
    try std.testing.expect(migrateLegacyDefaultPort(&cfg));
    try std.testing.expectEqual(DEFAULT_PORT, cfg.port);

    // A port chosen deliberately is left alone.
    cfg.port = 9090;
    try std.testing.expect(!migrateLegacyDefaultPort(&cfg));
    try std.testing.expectEqual(@as(u16, 9090), cfg.port);
}

test "save/load round-trips edited settings and keys" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = try defaultConfig(gpa);
    defer cfg.deinit(gpa);
    cfg.port = 9090;
    cfg.auto_start = true;
    cfg.cooldown_secs = 120;
    cfg.timeout_ms = 5_000;

    const keys = try gpa.alloc(models.Key, 1);
    keys[0] = .{
        .key = try gpa.dupe(u8, "sk-test-123"),
        .state = .Active,
        .last_used = 0,
        .cooldown_until = 0,
        .consecutive_errors = 0,
        .enabled = true,
    };
    gpa.free(cfg.providers[0].keys);
    cfg.providers[0].keys = keys;

    try saveToDir(tmp.dir, io, gpa, &cfg, CONFIG_FILE_NAME);

    var loaded = try loadFromDir(tmp.dir, io, gpa, CONFIG_FILE_NAME);
    defer loaded.deinit(gpa);

    try std.testing.expectEqual(@as(u16, 9090), loaded.port);
    try std.testing.expectEqual(true, loaded.auto_start);
    try std.testing.expectEqual(@as(u64, 120), loaded.cooldown_secs);
    try std.testing.expectEqual(@as(u32, 5_000), loaded.timeout_ms);
    try std.testing.expectEqual(@as(usize, 6), loaded.providers.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.providers[0].keys.len);
    try std.testing.expectEqualStrings("sk-test-123", loaded.providers[0].keys[0].key);
    try std.testing.expectEqual(models.KeyState.Active, loaded.providers[0].keys[0].state);
    try std.testing.expectEqual(true, loaded.providers[0].keys[0].enabled);
    try std.testing.expectEqual(@as(usize, 5), loaded.providers[0].headers.len);
    try std.testing.expectEqualStrings("opencode/1.18.29", loaded.providers[0].headers[0].value);
}

test "loading a missing file yields defaults" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = try loadFromDir(tmp.dir, io, gpa, "does-not-exist.json");
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(DEFAULT_PORT, cfg.port);
    try std.testing.expectEqual(@as(usize, 6), cfg.providers.len);
}

test "loading an empty file yields defaults" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "empty.json", .data = "  \n\t " });

    var cfg = try loadFromDir(tmp.dir, io, gpa, "empty.json");
    defer cfg.deinit(gpa);

    try std.testing.expectEqual(DEFAULT_PORT, cfg.port);
}

test "loading malformed json returns an error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "bad.json", .data = "{ not valid json!!" });

    if (loadFromDir(tmp.dir, io, gpa, "bad.json")) |bad| {
        var owned = bad;
        owned.deinit(gpa);
        return error.TestExpectedError;
    } else |_| {}
}

test "save creates nested parents and leaves no tmp file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cfg = try defaultConfig(gpa);
    defer cfg.deinit(gpa);
    cfg.port = 7070;

    try saveToDir(tmp.dir, io, gpa, &cfg, "deep/nested/" ++ CONFIG_FILE_NAME);

    var loaded = try loadFromDir(tmp.dir, io, gpa, "deep/nested/" ++ CONFIG_FILE_NAME);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 7070), loaded.port);

    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(io, "deep/nested/" ++ CONFIG_FILE_NAME ++ ".tmp", .{}),
    );
}

test "config paths resolve per OS conventions" {
    const gpa = std.testing.allocator;
    var map = std.process.Environ.Map.init(gpa);
    defer map.deinit();

    switch (builtin.os.tag) {
        .windows => {
            try map.put("APPDATA", "C:\\Users\\tester\\AppData\\Roaming");
            const dir = try configDirPath(gpa, &map);
            defer gpa.free(dir);
            try std.testing.expectEqualStrings("C:\\Users\\tester\\AppData\\Roaming\\freepro", dir);

            const file = try configFilePath(gpa, &map);
            defer gpa.free(file);
            try std.testing.expectEqualStrings("C:\\Users\\tester\\AppData\\Roaming\\freepro\\" ++ CONFIG_FILE_NAME, file);

            var fallback = std.process.Environ.Map.init(gpa);
            defer fallback.deinit();
            try fallback.put("USERPROFILE", "C:\\Users\\tester");
            const fb_dir = try configDirPath(gpa, &fallback);
            defer gpa.free(fb_dir);
            try std.testing.expectEqualStrings("C:\\Users\\tester\\AppData\\Roaming\\freepro", fb_dir);

            var bare = std.process.Environ.Map.init(gpa);
            defer bare.deinit();
            try std.testing.expectError(error.EnvironmentVariableMissing, configDirPath(gpa, &bare));
        },
        .macos => {
            try map.put("HOME", "/Users/tester");
            const dir = try configDirPath(gpa, &map);
            defer gpa.free(dir);
            try std.testing.expectEqualStrings("/Users/tester/Library/Application Support/freepro", dir);

            const file = try configFilePath(gpa, &map);
            defer gpa.free(file);
            try std.testing.expect(std.mem.endsWith(u8, file, "/" ++ CONFIG_FILE_NAME));

            var bare = std.process.Environ.Map.init(gpa);
            defer bare.deinit();
            try std.testing.expectError(error.EnvironmentVariableMissing, configDirPath(gpa, &bare));
        },
        else => {
            try map.put("XDG_CONFIG_HOME", "/tmp/xdg-test");
            const dir = try configDirPath(gpa, &map);
            defer gpa.free(dir);
            try std.testing.expectEqualStrings("/tmp/xdg-test/freepro", dir);

            var home_only = std.process.Environ.Map.init(gpa);
            defer home_only.deinit();
            try home_only.put("HOME", "/home/tester");
            try home_only.put("XDG_CONFIG_HOME", "");
            const ho_dir = try configDirPath(gpa, &home_only);
            defer gpa.free(ho_dir);
            try std.testing.expectEqualStrings("/home/tester/.config/freepro", ho_dir);

            const file = try configFilePath(gpa, &map);
            defer gpa.free(file);
            try std.testing.expect(std.mem.endsWith(u8, file, "/" ++ CONFIG_FILE_NAME));

            var bare = std.process.Environ.Map.init(gpa);
            defer bare.deinit();
            try std.testing.expectError(error.EnvironmentVariableMissing, configDirPath(gpa, &bare));
        },
    }
}

test "ensureParentDir creates cwd-relative parents" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const hex = randomHex(&rnd);
    const top = try std.fmt.allocPrint(gpa, ".zig-cache/freepro-cfgtest-{s}", .{hex});
    defer gpa.free(top);
    const target = try std.fmt.allocPrint(gpa, "{s}/a/b/x.json", .{top});
    defer gpa.free(target);

    // Clean up even if an assertion below fails.
    defer Io.Dir.cwd().deleteTree(io, top) catch {};

    try ensureParentDir(io, target);

    const nested = try std.fmt.allocPrint(gpa, "{s}/a/b", .{top});
    defer gpa.free(nested);
    var d = try Io.Dir.cwd().openDir(io, nested, .{});
    d.close(io);
}

/// Hex-encodes random bytes for unique sandbox directory names.
fn randomHex(rnd: *const [8]u8) [16]u8 {
    const digits = "0123456789abcdef";
    var out: [16]u8 = undefined;
    for (rnd, 0..) |b, k| {
        out[k * 2] = digits[b >> 4];
        out[k * 2 + 1] = digits[b & 0x0f];
    }
    return out;
}

/// Absolute base directory for scratch files in tests: the OS temp dir.
/// Falls back to skipping the test when it cannot be determined.
fn testTempBase(gpa: Allocator) ![]u8 {
    switch (builtin.os.tag) {
        .windows => {
            const env: std.process.Environ = .{ .block = .global };
            const temp = env.getAlloc(gpa, "TEMP") catch try env.getAlloc(gpa, "TMP");
            defer gpa.free(temp);
            return gpa.dupe(u8, std.mem.trimEnd(u8, temp, "\\/"));
        },
        else => return gpa.dupe(u8, "/tmp"),
    }
}

test "absolute path save/load round-trip" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const base = try testTempBase(gpa);
    defer gpa.free(base);
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const hex = randomHex(&rnd);
    const sandbox = try std.fmt.allocPrint(gpa, "{s}{c}freepro-cfgtest-{s}", .{ base, fs_path.sep, hex });
    defer gpa.free(sandbox);
    const file_path = try fs_path.join(gpa, &.{ sandbox, "nested", CONFIG_FILE_NAME });
    defer gpa.free(file_path);

    // Remove the whole sandbox afterwards; ignore cleanup failures.
    defer {
        const name = fs_path.basename(sandbox);
        const opened = Io.Dir.openDirAbsolute(io, base, .{});
        if (opened) |dir| {
            var basedir = dir;
            defer basedir.close(io);
            basedir.deleteTree(io, name) catch {};
        } else |_| {}
    }

    var cfg = try defaultConfig(gpa);
    defer cfg.deinit(gpa);
    cfg.port = 6060;
    cfg.cooldown_secs = 5;

    try saveToPath(gpa, io, &cfg, file_path);

    var loaded = try loadFromPath(gpa, io, file_path);
    defer loaded.deinit(gpa);
    try std.testing.expectEqual(@as(u16, 6060), loaded.port);
    try std.testing.expectEqual(@as(u64, 5), loaded.cooldown_secs);
    try std.testing.expectEqual(@as(usize, 6), loaded.providers.len);
}

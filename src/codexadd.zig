// src/codexadd.zig - wire freepro into OpenAI Codex (CLI and Desktop share ~/.codex).
//
// Codex reads `$CODEX_HOME/config.toml` (default `~/.codex`). A custom provider
// is a `[model_providers.<id>]` table plus the root keys `model_provider` and
// `model`; `wire_api = "responses"` is the only transport Codex supports, which
// freepro serves through its /v1/responses bridge (src/codex.zig).
//
// Models are picker-visible when `model_catalog_json` points at a catalog file
// whose entries parse as Codex's own model metadata, so this module also writes
// `freepro-models.json` next to the config.
//
// Edits are targeted and idempotent: root keys are rewritten in place, our own
// table is replaced wholesale, and everything else stays byte-for-byte intact.
const std = @import("std");
const models = @import("models.zig");
const A = std.mem.Allocator;
const cap = 16 * 1024 * 1024;

pub const provider_id = "freepro";
pub const catalog_file = "freepro-models.json";

/// Codex sends this as the request's `instructions`, so it is the system prompt
/// every routed model receives. Kept short and provider-neutral: the upstream
/// model's own behaviour plus the client's tool definitions do the rest.
const base_instructions =
    \\You are a coding agent operating through freepro, a local proxy that forwards
    \\this request to the upstream model named in the conversation. Work from the
    \\user's request: inspect the workspace before changing it, prefer small and
    \\reversible edits, and use the provided tools to run and verify what you built
    \\rather than assuming it works. Report outcomes plainly, including anything you
    \\could not verify.
;

pub const Result = struct {
    changed: bool = false,
    model_count: usize = 0,
    catalog_written: bool = false,
    replaced_provider: bool = false,
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn quoted(a: A, value: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}

fn appendInt(a: A, out: *std.ArrayList(u8), v: anytype) !void {
    const s = try std.fmt.allocPrint(a, "{d}", .{v});
    defer a.free(s);
    try out.appendSlice(a, s);
}

pub fn configPath(a: A, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("CODEX_HOME")) |home| {
        if (home.len != 0) return std.fs.path.join(a, &.{ home, "config.toml" });
    }
    const home = env.get("USERPROFILE") orelse env.get("HOME") orelse return error.HomeNotFound;
    return std.fs.path.join(a, &.{ home, ".codex", "config.toml" });
}

pub fn catalogPath(a: A, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("CODEX_HOME")) |home| {
        if (home.len != 0) return std.fs.path.join(a, &.{ home, catalog_file });
    }
    const home = env.get("USERPROFILE") orelse env.get("HOME") orelse return error.HomeNotFound;
    return std.fs.path.join(a, &.{ home, ".codex", catalog_file });
}

/// Byte offset where the document root ends: the first table header line. Root
/// keys written after it would silently become part of that table, which is how
/// Codex ends up ignoring them.
fn rootEnd(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = trim(text[i..nl]);
        if (line.len != 0 and line[0] != '#') {
            if (line[0] == '[') return i;
        }
        if (nl == text.len) break;
        i = nl + 1;
    }
    return text.len;
}

fn lineStarts(text: []const u8, from: usize, to: usize, key: []const u8) ?usize {
    var i = from;
    while (i < to) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse to;
        const line = std.mem.trimStart(u8, text[i..nl], " \t");
        const stripped = trim(line);
        if (stripped.len >= key.len and std.mem.startsWith(u8, stripped, key)) {
            const rest = std.mem.trimStart(u8, stripped[key.len..], " \t");
            if (rest.len != 0 and rest[0] == '=') return i;
        }
        if (nl == to) break;
        i = nl + 1;
    }
    return null;
}

/// Set a root-level key, replacing an existing assignment inside the root
/// region only (a same-named key inside a table is a different key).
fn setRootKey(a: A, text: []const u8, key: []const u8, value: []const u8) ![]u8 {
    const end = rootEnd(text);
    var out: std.ArrayList(u8) = .empty;
    if (lineStarts(text, 0, end, key)) |start| {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        try out.appendSlice(a, text[0..start]);
        try out.appendSlice(a, key);
        try out.appendSlice(a, " = ");
        try out.appendSlice(a, value);
        try out.appendSlice(a, text[nl..]);
        return out.toOwnedSlice(a);
    }
    try out.appendSlice(a, text[0..end]);
    if (end != 0 and (text.len == 0 or text[end - 1] != '\n')) try out.append(a, '\n');
    try out.appendSlice(a, key);
    try out.appendSlice(a, " = ");
    try out.appendSlice(a, value);
    try out.append(a, '\n');
    try out.appendSlice(a, text[end..]);
    return out.toOwnedSlice(a);
}

/// Remove our own provider table (header plus body up to the next header).
fn dropProviderTable(a: A, text: []const u8) !struct { text: []u8, found: bool } {
    const header = try std.fmt.allocPrint(a, "[model_providers.{s}]", .{provider_id});
    defer a.free(header);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var found = false;
    while (i < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = trim(text[i..nl]);
        if (std.mem.eql(u8, line, header)) {
            found = true;
            var j = nl;
            if (j == text.len) break;
            j += 1;
            while (j < text.len) {
                const nl2 = std.mem.indexOfScalarPos(u8, text, j, '\n') orelse text.len;
                const l2 = trim(text[j..nl2]);
                if (l2.len != 0 and l2[0] == '[') break;
                if (nl2 == text.len) {
                    j = text.len;
                    break;
                }
                j = nl2 + 1;
            }
            i = j;
            continue;
        }
        if (nl == text.len) {
            try out.appendSlice(a, text[i..]);
            break;
        }
        try out.appendSlice(a, text[i .. nl + 1]);
        i = nl + 1;
    }
    return .{ .text = try out.toOwnedSlice(a), .found = found };
}

/// The provider table freepro needs. No `env_key`: freepro accepts unauthenticated
/// loopback traffic, and a missing env var is a hard error inside Codex.
fn providerTable(a: A, port: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "[model_providers.");
    try out.appendSlice(a, provider_id);
    try out.appendSlice(a, "]\n");
    try out.appendSlice(a, "name = \"freepro\"\n");
    try out.appendSlice(a, try std.fmt.allocPrint(a, "base_url = \"http://127.0.0.1:{d}/v1\"\n", .{port}));
    try out.appendSlice(a, "wire_api = \"responses\"\n");
    return out.toOwnedSlice(a);
}

/// Build the Codex model catalog. Entries carry every field Codex's strict
/// parser requires; unknown extras would be ignored, missing ones are not.
pub fn catalogJson(a: A, cfg: models.ProxyConfig) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "{\"models\":[");
    var n: usize = 0;
    var priority: i32 = 1;
    for (cfg.providers) |p| {
        for (p.models) |m| {
            if (!m.enabled) continue;
            if ((cfg.hide_paid or cfg.free_mode) and !m.isFree()) continue;
            const slug = try std.fmt.allocPrint(a, "{s}{s}", .{ p.prefix, m.id });
            if (n != 0) try out.appendSlice(a, ",");
            n += 1;
            try out.appendSlice(a, "{\"slug\":");
            try out.appendSlice(a, try quoted(a, slug));
            try out.appendSlice(a, ",\"display_name\":");
            try out.appendSlice(a, try quoted(a, slug));
            try out.appendSlice(a, ",\"description\":");
            try out.appendSlice(a, try quoted(a, try std.fmt.allocPrint(
                a,
                "freepro route {s} ({s}) - served over the Responses API, upstream model {s}",
                .{ slug, p.display_name, m.upstream_id },
            )));
            try out.appendSlice(a, ",\"priority\":");
            try appendInt(a, &out, priority);
            priority += 1;
            try out.appendSlice(a, ",\"visibility\":\"list\",\"supported_in_api\":true");
            try out.appendSlice(a, ",\"shell_type\":\"unified_exec\"");
            // Codex rejects a catalog entry that has no instruction source: the
            // legacy `base_instructions` field becomes model_messages
            // .instructions_template while parsing.
            try out.appendSlice(a, ",\"base_instructions\":");
            try out.appendSlice(a, try quoted(a, base_instructions));
            try out.appendSlice(a, ",\"support_verbosity\":false,\"default_verbosity\":null");
            try out.appendSlice(a, ",\"apply_patch_tool_type\":null");
            try out.appendSlice(a, ",\"truncation_policy\":{\"mode\":\"tokens\",\"limit\":10000}");
            try out.appendSlice(a, ",\"experimental_supported_tools\":[]");
            try out.appendSlice(a, ",\"input_modalities\":[\"text\"]");
            try out.appendSlice(a, ",\"service_tiers\":[],\"additional_speed_tiers\":[]");
            try out.appendSlice(a, ",\"availability_nux\":null,\"upgrade\":null");
            const window: u64 = if (m.context_window == 0) 131_072 else m.context_window;
            try out.appendSlice(a, ",\"context_window\":");
            try appendInt(a, &out, window);
            try out.appendSlice(a, ",\"max_context_window\":");
            try appendInt(a, &out, window);
            // Reasoning ladder from the model metadata; Codex shows these as the
            // effort picker and rejects an entry with none.
            var levels: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, if (m.reasoning_levels.len == 0) models.default_reasoning_levels else m.reasoning_levels, ',');
            while (it.next()) |raw| {
                const v = trim(raw);
                if (v.len != 0) try levels.append(a, v);
            }
            try out.appendSlice(a, ",\"supported_reasoning_levels\":[");
            for (levels.items, 0..) |lvl, i| {
                if (i != 0) try out.appendSlice(a, ",");
                try out.appendSlice(a, "{\"effort\":");
                try out.appendSlice(a, try quoted(a, lvl));
                try out.appendSlice(a, ",\"description\":");
                try out.appendSlice(a, try quoted(a, try std.fmt.allocPrint(a, "{s} reasoning", .{lvl})));
                try out.appendSlice(a, "}");
            }
            try out.appendSlice(a, "]");
            var fallback: []const u8 = "medium";
            if (levels.items.len != 0) {
                fallback = "medium";
                for (levels.items) |lvl| {
                    if (std.mem.eql(u8, lvl, "medium")) fallback = lvl;
                }
                if (std.mem.eql(u8, fallback, "medium") and levels.items.len != 0) {
                    var has_medium = false;
                    for (levels.items) |lvl| has_medium = has_medium or std.mem.eql(u8, lvl, "medium");
                    if (!has_medium) fallback = levels.items[0];
                }
            }
            try out.appendSlice(a, ",\"default_reasoning_level\":");
            try out.appendSlice(a, try quoted(a, fallback));
            try out.appendSlice(a, "}");
        }
    }
    if (n == 0) return error.NoEnabledModels;
    try out.appendSlice(a, "]}");
    return out.toOwnedSlice(a);
}

pub const Update = struct { text: []const u8, catalog: []const u8, result: Result };

/// Pure transform: existing config text ("" when absent) plus the live proxy
/// config, returning the new config text, the catalog and what changed.
pub fn merged(a: A, original: []const u8, cfg: models.ProxyConfig, catalog_path: []const u8) !Update {
    const catalog = try catalogJson(a, cfg);
    const dropped = try dropProviderTable(a, original);
    var text = dropped.text;
    text = try setRootKey(a, text, "model_provider", try quoted(a, provider_id));
    text = try setRootKey(a, text, "model_catalog_json", try quoted(a, catalog_path));
    // Codex must start on a model freepro actually serves; keep the user's own
    // choice when it already names one of ours.
    const first = try firstSlug(a, cfg);
    if (!namesFreeproModel(text, first)) text = try setRootKey(a, text, "model", try quoted(a, first));
    // Exactly one blank line between the user's last statement and our table, so
    // re-applying never grows the file.
    var end = text.len;
    while (end > 0 and text[end - 1] == '\n') end -= 1;
    const parts = [_][]const u8{ text[0..end], "\n\n", try providerTable(a, cfg.port) };
    const final = try std.mem.concat(a, u8, &parts);
    return .{
        .text = final,
        .catalog = catalog,
        .result = .{
            .changed = !std.mem.eql(u8, original, final),
            .model_count = std.mem.count(u8, catalog, "\"slug\":"),
            .catalog_written = true,
            .replaced_provider = dropped.found,
        },
    };
}

fn namesFreeproModel(text: []const u8, slug: []const u8) bool {
    const end = rootEnd(text);
    const start = lineStarts(text, 0, end, "model") orelse return false;
    const nl = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return std.mem.indexOf(u8, text[start..nl], slug) != null;
}

fn firstSlug(a: A, cfg: models.ProxyConfig) ![]const u8 {
    for (cfg.providers) |p| for (p.models) |m| {
        if (!m.enabled) continue;
        if ((cfg.hide_paid or cfg.free_mode) and !m.isFree()) continue;
        return std.fmt.allocPrint(a, "{s}{s}", .{ p.prefix, m.id });
    };
    return error.NoEnabledModels;
}

pub fn read(a: A, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(cap));
}

fn writeFile(io: std.Io, path: []const u8, text: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = f.writer(io, &buffer);
    try writer.interface.writeAll(text);
    try writer.flush();
    try f.sync(io);
}

/// Write the catalog and merge the config in place. The config is backed up once
/// to `config.toml.freepro.bak` and swapped in atomically, and a config that
/// changed under us since it was read aborts the write rather than clobbering.
pub fn apply(a: A, io: std.Io, config: []const u8, catalog: []const u8, cfg: models.ProxyConfig) !Result {
    const original = read(a, io, config) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const dir = std.fs.path.dirname(config) orelse return error.InvalidPath;
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const update = try merged(a, original, cfg, catalog);
    try writeFile(io, catalog, update.catalog);
    const result = update.result;
    if (!result.changed) return result;
    const backup = try std.fmt.allocPrint(a, "{s}.freepro.bak", .{config});
    if (original.len != 0) writeFile(io, backup, original) catch {};
    var random: [8]u8 = undefined;
    io.random(&random);
    const temp = try std.fmt.allocPrint(a, "{s}.freepro-{x}.tmp", .{ config, random });
    defer std.Io.Dir.cwd().deleteFile(io, temp) catch {};
    try writeFile(io, temp, update.text);
    const current = read(a, io, config) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    if (!std.mem.eql(u8, original, current)) return error.ConfigChanged;
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), config, io);
    return result;
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

fn cfgWith(port: u16, allocator: A) !models.ProxyConfig {
    var cfg = models.ProxyConfig{ .port = port };
    cfg.providers = try allocator.alloc(models.Provider, 1);
    cfg.providers[0] = .{
        .display_name = "OpenCode Zen",
        .base_url = "https://example.test/v1",
        .prefix = try allocator.dupe(u8, "oc/"),
        .description = "",
        .keys = &.{},
        .headers = &.{},
        .models = try allocator.alloc(models.ModelInfo, 1),
        .use_free_proxy = false,
    };
    cfg.providers[0].models[0] = .{
        .id = try allocator.dupe(u8, "mimo-v2.5-free"),
        .upstream_id = try allocator.dupe(u8, "mimo-v2.5-free"),
        .provider_name = try allocator.dupe(u8, "OpenCode Zen"),
        .provider_prefix = try allocator.dupe(u8, "oc/"),
        .context_window = 131072,
        .enabled = true,
    };
    return cfg;
}

test "merged writes root keys before any table and appends the provider" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try cfgWith(54321, a);
    const original =
        \\model = "gpt-6-astra"
        \\
        \\[desktop]
        \\followUpQueueMode = "steer"
        \\
        \\[projects.'d:\freepro']
        \\trust_level = "trusted"
    ;
    const update = try merged(a, original, cfg, "C:\\Users\\mensch\\.codex\\freepro-models.json");
    // Root keys land before [desktop], not inside the last table.
    const root_end = std.mem.indexOfScalar(u8, update.text, '[').?;
    try testing.expect(std.mem.indexOf(u8, update.text[0..root_end], "model_provider = \"freepro\"") != null);
    try testing.expect(std.mem.indexOf(u8, update.text[0..root_end], "model_catalog_json =") != null);
    try testing.expect(std.mem.indexOf(u8, update.text[0..root_end], "model = \"oc/mimo-v2.5-free\"") != null);
    try testing.expect(std.mem.indexOf(u8, update.text, "[model_providers.freepro]") != null);
    try testing.expect(std.mem.indexOf(u8, update.text, "wire_api = \"responses\"") != null);
    try testing.expect(std.mem.indexOf(u8, update.text, "base_url = \"http://127.0.0.1:54321/v1\"") != null);
    // Untouched user content survives verbatim.
    try testing.expect(std.mem.indexOf(u8, update.text, "followUpQueueMode = \"steer\"") != null);
    try testing.expect(std.mem.indexOf(u8, update.text, "trust_level = \"trusted\"") != null);
    try testing.expect(update.result.changed);
    try testing.expectEqual(@as(usize, 1), update.result.model_count);

    // Re-applying is a no-op.
    const again = try merged(a, update.text, cfg, "C:\\Users\\mensch\\.codex\\freepro-models.json");
    try testing.expect(!again.result.changed);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, again.text, "[model_providers.freepro]"));
}

test "merged replaces a stale provider table and keeps one copy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try cfgWith(54399, a);
    const original =
        \\model_provider = "other"
        \\
        \\[model_providers.freepro]
        \\name = "stale"
        \\base_url = "http://127.0.0.1:1/v1"
        \\wire_api = "responses"
        \\
        \\[mcp_servers.node_repl]
        \\command = "keep me"
    ;
    const update = try merged(a, original, cfg, "/home/m/.codex/freepro-models.json");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, update.text, "[model_providers.freepro]"));
    try testing.expect(std.mem.indexOf(u8, update.text, "name = \"stale\"") == null);
    try testing.expect(std.mem.indexOf(u8, update.text, "base_url = \"http://127.0.0.1:54399/v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, update.text, "command = \"keep me\"") != null);
    try testing.expect(update.result.replaced_provider);
    // The user's own root key was rewritten, and only the root one.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, update.text, "model_provider = \"freepro\""));
}

test "catalog entries carry every field Codex requires" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cfg = try cfgWith(54321, a);
    const text = try catalogJson(a, cfg);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    const models_arr = parsed.value.object.get("models").?;
    try testing.expectEqual(@as(usize, 1), models_arr.array.items.len);
    const entry = models_arr.array.items[0].object;
    const required = [_][]const u8{
        "slug",
        "display_name",
        "supported_reasoning_levels",
        "shell_type",
        "visibility",
        "supported_in_api",
        "priority",
        "support_verbosity",
        "truncation_policy",
        "experimental_supported_tools",
    };
    for (required) |key| try testing.expect(entry.get(key) != null);
    // Codex refuses to load a catalog whose entries have no instruction source.
    try testing.expect(entry.get("base_instructions").? == .string);
    try testing.expect(entry.get("base_instructions").?.string.len > 40);
    try testing.expectEqualStrings("oc/mimo-v2.5-free", entry.get("slug").?.string);
    const levels = entry.get("supported_reasoning_levels").?.array.items;
    try testing.expect(levels.len > 0);
    try testing.expect(entry.get("supported_reasoning_levels").?.array.items[0].object.get("effort") != null);
}

test "catalog refuses a config with nothing exposed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = models.ProxyConfig{ .port = 54321 };
    cfg.providers = try a.alloc(models.Provider, 0);
    try testing.expectError(error.NoEnabledModels, catalogJson(a, cfg));
}

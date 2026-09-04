//! Targeted TOML edits for Kimi Code. Unmanaged statements stay byte-for-byte intact.
const std = @import("std");
const models = @import("models.zig");
const A = std.mem.Allocator;
const cap = 16 * 1024 * 1024;
const Field = struct { key: []const u8, value: []const u8, only_missing: bool = false };
const Section = struct { start: usize, body: usize, end: usize, path: [][]const u8, array: bool };
pub const Result = struct { changed: bool, added: usize, updated: usize, model_count: usize };

pub fn configPath(a: A, env: *const std.process.Environ.Map) ![]u8 {
    const home = env.get("USERPROFILE") orelse env.get("HOME") orelse return error.HomeNotFound;
    return std.fs.path.join(a, &.{ home, ".kimi-code", "config.toml" });
}
fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}
fn quoted(a: A, value: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}

// A statement can span lines inside arrays, inline tables or multiline strings.
fn endStatement(text: []const u8, start: usize) !usize {
    var i = start;
    var quote: u8 = 0;
    var multi = false;
    var depth: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote != 0) {
            if (c == '\\' and quote == '"') {
                if (i + 1 >= text.len) return error.UnsafeToml;
                i += 1;
                continue;
            }
            if (!multi and c == '\n') return error.UnsafeToml;
            if (c == quote) {
                if (!multi) {
                    quote = 0;
                } else if (i + 2 < text.len and text[i + 1] == quote and text[i + 2] == quote) {
                    quote = 0;
                    i += 2;
                }
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            multi = i + 2 < text.len and text[i + 1] == c and text[i + 2] == c;
            if (multi) i += 2;
        } else if (c == '#') {
            while (i < text.len and text[i] != '\n') : (i += 1) {}
            if (depth == 0) return @min(i + 1, text.len);
        } else if (c == '[' or c == '{') {
            depth += 1;
        } else if (c == ']' or c == '}') {
            if (depth == 0) return error.UnsafeToml;
            depth -= 1;
        } else if (c == '\n' and depth == 0) return i + 1;
    }
    if (quote != 0 or depth != 0) return error.UnsafeToml;
    return i;
}

fn parsePath(a: A, text: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
        if (i == text.len) return error.UnsafeToml;
        const start = i;
        var value: []const u8 = undefined;
        if (text[i] == '"' or text[i] == '\'') {
            const q = text[i];
            i += 1;
            while (i < text.len and text[i] != q) : (i += 1) {
                if (q == '"' and text[i] == '\\') i += 1;
            }
            if (i >= text.len) return error.UnsafeToml;
            if (q == '\'') value = text[start + 1 .. i] else {
                const parsed = std.json.parseFromSlice([]const u8, a, text[start .. i + 1], .{ .allocate = .alloc_always }) catch return error.UnsafeToml;
                value = parsed.value;
            }
            i += 1;
        } else {
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_' or text[i] == '-')) : (i += 1) {}
            if (i == start) return error.UnsafeToml;
            value = text[start..i];
        }
        try result.append(a, value);
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
        if (i == text.len) break;
        if (text[i] != '.') return error.UnsafeToml;
        i += 1;
        if (i == text.len) return error.UnsafeToml;
    }
    return result.toOwnedSlice(a);
}
fn header(a: A, text: []const u8) !struct { path: [][]const u8, array: bool } {
    const t = trim(text);
    const array = std.mem.startsWith(u8, t, "[[");
    const n: usize = if (array) 2 else 1;
    var q: u8 = 0;
    var i: usize = n;
    while (i < t.len) : (i += 1) {
        if (q != 0) {
            if (t[i] == '\\' and q == '"') i += 1 else if (t[i] == q) q = 0;
        } else if (t[i] == '"' or t[i] == '\'') q = t[i] else if (t[i] == ']') break;
    }
    if (i + n > t.len or (array and t[i + 1] != ']')) return error.UnsafeToml;
    const tail = trim(t[i + n ..]);
    if (tail.len != 0 and tail[0] != '#') return error.UnsafeToml;
    return .{ .path = try parsePath(a, trim(t[n..i])), .array = array };
}
fn sections(a: A, text: []const u8) ![]Section {
    var out: std.ArrayList(Section) = .empty;
    try out.append(a, .{ .start = 0, .body = 0, .end = text.len, .path = &.{}, .array = false });
    var i: usize = if (std.mem.startsWith(u8, text, "\xef\xbb\xbf")) 3 else 0;
    while (i < text.len) {
        const end = try endStatement(text, i);
        const line = trim(text[i..end]);
        if (line.len != 0 and line[0] == '[') {
            const h = try header(a, line);
            out.items[out.items.len - 1].end = i;
            try out.append(a, .{ .start = i, .body = end, .end = text.len, .path = h.path, .array = h.array });
        } else if (line.len != 0 and line[0] != '#' and std.mem.indexOfScalar(u8, line, '=') == null) return error.UnsafeToml;
        i = end;
    }
    return out.toOwnedSlice(a);
}
fn isSection(s: Section, group: []const u8, name: []const u8) bool {
    return !s.array and s.path.len == 2 and std.mem.eql(u8, s.path[0], group) and std.mem.eql(u8, s.path[1], name);
}

fn mergeSection(a: A, text: []const u8, group: []const u8, name: []const u8, fields: []const Field) ![]const u8 {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    return a.dupe(u8, try mergeSectionInner(scratch.allocator(), text, group, name, fields));
}
fn mergeSectionInner(a: A, text: []const u8, group: []const u8, name: []const u8, fields: []const Field) ![]const u8 {
    const parts = try sections(a, text);
    // Inline/dotted parent definitions cannot safely be extended with a table.
    for (parts) |s| {
        if (s.path.len > 0 and !std.mem.eql(u8, s.path[0], group)) continue;
        if (s.path.len >= 2) {
            if (!std.mem.eql(u8, s.path[1], name)) continue;
            if (s.array) return error.UnsafeToml;
            if (s.path.len > 2) for (fields) |f| {
                if (std.mem.eql(u8, s.path[2], f.key)) return error.UnsafeToml;
            };
            continue;
        }
        if (s.array) return error.UnsafeToml;
        var pos = s.body;
        if (pos == 0 and std.mem.startsWith(u8, text, "\xef\xbb\xbf")) pos = 3;
        while (pos < s.end) {
            const end = try endStatement(text, pos);
            const line = trim(text[pos..end]);
            if (line.len > 0 and line[0] != '#') {
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.UnsafeToml;
                const key = try parsePath(a, trim(line[0..eq]));
                if (key.len == 0) return error.UnsafeToml;
                if (s.path.len == 1) {
                    if (std.mem.eql(u8, key[0], name)) return error.UnsafeToml;
                } else if (std.mem.eql(u8, key[0], group)) {
                    if (key.len == 1 or std.mem.eql(u8, key[1], name)) return error.UnsafeToml;
                }
            }
            pos = end;
        }
    }
    var found: ?Section = null;
    for (parts) |s| if (isSection(s, group, name)) {
        if (found != null) return error.UnsafeToml;
        found = s;
    };
    var out: std.ArrayList(u8) = .empty;
    const newline: []const u8 = if (std.mem.indexOf(u8, text, "\r\n") != null) "\r\n" else "\n";
    var seen = try a.alloc(bool, fields.len);
    @memset(seen, false);
    if (found) |section| {
        try out.appendSlice(a, text[0..section.body]);
        var i = section.body;
        while (i < section.end) {
            const end = try endStatement(text, i);
            const line = trim(text[i..end]);
            var replace: ?usize = null;
            if (line.len != 0 and line[0] != '#') {
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.UnsafeToml;
                const key = try parsePath(a, trim(line[0..eq]));
                if (key.len > 1) for (fields) |f| {
                    if (std.mem.eql(u8, key[0], f.key)) return error.UnsafeToml;
                };
                if (key.len == 1) for (fields, 0..) |f, j| {
                    if (std.mem.eql(u8, key[0], f.key)) {
                        if (seen[j]) return error.UnsafeToml;
                        seen[j] = true;
                        if (!f.only_missing) replace = j;
                    }
                };
            }
            if (replace) |j| {
                try out.appendSlice(a, fields[j].key);
                try out.appendSlice(a, " = ");
                try out.appendSlice(a, fields[j].value);
                try out.appendSlice(a, newline);
            } else try out.appendSlice(a, text[i..end]);
            i = end;
        }
    } else {
        try out.appendSlice(a, text);
        if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(a, newline);
        try out.appendSlice(a, newline);
        try out.appendSlice(a, "[");
        try out.appendSlice(a, group);
        try out.appendSlice(a, ".");
        try out.appendSlice(a, try quoted(a, name));
        try out.appendSlice(a, "]");
        try out.appendSlice(a, newline);
    }
    for (fields, 0..) |f, j| if (!seen[j]) {
        if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(a, newline);
        try out.appendSlice(a, f.key);
        try out.appendSlice(a, " = ");
        try out.appendSlice(a, f.value);
        try out.appendSlice(a, newline);
    };
    if (found) |section| try out.appendSlice(a, text[section.end..]);
    return out.toOwnedSlice(a);
}

pub fn merged(a: A, original: []const u8, cfg: models.ProxyConfig) !struct { text: []const u8, result: Result } {
    const buffers = std.heap.page_allocator;
    var text = try mergeSection(buffers, original, "providers", "freepro", &.{
        .{ .key = "type", .value = "\"openai\"" },
        .{ .key = "base_url", .value = try quoted(a, try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1", .{cfg.port})) },
        .{ .key = "api_key", .value = "\"freepro-local\"", .only_missing = true },
    });
    defer buffers.free(text);
    const existing = try sections(a, original);
    var result: Result = .{ .changed = false, .added = 0, .updated = 0, .model_count = 0 };
    for (cfg.providers) |p| for (p.models) |m| {
        if (!m.enabled or ((cfg.hide_paid or cfg.free_mode) and !m.isFree())) continue;
        const alias = try std.fmt.allocPrint(a, "freepro/{s}", .{m.id});
        var present = false;
        for (existing) |s| if (isSection(s, "models", alias)) {
            present = true;
            break;
        };
        var efforts: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, if (m.reasoning_levels.len == 0) models.default_reasoning_levels else m.reasoning_levels, ',');
        while (it.next()) |level| {
            const v = trim(level);
            if (v.len != 0) try efforts.append(a, v);
        }
        const before = text;
        text = try mergeSection(buffers, text, "models", alias, &.{
            .{ .key = "provider", .value = "\"freepro\"" },
            .{ .key = "model", .value = try quoted(a, m.id) },
            .{ .key = "max_context_size", .value = try std.fmt.allocPrint(a, "{d}", .{if (m.context_window == 0) @as(u64, 131072) else m.context_window}), .only_missing = m.context_window == 0 },
            .{ .key = "display_name", .value = try quoted(a, m.upstream_id), .only_missing = true },
            .{ .key = "capabilities", .value = "[\"tool_use\", \"thinking\"]", .only_missing = true },
            .{ .key = "support_efforts", .value = try std.json.Stringify.valueAlloc(a, efforts.items, .{}) },
        });
        if (!present) result.added += 1 else if (!std.mem.eql(u8, before, text)) result.updated += 1;
        buffers.free(before);
        result.model_count += 1;
    };
    if (result.model_count == 0) return error.NoEnabledModels;
    result.changed = !std.mem.eql(u8, original, text);
    return .{ .text = try a.dupe(u8, text), .result = result };
}

pub fn read(a: A, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(cap));
}
fn writeFile(io: std.Io, path: []const u8, text: []const u8, exclusive: bool) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = exclusive });
    defer f.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = f.writer(io, &buffer);
    try writer.interface.writeAll(text);
    try writer.flush();
    try f.sync(io);
}
pub fn apply(a: A, io: std.Io, path: []const u8, cfg: models.ProxyConfig) !Result {
    const original = read(a, io, path) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    const update = try merged(a, original, cfg);
    if (!update.result.changed) return update.result;
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path) orelse return error.InvalidPath);
    const backup = try std.fmt.allocPrint(a, "{s}.freepro.bak", .{path});
    if (original.len != 0) writeFile(io, backup, original, true) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var random: [8]u8 = undefined;
    io.random(&random);
    const temp = try std.fmt.allocPrint(a, "{s}.freepro-{x}.tmp", .{ path, random });
    defer std.Io.Dir.cwd().deleteFile(io, temp) catch {};
    try writeFile(io, temp, update.text, true);
    const current = read(a, io, path) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    if (!std.mem.eql(u8, original, current)) return error.ConfigChanged;
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), path, io);
    return update.result;
}

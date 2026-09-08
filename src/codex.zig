// src/codex.zig - inbound OpenAI Responses API bridge (Codex CLI / Codex Desktop).
//
// Codex speaks the Responses wire and nothing else: codex-rs documents
// `wire_api = "responses"` as the only supported value for a custom provider.
// freepro's upstreams speak Chat Completions, so this module bridges both
// directions:
//
//   responses request -> chat request      (toChatBody)
//   chat JSON reply   -> responses reply   (Bridge.replyJson)
//   chat SSE stream   -> responses SSE     (Bridge.Stream)
//
// The event vocabulary mirrors what codex-rs actually consumes, from
// codex-api/src/sse/responses.rs: assistant text arrives through
// response.output_text.delta, but tool calls ONLY through
// response.output_item.done (function_call_arguments.delta/.done are parsed
// and dropped). A stream that ends without response.completed is reported to
// the user as "stream closed before response.completed", so finish() always
// emits one.
//
// Offline build: std-only. Builders return caller-owned memory.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Error = error{ BadResponsesRequest };

// -- JSON building helpers ----------------------------------------------------

fn appendInt(alloc: Allocator, out: *std.ArrayList(u8), v: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, "{d}", .{v});
    defer alloc.free(s);
    try out.appendSlice(alloc, s);
}

fn appendQuoted(alloc: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    const q = try std.json.Stringify.valueAlloc(alloc, std.json.Value{ .string = s }, .{});
    defer alloc.free(q);
    try out.appendSlice(alloc, q);
}

fn appendJson(alloc: Allocator, out: *std.ArrayList(u8), v: std.json.Value) !void {
    const s = try std.json.Stringify.valueAlloc(alloc, v, .{});
    defer alloc.free(s);
    try out.appendSlice(alloc, s);
}

fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

// -- request: responses -> chat ----------------------------------------------

/// A chat message under construction. `calls` stays open so consecutive
/// `function_call` input items collapse into one assistant turn, which is what
/// the chat wire requires before their `tool` replies.
const Msg = struct {
    role: []const u8,
    text: ?[]const u8 = null,
    parts: ?[]const u8 = null, // pre-rendered chat content array (image turns)
    calls: ?std.ArrayList(u8) = null, // tool_call entries, comma separated
    tool_call_id: ?[]const u8 = null,
};

pub const Translated = struct {
    body: []u8,
    /// Names of `custom` tools rewritten into function tools; the reply
    /// encoder has to turn their calls back into `custom_tool_call` items.
    custom_tools: [][]const u8,
};

/// Convert a `/v1/responses` request body into a chat/completions body.
/// Hosted tools (web_search, file_search, code_interpreter) are dropped: no
/// chat upstream can execute them. `store`, `include`, `previous_response_id`
/// and `client_metadata` are ignored — freepro is stateless and Codex resends
/// the full item history on every turn.
pub fn toChatBody(alloc: Allocator, req: []const u8) !Translated {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, req, .{}) catch
        return Error.BadResponsesRequest;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return Error.BadResponsesRequest,
    };

    var custom: std.ArrayList([]const u8) = .empty;
    errdefer custom.deinit(alloc);

    var msgs: std.ArrayList(Msg) = .empty;
    errdefer msgs.deinit(alloc);

    if (obj.get("instructions")) |iv| {
        if (iv == .string and iv.string.len != 0) {
            try msgs.append(alloc, .{ .role = "system", .text = iv.string });
        }
    }

    if (obj.get("input")) |input| {
        switch (input) {
            .string => try msgs.append(alloc, .{ .role = "user", .text = input.string }),
            .array => for (input.array.items) |item| {
                try pushInputItem(alloc, &msgs, item);
            },
            else => return Error.BadResponsesRequest,
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"model\":");
    switch (obj.get("model") orelse return Error.BadResponsesRequest) {
        .string => |m| try appendQuoted(alloc, &out, m),
        else => return Error.BadResponsesRequest,
    }

    var stream = false;
    if (obj.get("stream")) |sv| {
        if (sv == .bool) stream = sv.bool;
    }
    try out.appendSlice(alloc, ",\"stream\":");
    try out.appendSlice(alloc, if (stream) "true" else "false");
    if (stream) try out.appendSlice(alloc, ",\"stream_options\":{\"include_usage\":true}");

    try out.appendSlice(alloc, ",\"messages\":[");
    for (msgs.items, 0..) |m, i| {
        if (i != 0) try out.appendSlice(alloc, ",");
        try renderMsg(alloc, &out, m);
    }
    try out.appendSlice(alloc, "]");

    if (obj.get("tools")) |tv| {
        if (tv == .array) {
            var written: usize = 0;
            var body_buf: std.ArrayList(u8) = .empty;
            errdefer body_buf.deinit(alloc);
            try writeTools(alloc, &body_buf, tv, &custom, &written);
            if (written != 0) {
                try out.appendSlice(alloc, ",\"tools\":[");
                try out.appendSlice(alloc, body_buf.items);
                try out.appendSlice(alloc, "]");
            }
            body_buf.deinit(alloc);
        }
    }

    if (obj.get("tool_choice")) |tc| {
        switch (tc) {
            .string => {
                try out.appendSlice(alloc, ",\"tool_choice\":");
                try appendJson(alloc, &out, tc);
            },
            .object => {
                const kind = strField(tc.object, "type");
                if (kind) |k| {
                    if (std.mem.eql(u8, k, "function")) {
                        if (tc.object.get("name") != null) {
                            try out.appendSlice(alloc, ",\"tool_choice\":{\"type\":\"function\",\"function\":{\"name\":");
                            try appendJson(alloc, &out, tc.object.get("name").?);
                            try out.appendSlice(alloc, "}}");
                        }
                    } else if (std.mem.eql(u8, k, "none") or std.mem.eql(u8, k, "auto") or
                        std.mem.eql(u8, k, "required"))
                    {
                        try out.appendSlice(alloc, ",\"tool_choice\":\"");
                        try out.appendSlice(alloc, k);
                        try out.appendSlice(alloc, "\"");
                    }
                }
            },
            else => {},
        }
    }

    if (obj.get("max_output_tokens")) |v| {
        if (v == .integer) {
            try out.appendSlice(alloc, ",\"max_tokens\":");
            try appendJson(alloc, &out, v);
        }
    }
    if (obj.get("reasoning")) |rv| {
        if (rv == .object) {
            if (strField(rv.object, "effort")) |eff| {
                if (!std.mem.eql(u8, eff, "none")) {
                    try out.appendSlice(alloc, ",\"reasoning_effort\":");
                    try appendQuoted(alloc, &out, eff);
                }
            }
        }
    }
    inline for (.{
        "temperature",
        "top_p",
        "presence_penalty",
        "frequency_penalty",
        "seed",
        "stop",
        "user",
        "parallel_tool_calls",
    }) |k| {
        if (obj.get(k)) |v| {
            if (v != .null) {
                try out.appendSlice(alloc, ",\"");
                try out.appendSlice(alloc, k);
                try out.appendSlice(alloc, "\":");
                try appendJson(alloc, &out, v);
            }
        }
    }
    try out.appendSlice(alloc, "}");

    const body = try out.toOwnedSlice(alloc);
    const custom_tools = try custom.toOwnedSlice(alloc);

    // Deinit intermediate messages: their owned strings (text/parts/calls)
    // were borrowed during rendering and are no longer needed.
    for (msgs.items) |*m| {
        if (m.calls) |*c| c.deinit(alloc);
    }
    msgs.deinit(alloc);

    return .{ .body = body, .custom_tools = custom_tools };
}

/// Append one `input` item to the message list. Unknown/unmappable item types
/// (reasoning, web_search_call, compaction, ...) are skipped: their content is
/// either provider-internal or already reflected in a following output item.
fn pushInputItem(alloc: Allocator, msgs: *std.ArrayList(Msg), item: std.json.Value) !void {
    if (item == .string) {
        try msgs.append(alloc, .{ .role = "user", .text = item.string });
        return;
    }
    if (item != .object) return;
    const o = item.object;
    const kind = strField(o, "type") orelse "message";

    if (std.mem.eql(u8, kind, "message")) {
        const role = strField(o, "role") orelse "user";
        var mapped: []const u8 = role;
        if (std.mem.eql(u8, role, "assistant")) {
            mapped = "assistant";
        } else if (std.mem.eql(u8, role, "system") or std.mem.eql(u8, role, "developer")) {
            mapped = role;
        } else mapped = "user";

        var text: std.ArrayList(u8) = .empty;
        var parts: std.ArrayList(u8) = .empty;
        var only_text = true;
        const content = o.get("content") orelse return;
        switch (content) {
            .string => |s| try text.appendSlice(alloc, s),
            .array => for (content.array.items) |part| {
                if (part == .string) {
                    try text.appendSlice(alloc, part.string);
                    continue;
                }
                if (part != .object) continue;
                const pt = strField(part.object, "type") orelse continue;
                if (std.mem.eql(u8, pt, "input_text") or std.mem.eql(u8, pt, "output_text")) {
                    const t = strField(part.object, "text") orelse continue;
                    if (text.items.len != 0) try text.appendSlice(alloc, "\n");
                    try text.appendSlice(alloc, t);
                } else if (std.mem.eql(u8, pt, "refusal")) {
                    if (strField(part.object, "refusal")) |t| try text.appendSlice(alloc, t);
                } else if (std.mem.eql(u8, pt, "input_image")) {
                    only_text = false;
                    const url = strField(part.object, "image_url") orelse continue;
                    if (parts.items.len != 0) try parts.appendSlice(alloc, ",");
                    try parts.appendSlice(alloc, "{\"type\":\"image_url\",\"image_url\":{\"url\":");
                    try appendQuoted(alloc, &parts, url);
                    try parts.appendSlice(alloc, "}}");
                }
            },
            else => return,
        }
        if (only_text) {
            try msgs.append(alloc, .{ .role = mapped, .text = text.items });
            text.deinit(alloc);
        } else {
            // Keep the text we collected too, so a mixed turn does not lose it.
            if (text.items.len != 0) {
                if (parts.items.len != 0) try parts.appendSlice(alloc, ",");
                try parts.appendSlice(alloc, "{\"type\":\"text\",\"text\":");
                try appendQuoted(alloc, &parts, text.items);
                try parts.appendSlice(alloc, "}");
            }
            text.deinit(alloc);
            try msgs.append(alloc, .{ .role = mapped, .parts = try parts.toOwnedSlice(alloc) });
        }
        return;
    }

    if (std.mem.eql(u8, kind, "function_call")) {
        const entry = std.ArrayList(u8).fromOwnedSlice(try callEntry(
            alloc,
            strField(o, "call_id") orelse "call_unknown",
            strField(o, "name") orelse return,
            strField(o, "arguments") orelse "{}",
        ));
        try mergeCall(alloc, msgs, entry);
        return;
    }

    if (std.mem.eql(u8, kind, "custom_tool_call")) {
        // Registered as a function tool taking one string; replay it the same way.
        var args: std.ArrayList(u8) = .empty;
        try args.appendSlice(alloc, "{\"input\":");
        try appendQuoted(alloc, &args, strField(o, "input") orelse "");
        try args.appendSlice(alloc, "}");
        const entry = std.ArrayList(u8).fromOwnedSlice(try callEntry(
            alloc,
            strField(o, "call_id") orelse "call_unknown",
            strField(o, "name") orelse return,
            args.items,
        ));
        try mergeCall(alloc, msgs, entry);
        return;
    }

    if (std.mem.eql(u8, kind, "function_call_output") or
        std.mem.eql(u8, kind, "custom_tool_call_output") or
        std.mem.eql(u8, kind, "tool_result"))
    {
        var text: std.ArrayList(u8) = .empty;
        if (o.get("output")) |ov| try flattenToolOutput(alloc, &text, ov);
        try msgs.append(alloc, .{
            .role = "tool",
            .text = text.items,
            .tool_call_id = strField(o, "call_id") orelse "call_unknown",
        });
        return;
    }
}

/// Render `{"id":..,"type":"function","function":{"name":..,"arguments":..}}`.
fn callEntry(alloc: Allocator, call_id: []const u8, name: []const u8, arguments: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(alloc, "{\"id\":");
    try appendQuoted(alloc, &buf, call_id);
    try buf.appendSlice(alloc, ",\"type\":\"function\",\"function\":{\"name\":");
    try appendQuoted(alloc, &buf, name);
    try buf.appendSlice(alloc, ",\"arguments\":");
    // Arguments are a JSON document carried as a string; re-embed them raw when
    // they already parse, so upstreams see a well-formed value either way.
    if (std.json.parseFromSlice(std.json.Value, alloc, arguments, .{})) |p| {
        p.deinit();
        try buf.appendSlice(alloc, arguments);
    } else |_| {
        try appendQuoted(alloc, &buf, arguments);
    }
    try buf.appendSlice(alloc, "}}");
    return buf.toOwnedSlice(alloc);
}

/// Attach a tool call to the trailing assistant turn, or open a new one.
fn mergeCall(alloc: Allocator, msgs: *std.ArrayList(Msg), entry: std.ArrayList(u8)) !void {
    if (msgs.items.len != 0) {
        const last = &msgs.items[msgs.items.len - 1];
        if (last.calls != null and last.text == null and last.parts == null) {
            const c = &last.calls.?;
            if (c.items.len != 0) try c.append(alloc, ',');
            try c.appendSlice(alloc, entry.items);
            return;
        }
    }
    try msgs.append(alloc, .{ .role = "assistant", .calls = entry });
}

/// Flatten a `function_call_output.output` (string, parts array, or object) to text.
fn flattenToolOutput(alloc: Allocator, text: *std.ArrayList(u8), v: std.json.Value) !void {
    switch (v) {
        .string => try text.appendSlice(alloc, v.string),
        .integer, .float, .bool => try appendJson(alloc, text, v),
        .array => for (v.array.items) |part| {
            switch (part) {
                .string => {
                    if (text.items.len != 0) try text.appendSlice(alloc, "\n");
                    try text.appendSlice(alloc, part.string);
                },
                .object => {
                    if (strField(part.object, "text")) |t| {
                        if (text.items.len != 0) try text.appendSlice(alloc, "\n");
                        try text.appendSlice(alloc, t);
                    } else if (strField(part.object, "content")) |t| {
                        if (text.items.len != 0) try text.appendSlice(alloc, "\n");
                        try text.appendSlice(alloc, t);
                    } else if (part.object.get("output")) |ov| {
                        try flattenToolOutput(alloc, text, ov);
                    }
                },
                else => {},
            }
        },
        .object => {
            if (strField(v.object, "text")) |t| {
                try text.appendSlice(alloc, t);
            } else {
                try appendJson(alloc, text, v);
            }
        },
        else => {},
    }
}

fn renderMsg(alloc: Allocator, out: *std.ArrayList(u8), m: Msg) !void {
    try out.appendSlice(alloc, "{\"role\":");
    try appendQuoted(alloc, out, m.role);
    if (m.calls) |calls| {
        try out.appendSlice(alloc, ",\"tool_calls\":[");
        try out.appendSlice(alloc, calls.items);
        try out.appendSlice(alloc, "]");
        if (m.text) |t| {
            if (t.len != 0) {
                try out.appendSlice(alloc, ",\"content\":");
                try appendQuoted(alloc, out, t);
            }
        }
        try out.appendSlice(alloc, "}");
        return;
    }
    if (m.tool_call_id) |id| {
        try out.appendSlice(alloc, ",\"tool_call_id\":");
        try appendQuoted(alloc, out, id);
        try out.appendSlice(alloc, ",\"content\":");
        try appendQuoted(alloc, out, m.text orelse "");
        try out.appendSlice(alloc, "}");
        return;
    }
    if (m.parts) |parts| {
        try out.appendSlice(alloc, ",\"content\":[");
        try out.appendSlice(alloc, parts);
        try out.appendSlice(alloc, "]}");
        return;
    }
    try out.appendSlice(alloc, ",\"content\":");
    try appendQuoted(alloc, out, m.text orelse "");
    try out.appendSlice(alloc, "}");
}

/// Translate a Responses `tools` array into chat form. `namespace` groups are
/// flattened (their members are addressed by bare name on the wire); `custom`
/// tools become single-string-argument functions and are recorded so the reply
/// encoder can restore them.
fn writeTools(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    tv: std.json.Value,
    custom: *std.ArrayList([]const u8),
    written: *usize,
) !void {
    if (tv != .array) return;
    for (tv.array.items) |tool| {
        if (tool != .object) continue;
        const o = tool.object;
        const kind = strField(o, "type") orelse continue;
        if (std.mem.eql(u8, kind, "function")) {
            const name = strField(o, "name") orelse continue;
            if (written.* != 0) try out.appendSlice(alloc, ",");
            written.* += 1;
            try out.appendSlice(alloc, "{\"type\":\"function\",\"function\":{\"name\":");
            try appendQuoted(alloc, out, name);
            if (strField(o, "description")) |d| {
                try out.appendSlice(alloc, ",\"description\":");
                try appendQuoted(alloc, out, d);
            }
            try out.appendSlice(alloc, ",\"parameters\":");
            if (o.get("parameters")) |p| {
                try appendJson(alloc, out, p);
            } else try out.appendSlice(alloc, "{\"type\":\"object\",\"properties\":{}}");
            if (o.get("strict")) |s| {
                try out.appendSlice(alloc, ",\"strict\":");
                try appendJson(alloc, out, s);
            }
            try out.appendSlice(alloc, "}}");
            continue;
        }
        if (std.mem.eql(u8, kind, "namespace")) {
            if (o.get("tools")) |inner| try writeTools(alloc, out, inner, custom, written);
            continue;
        }
        if (std.mem.eql(u8, kind, "custom")) {
            const name = strField(o, "name") orelse continue;
            if (written.* != 0) try out.appendSlice(alloc, ",");
            written.* += 1;
            // The parsed request is torn down before the caller uses this list.
            try custom.append(alloc, try alloc.dupe(u8, name));
            try out.appendSlice(alloc,
                \\{"type":"function","function":{"name":
            );
            try appendQuoted(alloc, out, name);
            if (strField(o, "description")) |d| {
                try out.appendSlice(alloc, ",\"description\":");
                try appendQuoted(alloc, out, d);
            }
            try out.appendSlice(alloc,
                \\,"parameters":{"type":"object","properties":{"input":{"type":"string"}},"required":["input"],"additionalProperties":false},"strict":false}}
            );
            continue;
        }
        // web_search / file_search / code_interpreter / image_generation /
        // local_shell: hosted tools with no chat equivalent.
    }
}

// -- reply: chat -> responses -------------------------------------------------

var reply_seq: u64 = 0;

/// Unix milliseconds. Zig 0.16 moved the wall clock behind std.Io, which these
/// builders must not depend on, so the OS clock is read directly (mirrors
/// src/proxy.zig).
fn nowMs() i64 {
    if (@hasDecl(std.time, "milliTimestamp")) return std.time.milliTimestamp();
    if (builtin.os.tag == .windows) {
        const ticks_100ns: i64 = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        return @divFloor(ticks_100ns, 10_000) - 11_644_473_600_000;
    }
    var ts: std.posix.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1_000 + @divFloor(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn newId(alloc: Allocator, prefix: []const u8) ![]u8 {
    const n = @atomicRmw(u64, &reply_seq, .Add, 1, .monotonic);
    const stamp: u64 = @intCast(@max(0, nowMs()));
    return std.fmt.allocPrint(alloc, "{s}{x}{x}", .{ prefix, stamp, n });
}

/// Deterministic message item id derived from the response id.
fn msgId(alloc: Allocator, resp_id: []const u8, index: usize) ![]u8 {
    return std.fmt.allocPrint(alloc, "msg_{s}_{d}", .{ resp_id, index });
}

fn usageJson(alloc: Allocator, out: *std.ArrayList(u8), input: u64, output: u64, cached: u64) !void {
    try out.appendSlice(alloc, ",\"usage\":{\"input_tokens\":");
    try appendInt(alloc, out, input);
    try out.appendSlice(alloc, ",\"output_tokens\":");
    try appendInt(alloc, out, output);
    try out.appendSlice(alloc, ",\"total_tokens\":");
    try appendInt(alloc, out, input + output);
    try out.appendSlice(alloc, ",\"input_tokens_details\":{\"cached_tokens\":");
    try appendInt(alloc, out, cached);
    try out.appendSlice(alloc, "},\"output_tokens_details\":{\"reasoning_tokens\":0}}");
}

pub const Bridge = struct {
    alloc: Allocator,
    /// Model id echoed back to the client — the caller's own (prefixed) name,
    /// not the upstream's stripped one.
    model: []const u8,
    id: []u8,
    custom_tools: [][]const u8,

    pub fn init(alloc: Allocator, model: []const u8, custom_tools: [][]const u8) !Bridge {
        return .{
            .alloc = alloc,
            .model = model,
            .id = try newId(alloc, "resp_"),
            .custom_tools = custom_tools,
        };
    }

    fn isCustom(self: *const Bridge, name: []const u8) bool {
        for (self.custom_tools) |c| {
            if (std.mem.eql(u8, c, name)) return true;
        }
        return false;
    }

    /// Build a complete Responses document from a chat JSON reply.
    pub fn replyJson(self: *const Bridge, chat: []const u8) ![]u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, chat, .{}) catch
            return Error.BadResponsesRequest;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return Error.BadResponsesRequest,
        };
        var in_tok: u64 = 0;
        var out_tok: u64 = 0;
        var cached: u64 = 0;
        if (root.get("usage")) |uv| {
            if (uv == .object) {
                in_tok = @intCast(@max(0, intField(uv.object, "prompt_tokens") orelse 0));
                out_tok = @intCast(@max(0, intField(uv.object, "completion_tokens") orelse 0));
                if (uv.object.get("prompt_tokens_details")) |dv| {
                    if (dv == .object) cached = @intCast(@max(0, intField(dv.object, "cached_tokens") orelse 0));
                }
            }
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.alloc);
        try out.appendSlice(self.alloc, "{\"id\":");
        try appendQuoted(self.alloc, &out, self.id);
        try out.appendSlice(self.alloc, ",\"object\":\"response\",\"created_at\":");
        try appendInt(self.alloc, &out, @divFloor(@max(0, nowMs()), 1000));
        try out.appendSlice(self.alloc, ",\"status\":\"completed\",\"model\":");
        try appendQuoted(self.alloc, &out, self.model);
        try out.appendSlice(self.alloc, ",\"output\":[");

        var items: usize = 0;
        var text: []const u8 = "";
        var text_acc: std.ArrayList(u8) = .empty;
        defer text_acc.deinit(self.alloc);
        var calls: ?std.json.Value = null;
        if (root.get("choices")) |cv| {
            if (cv == .array and cv.array.items.len != 0) {
                const ch = cv.array.items[0];
                if (ch == .object) {
                    if (ch.object.get("message")) |msg| {
                        if (msg == .object) {
                            if (msg.object.get("content")) |ct| {
                                switch (ct) {
                                    .string => text = ct.string,
                                    .array => {
                                        for (ct.array.items) |part| {
                                            if (part == .object) {
                                                if (strField(part.object, "text")) |t| {
                                                    if (text_acc.items.len != 0) try text_acc.appendSlice(self.alloc, "\n");
                                                    try text_acc.appendSlice(self.alloc, t);
                                                }
                                            }
                                        }
                                        text = text_acc.items;
                                    },
                                    else => {},
                                }
                            }
                            calls = msg.object.get("tool_calls");
                        }
                    }
                }
            }
        }
        if (text.len != 0) {
            try out.appendSlice(self.alloc, "{\"type\":\"message\",\"id\":");
            try appendQuoted(self.alloc, &out, try newId(self.alloc, "msg_"));
            try out.appendSlice(self.alloc, ",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":");
            try appendQuoted(self.alloc, &out, text);
            try out.appendSlice(self.alloc, ",\"annotations\":[]}]}");
            items += 1;
        }
        if (calls) |cv| {
            if (cv == .array) for (cv.array.items) |tc| {
                if (tc != .object) continue;
                const fnv = tc.object.get("function") orelse continue;
                if (fnv != .object) continue;
                const name = strField(fnv.object, "name") orelse continue;
                var args: []const u8 = strField(fnv.object, "arguments") orelse "{}";
                if (self.isCustom(name)) args = customInput(self.alloc, args);
                if (items != 0) try out.appendSlice(self.alloc, ",");
                items += 1;
                if (self.isCustom(name)) {
                    try out.appendSlice(self.alloc, "{\"type\":\"custom_tool_call\",\"id\":");
                    try appendQuoted(self.alloc, &out, try newId(self.alloc, "ctc_"));
                    try out.appendSlice(self.alloc, ",\"call_id\":");
                    try appendQuoted(self.alloc, &out, strField(tc.object, "id") orelse "call_unknown");
                    try out.appendSlice(self.alloc, ",\"name\":");
                    try appendQuoted(self.alloc, &out, name);
                    try out.appendSlice(self.alloc, ",\"input\":");
                    try appendQuoted(self.alloc, &out, args);
                    try out.appendSlice(self.alloc, "}");
                } else {
                    try out.appendSlice(self.alloc, "{\"type\":\"function_call\",\"id\":");
                    try appendQuoted(self.alloc, &out, try newId(self.alloc, "fc_"));
                    try out.appendSlice(self.alloc, ",\"call_id\":");
                    try appendQuoted(self.alloc, &out, strField(tc.object, "id") orelse "call_unknown");
                    try out.appendSlice(self.alloc, ",\"name\":");
                    try appendQuoted(self.alloc, &out, name);
                    try out.appendSlice(self.alloc, ",\"arguments\":");
                    try appendQuoted(self.alloc, &out, args);
                    try out.appendSlice(self.alloc, "}");
                }
            };
        }
        try out.appendSlice(self.alloc, "]");
        try usageJson(self.alloc, &out, in_tok, out_tok, cached);
        try out.appendSlice(self.alloc, ",\"error\":null}");
        return out.toOwnedSlice(self.alloc);
    }

    /// Start an incremental chat-SSE -> responses-SSE encoder.
    pub fn stream(self: *Bridge, writer: *std.Io.Writer) !Stream {
        return Stream.init(self, writer);
    }
};

/// Unwrap the `{"input": "..."}` envelope a custom tool was mapped into.
/// Falls back to the raw arguments when they are not that shape.
fn customInput(alloc: Allocator, args: []const u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, args, .{}) catch return args;
    defer parsed.deinit();
    if (parsed.value != .object) return args;
    return strField(parsed.value.object, "input") orelse args;
}

// -- streaming reply ---------------------------------------------------------

const Call = struct {
    call_id: []u8,
    name: []u8,
    args: std.ArrayList(u8),
};

/// Incremental encoder: chat SSE bytes in, Responses SSE events out.
///
/// Two arenas: `arena` holds only what must survive the stream (assistant text
/// and accumulated tool calls), `scratch` is rewound for every upstream event,
/// so parse trees and rendered frames never pile up over a long generation.
pub const Stream = struct {
    bridge: *Bridge,
    writer: *std.Io.Writer,
    arena: std.heap.ArenaAllocator,
    scratch: std.heap.ArenaAllocator,
    line: std.ArrayList(u8) = .empty,
    text: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(Call) = .empty,
    msg_open: bool = false,
    out_index: usize = 0,
    msg_index: usize = 0,
    in_tok: u64 = 0,
    out_tok: u64 = 0,
    cached_tok: u64 = 0,
    finished: bool = false,

    fn init(bridge: *Bridge, writer: *std.Io.Writer) Stream {
        return .{
            .bridge = bridge,
            .writer = writer,
            .arena = .init(bridge.alloc),
            .scratch = .init(bridge.alloc),
        };
    }

    pub fn deinit(self: *Stream) void {
        self.line.deinit(self.arena.allocator());
        self.text.deinit(self.arena.allocator());
        self.calls.deinit(self.arena.allocator());
        self.scratch.deinit();
        self.arena.deinit();
    }

    /// HTTP head plus the opening response lifecycle events.
    pub fn head(self: *Stream) !void {
        try self.writer.writeAll(
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/event-stream\r\n" ++
                "Cache-Control: no-cache\r\n" ++
                "Transfer-Encoding: chunked\r\n" ++
                "Connection: close\r\n\r\n",
        );
        const scratch = self.scratch.allocator();
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(scratch, "{\"type\":\"response.created\",\"response\":{\"id\":");
        try appendQuoted(scratch, &buf, self.bridge.id);
        try buf.appendSlice(scratch, ",\"object\":\"response\",\"status\":\"in_progress\",\"model\":");
        try appendQuoted(scratch, &buf, self.bridge.model);
        try buf.appendSlice(scratch, "}}");
        try self.emit(buf.items);

        buf.clearRetainingCapacity();
        try buf.appendSlice(scratch, "{\"type\":\"response.in_progress\",\"response\":{\"id\":");
        try appendQuoted(scratch, &buf, self.bridge.id);
        try buf.appendSlice(scratch, ",\"status\":\"in_progress\"}}");
        try self.emit(buf.items);
    }

    fn emit(self: *Stream, payload: []const u8) !void {
        const scratch = self.scratch.allocator();
        var frame: std.ArrayList(u8) = .empty;
        try frame.appendSlice(scratch, "data: ");
        try frame.appendSlice(scratch, payload);
        try frame.appendSlice(scratch, "\n\n");
        try writeChunked(self.writer, frame.items);
    }

    /// Feed raw upstream bytes; complete SSE lines are dispatched immediately.
    pub fn feed(self: *Stream, bytes: []const u8) !void {
        const alloc = self.arena.allocator();
        for (bytes) |b| {
            if (b == '\n') {
                try self.takeLine(self.line.items);
                self.line.clearRetainingCapacity();
                continue;
            }
            if (b == '\r') continue;
            try self.line.append(alloc, b);
        }
    }

    /// Flush a trailing line the upstream ended without a newline on.
    pub fn flushPending(self: *Stream) !void {
        if (self.line.items.len == 0) return;
        try self.takeLine(self.line.items);
        self.line.clearRetainingCapacity();
    }

    fn takeLine(self: *Stream, raw: []const u8) !void {
        const line = std.mem.trimStart(u8, raw, " \t");
        if (!std.mem.startsWith(u8, line, "data:")) return;
        const payload = std.mem.trim(u8, line["data:".len..], " \t");
        if (payload.len == 0) return;
        if (std.mem.eql(u8, payload, "[DONE]")) return;

        _ = self.scratch.reset(.retain_capacity);
        const scratch = self.scratch.allocator();
        const parsed = std.json.parseFromSlice(std.json.Value, scratch, payload, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const root = parsed.value.object;

        if (root.get("usage")) |uv| {
            if (uv == .object) {
                if (intField(uv.object, "prompt_tokens")) |v| self.in_tok = @intCast(@max(0, v));
                if (intField(uv.object, "completion_tokens")) |v| self.out_tok = @intCast(@max(0, v));
                if (uv.object.get("prompt_tokens_details")) |dv| {
                    if (dv == .object) {
                        if (intField(dv.object, "cached_tokens")) |v| self.cached_tok = @intCast(@max(0, v));
                    }
                }
            }
        }

        const choices = root.get("choices") orelse return;
        if (choices != .array or choices.array.items.len == 0) return;
        const ch = choices.array.items[0];
        if (ch != .object) return;

        const dv = ch.object.get("delta") orelse return;
        if (dv != .object) return;

        if (dv.object.get("content")) |ct| {
            switch (ct) {
                .string => |s| if (s.len != 0) try self.textDelta(s),
                .array => for (ct.array.items) |part| {
                    if (part == .object) {
                        if (strField(part.object, "text")) |t| {
                            if (t.len != 0) try self.textDelta(t);
                        }
                    }
                },
                else => {},
            }
        }
        if (dv.object.get("tool_calls")) |tc| {
            if (tc == .array) for (tc.array.items) |entry| {
                if (entry == .object) try self.toolDelta(entry.object);
            };
        }
    }

    fn textDelta(self: *Stream, delta: []const u8) !void {
        const alloc = self.arena.allocator();
        const scratch = self.scratch.allocator();
        if (!self.msg_open) try self.openMessage();
        try self.text.appendSlice(alloc, delta);
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(scratch, "{\"type\":\"response.output_text.delta\",\"item_id\":");
        try appendQuoted(scratch, &buf, try msgId(scratch, self.bridge.id, self.msg_index));
        try buf.appendSlice(scratch, ",\"output_index\":");
        try appendInt(scratch, &buf, self.msg_index);
        try buf.appendSlice(scratch, ",\"content_index\":0,\"delta\":");
        try appendQuoted(scratch, &buf, delta);
        try buf.appendSlice(scratch, "}");
        try self.emit(buf.items);
    }

    fn openMessage(self: *Stream) !void {
        const scratch = self.scratch.allocator();
        self.msg_open = true;
        self.msg_index = self.out_index;
        self.out_index += 1;
        const mid = try msgId(scratch, self.bridge.id, self.msg_index);

        var added: std.ArrayList(u8) = .empty;
        try added.appendSlice(scratch, "{\"type\":\"response.output_item.added\",\"output_index\":");
        try appendInt(scratch, &added, self.msg_index);
        try added.appendSlice(scratch, ",\"item\":{\"type\":\"message\",\"id\":");
        try appendQuoted(scratch, &added, mid);
        try added.appendSlice(scratch, ",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}");
        try self.emit(added.items);

        added.clearRetainingCapacity();
        try added.appendSlice(scratch, "{\"type\":\"response.content_part.added\",\"item_id\":");
        try appendQuoted(scratch, &added, mid);
        try added.appendSlice(scratch, ",\"output_index\":");
        try appendInt(scratch, &added, self.msg_index);
        try added.appendSlice(scratch, ",\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"\"}}");
        try self.emit(added.items);
    }

    fn toolDelta(self: *Stream, entry: std.json.ObjectMap) !void {
        const alloc = self.arena.allocator();
        var idx: usize = self.calls.items.len;
        if (entry.get("index")) |iv| {
            if (iv == .integer) idx = @intCast(@max(0, iv.integer));
        }
        while (self.calls.items.len <= idx) {
            try self.calls.append(alloc, .{
                .call_id = try newId(alloc, "call_"),
                .name = "",
                .args = .empty,
            });
        }
        const call = &self.calls.items[idx];
        if (strField(entry, "call_id") orelse strField(entry, "id")) |id| {
            if (id.len != 0) call.call_id = try alloc.dupe(u8, id);
        }
        if (entry.get("function")) |fv| {
            if (fv == .object) {
                if (strField(fv.object, "name")) |n| {
                    if (n.len != 0) call.name = try alloc.dupe(u8, n);
                }
                if (strField(fv.object, "arguments")) |a| {
                    try call.args.appendSlice(alloc, a);
                }
            }
        }
    }

    /// Close the assistant message and every tool call, then complete.
    pub fn finish(self: *Stream) !void {
        if (self.finished) return;
        self.finished = true;
        _ = self.scratch.reset(.retain_capacity);
        const scratch = self.scratch.allocator();
        var buf: std.ArrayList(u8) = .empty;

        if (self.msg_open) {
            const mid = try msgId(scratch, self.bridge.id, self.msg_index);
            try buf.appendSlice(scratch, "{\"type\":\"response.output_text.done\",\"item_id\":");
            try appendQuoted(scratch, &buf, mid);
            try buf.appendSlice(scratch, ",\"output_index\":");
            try appendInt(scratch, &buf, self.msg_index);
            try buf.appendSlice(scratch, ",\"content_index\":0,\"text\":");
            try appendQuoted(scratch, &buf, self.text.items);
            try buf.appendSlice(scratch, "}");
            try self.emit(buf.items);

            buf.clearRetainingCapacity();
            try buf.appendSlice(scratch, "{\"type\":\"response.content_part.done\",\"item_id\":");
            try appendQuoted(scratch, &buf, mid);
            try buf.appendSlice(scratch, ",\"output_index\":");
            try appendInt(scratch, &buf, self.msg_index);
            try buf.appendSlice(scratch, ",\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":");
            try appendQuoted(scratch, &buf, self.text.items);
            try buf.appendSlice(scratch, "}}");
            try self.emit(buf.items);

            buf.clearRetainingCapacity();
            try buf.appendSlice(scratch, "{\"type\":\"response.output_item.done\",\"output_index\":");
            try appendInt(scratch, &buf, self.msg_index);
            try buf.appendSlice(scratch, ",\"item\":{\"type\":\"message\",\"id\":");
            try appendQuoted(scratch, &buf, mid);
            try buf.appendSlice(scratch, ",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":");
            try appendQuoted(scratch, &buf, self.text.items);
            try buf.appendSlice(scratch, ",\"annotations\":[]}]}}");
            try self.emit(buf.items);
        }

        for (self.calls.items) |*call| {
            if (call.name.len == 0) continue;
            const custom = self.bridge.isCustom(call.name);
            const args = if (custom) customInput(scratch, call.args.items) else call.args.items;
            const iid = try newId(scratch, if (custom) "ctc_" else "fc_");
            const idx = self.out_index;
            self.out_index += 1;

            buf.clearRetainingCapacity();
            try buf.appendSlice(scratch, "{\"type\":\"response.output_item.added\",\"output_index\":");
            try appendInt(scratch, &buf, idx);
            try buf.appendSlice(scratch, ",\"item\":{\"type\":");
            try appendQuoted(scratch, &buf, if (custom) "custom_tool_call" else "function_call");
            try buf.appendSlice(scratch, ",\"id\":");
            try appendQuoted(scratch, &buf, iid);
            try buf.appendSlice(scratch, ",\"call_id\":");
            try appendQuoted(scratch, &buf, call.call_id);
            try buf.appendSlice(scratch, ",\"name\":");
            try appendQuoted(scratch, &buf, call.name);
            try buf.appendSlice(scratch, if (custom) ",\"input\":\"\"}}" else ",\"arguments\":\"\"}}");
            try self.emit(buf.items);

            buf.clearRetainingCapacity();
            try buf.appendSlice(scratch, "{\"type\":\"response.output_item.done\",\"output_index\":");
            try appendInt(scratch, &buf, idx);
            try buf.appendSlice(scratch, ",\"item\":{\"type\":");
            try appendQuoted(scratch, &buf, if (custom) "custom_tool_call" else "function_call");
            try buf.appendSlice(scratch, ",\"id\":");
            try appendQuoted(scratch, &buf, iid);
            try buf.appendSlice(scratch, ",\"call_id\":");
            try appendQuoted(scratch, &buf, call.call_id);
            try buf.appendSlice(scratch, ",\"name\":");
            try appendQuoted(scratch, &buf, call.name);
            try buf.appendSlice(scratch, if (custom) ",\"input\":" else ",\"arguments\":");
            try appendQuoted(scratch, &buf, args);
            try buf.appendSlice(scratch, "}}");
            try self.emit(buf.items);
        }

        buf.clearRetainingCapacity();
        try buf.appendSlice(scratch, "{\"type\":\"response.completed\",\"response\":{\"id\":");
        try appendQuoted(scratch, &buf, self.bridge.id);
        try buf.appendSlice(scratch, ",\"object\":\"response\",\"status\":\"completed\",\"model\":");
        try appendQuoted(scratch, &buf, self.bridge.model);
        try buf.appendSlice(scratch, ",\"output\":[]");
        try usageJson(scratch, &buf, self.in_tok, self.out_tok, self.cached_tok);
        try buf.appendSlice(scratch, "}}");
        try self.emit(buf.items);
        // Terminating zero-length chunk: without it the client sees an
        // incomplete chunked body even though every event arrived.
        try self.writer.writeAll("0\r\n\r\n");
        try self.writer.flush();
    }
};

/// HTTP/1.1 chunked framing, matching what proxy.zig's SSE relay emits.
pub fn writeChunked(writer: *std.Io.Writer, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    var hexbuf: [16]u8 = undefined;
    const hex = std.fmt.bufPrint(&hexbuf, "{x}", .{bytes.len}) catch return;
    try writer.writeAll(hex);
    try writer.writeAll("\r\n");
    try writer.writeAll(bytes);
    try writer.writeAll("\r\n");
    try writer.flush();
}

// -- tests -------------------------------------------------------------------

const testing = std.testing;

/// Collect the `data:` payloads a Stream wrote, decoding the chunked framing.
const Frame = struct {
    alloc: Allocator,
    raw: []const u8,

    fn next(self: *Frame) ?[]const u8 {
        while (true) {
            if (self.raw.len == 0) return null;
            const nl = std.mem.indexOfScalar(u8, self.raw, '\n') orelse return null;
            const hex = self.raw[0..nl];
            const len = std.fmt.parseInt(usize, std.mem.trimEnd(u8, hex, "\r"), 16) catch {
                self.raw = "";
                return null;
            };
            const body_start = nl + 1;
            const body = self.raw[body_start..@min(body_start + len, self.raw.len)];
            self.raw = self.raw[@min(body_start + len + 2, self.raw.len)..];
            const trimmed = std.mem.trim(u8, body, " \r\n");
            if (trimmed.len == 0) continue;
            if (!std.mem.startsWith(u8, trimmed, "data: ")) continue;
            return trimmed["data: ".len..];
        }
    }
};

test "toChatBody maps instructions, input items and tools" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const req =
        \\{"model":"oc/m","instructions":"be terse","stream":true,"input":[
        \\{"type":"message","role":"developer","content":[{"type":"input_text","text":"ctx"}]},
        \\{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]},
        \\{"type":"function_call","call_id":"c1","name":"exec_command","arguments":"{\"cmd\":\"ls\"}"},
        \\{"type":"function_call","call_id":"c2","name":"write_stdin","arguments":"{}"},
        \\{"type":"function_call_output","call_id":"c1","output":"file.c"},
        \\{"type":"reasoning","id":"r1","summary":[],"encrypted_content":"zzz"}
        \\],"tools":[
        \\{"type":"function","name":"exec_command","parameters":{"type":"object"},"strict":false},
        \\{"type":"namespace","name":"ma","tools":[{"type":"function","name":"close_agent","parameters":{}}]},
        \\{"type":"web_search","external_web_access":false},
        \\{"type":"custom","name":"apply_patch","description":"patch"}],
        \\"tool_choice":"auto","max_output_tokens":512,"reasoning":{"effort":"low"},
        \\"parallel_tool_calls":true,"store":false,"include":["reasoning.encrypted_content"]}
    ;
    const t = try toChatBody(alloc, req);

    const p = try std.json.parseFromSlice(std.json.Value, alloc, t.body, .{});
    defer p.deinit();
    const o = p.value.object;
    try testing.expectEqualStrings("oc/m", strField(o, "model").?);
    try testing.expect(o.get("stream").?.bool);
    try testing.expect(o.get("stream_options") != null);
    try testing.expectEqual(@as(i64, 512), intField(o, "max_tokens").?);
    try testing.expectEqualStrings("low", strField(o, "reasoning_effort").?);
    try testing.expect(o.get("store") == null);
    try testing.expect(o.get("include") == null);
    try testing.expectEqualStrings("auto", strField(o, "tool_choice").?);

    const msgs = o.get("messages").?.array.items;
    try testing.expectEqual(@as(usize, 5), msgs.len);
    try testing.expectEqualStrings("system", strField(msgs[0].object, "role").?);
    try testing.expectEqualStrings("developer", strField(msgs[1].object, "role").?);
    try testing.expectEqualStrings("user", strField(msgs[2].object, "role").?);
    // Consecutive function_call items merge into one assistant turn; reasoning dropped.
    try testing.expectEqualStrings("assistant", strField(msgs[3].object, "role").?);
    try testing.expectEqual(@as(usize, 2), msgs[3].object.get("tool_calls").?.array.items.len);
    try testing.expectEqualStrings("tool", strField(msgs[4].object, "role").?);
    try testing.expectEqualStrings("c1", strField(msgs[4].object, "tool_call_id").?);
    try testing.expectEqualStrings("file.c", strField(msgs[4].object, "content").?);

    const tools = o.get("tools").?.array.items;
    try testing.expectEqual(@as(usize, 3), tools.len); // web_search dropped
    try testing.expectEqualStrings("exec_command", strField(tools[0].object.get("function").?.object, "name").?);
    try testing.expectEqualStrings("close_agent", strField(tools[1].object.get("function").?.object, "name").?);
    try testing.expectEqualStrings("apply_patch", strField(tools[2].object.get("function").?.object, "name").?);
    try testing.expectEqual(@as(usize, 1), t.custom_tools.len);
    try testing.expectEqualStrings("apply_patch", t.custom_tools[0]);
}

test "toChatBody accepts a bare string input and rejects junk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const t = try toChatBody(alloc, "{\"model\":\"a/b\",\"input\":\"hello\"}");
    try std.testing.expect(std.mem.indexOf(u8, t.body, "\"content\":\"hello\"") != null);
    try std.testing.expectError(Error.BadResponsesRequest, toChatBody(alloc, "not json"));
    try std.testing.expectError(Error.BadResponsesRequest, toChatBody(alloc, "{\"input\":\"x\"}"));
}

test "replyJson turns a chat reply into a responses document" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var custom = [_][]const u8{"apply_patch"};
    var b = try Bridge.init(alloc, "oc/m", &custom);
    const chat =
        \\{"id":"chatcmpl-1","choices":[{"index":0,"message":{"role":"assistant","content":"hello",
        \\"tool_calls":[{"id":"c1","type":"function","function":{"name":"exec_command","arguments":"{\"cmd\":\"ls\"}"}},
        \\{"id":"c2","type":"function","function":{"name":"apply_patch","arguments":"{\"input\":\"patch me\"}"}}]},
        \\"finish_reason":"tool_calls"}],
        \\"usage":{"prompt_tokens":11,"completion_tokens":5,"total_tokens":16,"prompt_tokens_details":{"cached_tokens":3}}}
    ;
    const out = try b.replyJson(chat);
    const p = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer p.deinit();
    const o = p.value.object;
    try testing.expectEqualStrings("response", strField(o, "object").?);
    try testing.expectEqualStrings("completed", strField(o, "status").?);
    try testing.expectEqualStrings("oc/m", strField(o, "model").?);
    const items = o.get("output").?.array.items;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("message", strField(items[0].object, "type").?);
    try testing.expectEqualStrings(
        "hello",
        strField(items[0].object.get("content").?.array.items[0].object, "text").?,
    );
    try testing.expectEqualStrings("function_call", strField(items[1].object, "type").?);
    try testing.expectEqualStrings("c1", strField(items[1].object, "call_id").?);
    // Custom tools come back unwrapped, as custom_tool_call items.
    try testing.expectEqualStrings("custom_tool_call", strField(items[2].object, "type").?);
    try testing.expectEqualStrings("patch me", strField(items[2].object, "input").?);
    const usage = o.get("usage").?.object;
    try testing.expectEqual(@as(i64, 11), intField(usage, "input_tokens").?);
    try testing.expectEqual(@as(i64, 5), intField(usage, "output_tokens").?);
    try testing.expectEqual(@as(i64, 16), intField(usage, "total_tokens").?);
    try testing.expectEqual(
        @as(i64, 3),
        intField(usage.get("input_tokens_details").?.object, "cached_tokens").?,
    );
}

test "Stream re-encodes chat SSE into responses events" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var backing: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&backing);
    var custom = [_][]const u8{"apply_patch"};
    var b = try Bridge.init(alloc, "oc/m", &custom);
    var s = try b.stream(&w);
    defer s.deinit();
    try s.head();
    try s.feed(
        \\data: {"choices":[{"index":0,"delta":{"role":"assistant","content":"he"}}]}
        \\
        \\data: {"choices":[{"index":0,"delta":{"content":"llo"}}]}
        \\
        \\data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_9","function":{"name":"exec_command","arguments":"{\"cmd\""}}]}}]}
        \\
        \\data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\"ls\"}"}}]}}]}
        \\
        \\data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":7,"completion_tokens":4,"prompt_tokens_details":{"cached_tokens":2}}}
        \\
        \\data: [DONE]
        \\
        \\
    );
    try s.finish();

    const written = w.buffered();
    const head_end = (std.mem.indexOf(u8, written, "\r\n\r\n") orelse 0) + 4;
    var fr = Frame{ .alloc = alloc, .raw = written[head_end..] };
    var kinds: std.ArrayList([]const u8) = .empty;
    defer kinds.deinit(alloc);
    var text: []const u8 = "";
    var call_args: []const u8 = "";
    var parsed_arena = std.heap.ArenaAllocator.init(alloc);
    defer parsed_arena.deinit();
    while (fr.next()) |payload| {
        const p = try std.json.parseFromSlice(std.json.Value, parsed_arena.allocator(), payload, .{});
        const kind = strField(p.value.object, "type").?;
        try kinds.append(alloc, kind);
        if (std.mem.eql(u8, kind, "response.output_text.done")) {
            text = strField(p.value.object, "text").?;
        }
        if (std.mem.eql(u8, kind, "response.output_item.done")) {
            const item = p.value.object.get("item").?;
            if (item.object.get("arguments")) |a| call_args = a.string;
        }
    }
    // Split argument fragments must be reassembled into one complete call.
    try testing.expectEqualStrings("{\"cmd\":\"ls\"}", call_args);
    try testing.expectEqualStrings("hello", text);
    // The chunked body must be terminated or the client sees a truncated reply.
    try testing.expect(w.buffered().len >= 5);
    try testing.expectEqualStrings("0\r\n\r\n", w.buffered()[w.buffered().len - 5..]);
    const expect_kinds = [_][]const u8{
        "response.created",
        "response.in_progress",
        "response.output_item.added",
        "response.content_part.added",
        "response.output_text.delta",
        "response.output_text.delta",
        "response.output_text.done",
        "response.content_part.done",
        "response.output_item.done",
        "response.output_item.added",
        "response.output_item.done",
        "response.completed",
    };
    try testing.expectEqual(expect_kinds.len, kinds.items.len);
    for (expect_kinds, 0..) |k, i| try testing.expectEqualStrings(k, kinds.items[i]);
}

test "Stream survives byte-at-a-time delivery and never loses the tail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var backing: [65536]u8 = undefined;
    var w = std.Io.Writer.fixed(&backing);
    var none: [0][]const u8 = .{};
    var b = try Bridge.init(alloc, "m", &none);
    var s = try b.stream(&w);
    defer s.deinit();
    try s.head();
    const traffic = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"abc\"}}]}\n\ndata: [DONE]\n\n";
    for (traffic) |c| try s.feed(&[_]u8{c});
    try s.flushPending();
    try s.finish();
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"delta\":\"abc\"") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"type\":\"response.completed\"") != null);
}

test "writeChunked frames exactly and skips empty writes" {
    var backing: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&backing);
    try writeChunked(&w, "data: x\n\n");
    try testing.expectEqualStrings("9\r\ndata: x\n\n\r\n", w.buffered());
    const before = w.buffered().len;
    try writeChunked(&w, "");
    try testing.expectEqual(before, w.buffered().len);
}

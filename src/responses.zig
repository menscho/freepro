// src/responses.zig - OpenAI Responses wire-format translation.
//
// Some gateways (OpenCode Zen) only implement the OpenAI *Responses* API
// (/v1/responses) while every OpenAI-compatible client speaks Chat
// Completions. This module converts both directions so the proxy can serve
// chat clients transparently:
//
//   chat completions request  -> responses request      (buildResponsesBody)
//   responses JSON reply      -> chat completions reply (chatFromResponses)
//   responses SSE stream      -> chat SSE chunks
//
// Usage tokens are extracted for metrics (responsesUsage).
// Offline build: std-only. Builders return caller-owned memory.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TranslatedUsage = struct {
    input: u64 = 0,
    output: u64 = 0,
    cached: u64 = 0,
};

/// Build a /responses request body from a chat completions body.
/// Keeps model, stream, max_tokens (as max_output_tokens), temperature,
/// top_p and translates messages[] (text parts; images are skipped).
pub fn buildResponsesBody(alloc: Allocator, chat_body: []const u8, upstream_model: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "{\"model\":");
    try appendQuoted(alloc, &out, upstream_model);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, chat_body, .{}) catch {
        return error.BadChatBody;
    };
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadChatBody,
    };

    // `stream` is deliberately NOT propagated: /responses is always called
    // in non-streaming mode and the proxy synthesizes chat SSE from the
    // complete reply (see forwardAttempt's responses_mode relay).

    inline for (.{ "temperature", "top_p" }) |k| {
        if (obj.get(k)) |v| {
            if (v == .integer or v == .float) {
                try out.appendSlice(alloc, ",\"" ++ k ++ "\":");
                try appendJson(alloc, &out, v);
            }
        }
    }

    if (obj.get("max_completion_tokens") orelse obj.get("max_tokens")) |v| {
        if (v == .integer) {
            try out.appendSlice(alloc, ",\"max_output_tokens\":");
            try appendJson(alloc, &out, v);
        }
    }

    // Reasoning effort: the chat wire carries a flat "reasoning_effort";
    // the Responses wire wraps it as reasoning.effort. "none" means the
    // caller switched reasoning off, which the Responses API expresses by
    // omitting the field entirely.
    if (obj.get("reasoning_effort")) |v| {
        if (v == .string and !std.mem.eql(u8, v.string, "none")) {
            try out.appendSlice(alloc, ",\"reasoning\":{\"effort\":");
            try appendQuoted(alloc, &out, v.string);
            try out.appendSlice(alloc, "}");
        }
    }

    if (obj.get("tools")) |tv| {
        if (tv == .array and tv.array.items.len > 0) {
            try out.appendSlice(alloc, ",\"tools\":");
            try out.appendSlice(alloc, "[");
            for (tv.array.items, 0..) |tool, i| {
                if (i != 0) try out.appendSlice(alloc, ",");
                if (tool == .object and tool.object.get("function") != null) {
                    const f = tool.object.get("function").?;
                    if (f != .object) return error.BadChatBody;
                    try out.appendSlice(alloc, "{\"type\":\"function\"");
                    inline for (.{ "name", "description", "parameters", "strict" }) |k| {
                        if (f.object.get(k)) |v| {
                            try out.appendSlice(alloc, ",\"" ++ k ++ "\":");
                            try appendJson(alloc, &out, v);
                        }
                    }
                    try out.appendSlice(alloc, "}");
                } else try appendJson(alloc, &out, tool);
            }
            try out.appendSlice(alloc, "]");
        }
    }

    if (obj.get("tool_choice")) |tc| {
        try out.appendSlice(alloc, ",\"tool_choice\":");
        if (tc == .object and tc.object.get("function") != null) {
            const f = tc.object.get("function").?;
            if (f != .object) return error.BadChatBody;
            try out.appendSlice(alloc, "{\"type\":\"function\",\"name\":");
            try appendJson(alloc, &out, f.object.get("name") orelse return error.BadChatBody);
            try out.appendSlice(alloc, "}");
        } else try appendJson(alloc, &out, tc);
    }
    inline for (.{ "parallel_tool_calls", "prompt_cache_key" }) |k| {
        if (obj.get(k)) |v| {
            try out.appendSlice(alloc, ",\"" ++ k ++ "\":");
            try appendJson(alloc, &out, v);
        }
    }

    try out.appendSlice(alloc, ",\"input\":");
    var input: std.ArrayList(u8) = .empty;
    errdefer input.deinit(alloc);
    try input.appendSlice(alloc, "[");
    var first = true;
    if (obj.get("messages")) |mv| {
        if (mv == .array) {
            for (mv.array.items) |m| {
                if (m != .object) continue;
                const role = switch (m.object.get("role") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                if (std.mem.eql(u8, role, "tool")) {
                    if (!first) try input.appendSlice(alloc, ",");
                    first = false;
                    try input.appendSlice(alloc, "{\"type\":\"function_call_output\",\"call_id\":");
                    try appendJson(alloc, &input, m.object.get("tool_call_id") orelse return error.BadChatBody);
                    try input.appendSlice(alloc, ",\"output\":");
                    try appendJson(alloc, &input, m.object.get("content") orelse .{ .string = "" });
                    try input.appendSlice(alloc, "}");
                    continue;
                }
                if (m.object.get("tool_calls")) |calls| {
                    if (calls == .array) for (calls.array.items) |call| {
                        if (call != .object) return error.BadChatBody;
                        const f = call.object.get("function") orelse return error.BadChatBody;
                        if (f != .object) return error.BadChatBody;
                        if (!first) try input.appendSlice(alloc, ",");
                        first = false;
                        try input.appendSlice(alloc, "{\"type\":\"function_call\",\"call_id\":");
                        try appendJson(alloc, &input, call.object.get("id") orelse return error.BadChatBody);
                        inline for (.{ "name", "arguments" }) |k| {
                            try input.appendSlice(alloc, ",\"" ++ k ++ "\":");
                            try appendJson(alloc, &input, f.object.get(k) orelse return error.BadChatBody);
                        }
                        try input.appendSlice(alloc, "}");
                    };
                }
                if (m.object.get("content")) |cv| {
                    if (cv == .null) continue;
                    if (!first) try input.appendSlice(alloc, ",");
                    first = false;
                    try input.appendSlice(alloc, "{\"role\":");
                    try appendQuoted(alloc, &input, role);
                    try input.appendSlice(alloc, ",\"content\":");
                    try appendTextContent(alloc, &input, cv, role);
                    try input.appendSlice(alloc, "}");
                }
            }
        }
    }
    try input.appendSlice(alloc, "]");
    try out.appendSlice(alloc, input.items);
    input.deinit(alloc);
    try out.appendSlice(alloc, "}");
    return try out.toOwnedSlice(alloc);
}

/// Flatten chat message content into Responses content items. String content
/// becomes one input_text item; array content keeps text parts only.
fn appendTextContent(alloc: Allocator, out: *std.ArrayList(u8), cv: std.json.Value, role: []const u8) !void {
    const text_type = if (std.mem.eql(u8, role, "assistant")) "output_text" else "input_text";
    switch (cv) {
        .string => |s| {
            try out.appendSlice(alloc, "[{\"type\":");
            try appendQuoted(alloc, out, text_type);
            try out.appendSlice(alloc, ",\"text\":");
            try appendQuoted(alloc, out, s);
            try out.appendSlice(alloc, "}]");
        },
        .array => |arr| {
            try out.appendSlice(alloc, "[");
            var first = true;
            for (arr.items) |part| {
                if (part != .object) continue;
                const t = part.object.get("type") orelse continue;
                if (t != .string) continue;
                if (!std.mem.eql(u8, t.string, "text")) continue;
                const text = part.object.get("text") orelse continue;
                if (text != .string) continue;
                if (!first) try out.appendSlice(alloc, ",");
                first = false;
                try out.appendSlice(alloc, "{\"type\":");
                try appendQuoted(alloc, out, text_type);
                try out.appendSlice(alloc, ",\"text\":");
                try appendQuoted(alloc, out, text.string);
                try out.appendSlice(alloc, "}");
            }
            if (first) {
                try out.appendSlice(alloc, "{\"type\":");
                try appendQuoted(alloc, out, text_type);
                try out.appendSlice(alloc, ",\"text\":\"\"}");
            }
            try out.appendSlice(alloc, "]");
        },
        else => try appendTextContent(alloc, out, .{ .string = "" }, role),
    }
}

/// Convert a complete Responses JSON reply into a chat completions reply.
/// Returns caller-owned chat JSON. `model` is the client-facing model id.
pub fn chatFromResponses(gpa: Allocator, responses_body: []const u8, model: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, responses_body, .{}) catch
        return error.BadResponsesBody;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.BadResponsesBody,
    };

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    if (obj.get("output")) |ov| {
        if (ov == .array) {
            for (ov.array.items) |item| {
                if (item != .object) continue;
                if (item.object.get("type")) |t| {
                    if (t != .string or !std.mem.eql(u8, t.string, "message")) continue;
                }
                const content = item.object.get("content") orelse continue;
                if (content != .array) continue;
                for (content.array.items) |part| {
                    if (part != .object) continue;
                    const pt = part.object.get("type") orelse continue;
                    if (pt != .string) continue;
                    if (!std.mem.eql(u8, pt.string, "output_text")) continue;
                    const tv = part.object.get("text") orelse continue;
                    if (tv != .string) continue;
                    try text.appendSlice(alloc, tv.string);
                }
            }
        }
    }

    var calls: std.ArrayList(u8) = .empty;
    try calls.appendSlice(alloc, "[");
    var call_count: usize = 0;
    if (obj.get("output")) |ov| {
        if (ov == .array) for (ov.array.items) |item| {
            if (item != .object) continue;
            const t = item.object.get("type") orelse continue;
            if (t != .string or !std.mem.eql(u8, t.string, "function_call")) continue;
            if (call_count != 0) try calls.appendSlice(alloc, ",");
            call_count += 1;
            try calls.appendSlice(alloc, "{\"id\":");
            try appendJson(alloc, &calls, item.object.get("call_id") orelse return error.BadResponsesBody);
            try calls.appendSlice(alloc, ",\"type\":\"function\",\"function\":{\"name\":");
            try appendJson(alloc, &calls, item.object.get("name") orelse return error.BadResponsesBody);
            try calls.appendSlice(alloc, ",\"arguments\":");
            try appendJson(alloc, &calls, item.object.get("arguments") orelse .{ .string = "{}" });
            try calls.appendSlice(alloc, "}}");
        };
    }
    try calls.appendSlice(alloc, "]");
    var usage = TranslatedUsage{};
    if (obj.get("usage")) |uv| {
        if (uv == .object) usage = responsesUsage(uv);
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "{\"id\":");
    if (obj.get("id")) |idv| {
        if (idv == .string) try appendQuoted(alloc, &out, idv.string) else try out.appendSlice(alloc, "\"chatcmpl-resp\"");
    } else try out.appendSlice(alloc, "\"chatcmpl-resp\"");
    try out.appendSlice(alloc, ",\"object\":\"chat.completion\",\"model\":");
    try appendQuoted(alloc, &out, model);
    try out.appendSlice(alloc, ",\"created\":");
    if (obj.get("created_at")) |cv| {
        try appendJson(alloc, &out, cv);
    } else try out.appendSlice(alloc, "0");
    try out.appendSlice(alloc, ",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":");
    try appendQuoted(alloc, &out, text.items);
    if (call_count > 0) {
        try out.appendSlice(alloc, ",\"tool_calls\":");
        try out.appendSlice(alloc, calls.items);
    }
    try out.appendSlice(alloc, "},\"finish_reason\":");
    try appendQuoted(alloc, &out, if (call_count > 0) "tool_calls" else "stop");
    try out.appendSlice(alloc, "}],\"usage\":{\"prompt_tokens\":");
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}", .{usage.input}));
    try out.appendSlice(alloc, ",\"completion_tokens\":");
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}", .{usage.output}));
    try out.appendSlice(alloc, ",\"prompt_tokens_details\":{\"cached_tokens\":");
    try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "{d}", .{usage.cached}));
    try out.appendSlice(alloc, "}}}"); // cached_tokens obj, usage obj, root
    // The whole reply lives in the arena; copy the final bytes out so the
    // caller owns them independently of the arena teardown.
    const result = try gpa.dupe(u8, out.items);
    return result;
}

/// Extract usage integers from a Responses usage object.
pub fn responsesUsage(uv: std.json.Value) TranslatedUsage {
    var usage = TranslatedUsage{};
    if (uv != .object) return usage;
    if (uv.object.get("input_tokens")) |v| {
        if (v == .integer and v.integer > 0) usage.input = @intCast(v.integer);
    }
    if (uv.object.get("output_tokens")) |v| {
        if (v == .integer and v.integer > 0) usage.output = @intCast(v.integer);
    }
    if (uv.object.get("input_tokens_details")) |dv| {
        if (dv == .object) {
            if (dv.object.get("cached_tokens")) |v| {
                if (v == .integer and v.integer > 0) usage.cached = @intCast(v.integer);
            }
        }
    }
    return usage;
}

/// True when an SSE chunk carries the Responses `response.completed` event.
pub fn streamDoneDetected(chunk: []const u8) bool {
    return std.mem.indexOf(u8, chunk, "response.completed") != null;
}

/// Extract accumulated text out of a `response.completed` SSE payload.
pub fn completedText(alloc: Allocator, chunk: []const u8) !?[]u8 {
    const marker = std.mem.indexOf(u8, chunk, "response.completed") orelse return null;
    const brace = std.mem.indexOfScalarPos(u8, chunk, marker, '{') orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, chunk[brace..], .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const response = obj.get("response") orelse return null;
    if (response != .object) return null;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    if (response.object.get("output")) |ov| {
        if (ov == .array) {
            for (ov.array.items) |item| {
                if (item != .object) continue;
                const content = item.object.get("content") orelse continue;
                if (content != .array) continue;
                for (content.array.items) |part| {
                    if (part != .object) continue;
                    const pt = part.object.get("type") orelse continue;
                    if (pt != .string or !std.mem.eql(u8, pt.string, "output_text")) continue;
                    const tv = part.object.get("text") orelse continue;
                    if (tv != .string) continue;
                    try text.appendSlice(alloc, tv.string);
                }
            }
        }
    }
    if (text.items.len == 0) return null;
    return try text.toOwnedSlice(alloc);
}

/// Extract usage out of a `response.completed` SSE payload. Uses an internal
/// arena because the caller receives plain values.
pub fn completedUsage(alloc: Allocator, chunk: []const u8) TranslatedUsage {
    const marker = std.mem.indexOf(u8, chunk, "response.completed") orelse return .{};
    const brace = std.mem.indexOfScalarPos(u8, chunk, marker, '{') orelse return .{};
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, chunk[brace..], .{}) catch return .{};
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return .{},
    };
    const response = obj.get("response") orelse return .{};
    if (response != .object) return .{};
    const uv = response.object.get("usage") orelse return .{};
    return responsesUsage(uv);
}

// -- json helpers ---------------------------------------------------------

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

// -- tests ----------------------------------------------------------------

test "buildResponsesBody translates messages and knobs" {
    const alloc = std.testing.allocator;
    const chat =
        "{" ++ "\"model\":\"oc/x\",\"messages\":[" ++
        "{\"role\":\"system\",\"content\":\"be nice\"}," ++
        "{\"role\":\"user\",\"content\":\"hello\"}]," ++
        "\"max_tokens\":64,\"stream\":false,\"temperature\":0.5,\"reasoning_effort\":\"high\"}";
    const out = try buildResponsesBody(alloc, chat, "x");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"model\":\"x\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"max_output_tokens\":64") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hello\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"stream\":true") == null);
    // Guard the wire: the translated body must be valid JSON, and the input
    // must be a well-formed object array (message objects closed).
    const reparsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    reparsed.deinit();
    try std.testing.expectEqualStrings(
        "{\"model\":\"x\",\"temperature\":0.5,\"max_output_tokens\":64,\"reasoning\":{\"effort\":\"high\"},\"input\":[" ++
            "{\"role\":\"system\",\"content\":[{\"type\":\"input_text\",\"text\":\"be nice\"}]}," ++
            "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hello\"}]}]}",
        out,
    );
}

test "buildResponsesBody forwards reasoning_effort, drops none" {
    const alloc = std.testing.allocator;
    const with_none =
        "{\"model\":\"oc/x\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"reasoning_effort\":\"none\"}";
    const out_none = try buildResponsesBody(alloc, with_none, "x");
    defer alloc.free(out_none);
    try std.testing.expect(std.mem.indexOf(u8, out_none, "reasoning") == null);

    const with_low =
        "{\"model\":\"oc/x\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"reasoning_effort\":\"low\"}";
    const out_low = try buildResponsesBody(alloc, with_low, "x");
    defer alloc.free(out_low);
    try std.testing.expect(std.mem.indexOf(u8, out_low, "\"reasoning\":{\"effort\":\"low\"}") != null);
}

test "chatFromResponses maps output text and usage" {
    const alloc = std.testing.allocator;
    const resp =
        "{" ++ "\"id\":\"resp_1\",\"created_at\":123," ++
        "\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello!\"}]}]," ++
        "\"usage\":{\"input_tokens\":9,\"output_tokens\":5," ++
        "\"input_tokens_details\":{\"cached_tokens\":2}}}";
    const out = try chatFromResponses(alloc, resp, "oc/x");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"content\":\"Hello!\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prompt_tokens\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"completion_tokens\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"cached_tokens\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"model\":\"oc/x\"") != null);
}

test "responses SSE detection + text + usage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const chunk = "event: response.completed\ndata: {" ++
        "\"type\":\"response.completed\"," ++
        "\"response\":{\"output\":[{\"type\":\"message\",\"content\":[" ++
        "{\"type\":\"output_text\",\"text\":\"OK!\"}]}]," ++
        "\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}}";
    try std.testing.expect(streamDoneDetected(chunk));
    const text = (try completedText(alloc, chunk)).?;
    try std.testing.expectEqualStrings("OK!", text);
    const u = completedUsage(alloc, chunk);
    try std.testing.expectEqual(@as(u64, 3), u.input);
    try std.testing.expectEqual(@as(u64, 2), u.output);
}

test "Responses tools and tool conversation use native wire shapes" {
    const a = std.testing.allocator;
    const body =
        \\{"model":"x","tools":[{"type":"function","function":{"name":"lookup","description":"Find","parameters":{"type":"object"},"strict":false}}],"tool_choice":{"type":"function","function":{"name":"lookup"}},"messages":[{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{}"}}]},{"role":"tool","tool_call_id":"call_1","content":"done"}],"max_completion_tokens":123}
    ;
    const out = try buildResponsesBody(a, body, "x");
    defer a.free(out);
    const doc = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer doc.deinit();
    const o = doc.value.object;
    const tool = o.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("lookup", tool.get("name").?.string);
    try std.testing.expect(tool.get("function") == null);
    try std.testing.expectEqualStrings("lookup", o.get("tool_choice").?.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 123), o.get("max_output_tokens").?.integer);
    const input = o.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), input.len);
    try std.testing.expectEqualStrings("function_call", input[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("function_call_output", input[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", input[1].object.get("call_id").?.string);
}

test "Responses function calls survive return translation" {
    const a = std.testing.allocator;
    const out = try chatFromResponses(a,
        \\{"id":"r1","output":[{"type":"function_call","call_id":"c1","name":"lookup","arguments":"{\"q\":1}"}]}
    , "oc/x");
    defer a.free(out);
    const doc = try std.json.parseFromSlice(std.json.Value, a, out, .{});
    defer doc.deinit();
    const choice = doc.value.object.get("choices").?.array.items[0].object;
    try std.testing.expectEqualStrings("tool_calls", choice.get("finish_reason").?.string);
    const call = choice.get("message").?.object.get("tool_calls").?.array.items[0].object;
    try std.testing.expectEqualStrings("c1", call.get("id").?.string);
    try std.testing.expectEqualStrings("{\"q\":1}", call.get("function").?.object.get("arguments").?.string);
}

test "assistant history uses output_text for strings and content arrays" {
    const a = std.testing.allocator;
    const body = try buildResponsesBody(a,
        \\{"model":"m","messages":[{"role":"user","content":"question"},{"role":"assistant","content":"answer"},{"role":"assistant","content":[{"type":"text","text":"checking"}]}]}
    , "m");
    defer a.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("input").?.array.items;
    try std.testing.expectEqualStrings("input_text", items[0].object.get("content").?.array.items[0].object.get("type").?.string);
    for (items[1..]) |item| {
        try std.testing.expectEqualStrings("output_text", item.object.get("content").?.array.items[0].object.get("type").?.string);
    }
}

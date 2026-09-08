// src/upstream.zig — upstream HTTP forwarder for the freepro proxy engine.
//
// std-only module: forwarding is built on std.http.Client, JSON handling on
// std.json, timing on std.time. No httpz / DVUI / GUI dependency is required
// by this file. If the proxy later needs a faster socket loop (httpz / zap),
// that dependency belongs in build.zig and src/proxy.zig, not here.
//
// What this module owns:
//   * forwardChatCompletions / forwardCompletions — POST an OpenAI-compatible
//     chat (or plain) completions payload upstream, injecting the provider's
//     static headers plus `Authorization: Bearer <key>` and
//     `Content-Type: application/json`. SSE streams relay verbatim chunk by
//     chunk; buffered responses relay as one body.
//   * fetchModels — GET <base>/models and prefix every id for aggregation.
//   * Stopwatch / nowMs / elapsedMsSince — response-time measurement.
//
// Contracts with sibling agents:
//   * Provider shape comes from @import("models.zig"): display_name, base_url,
//     prefix, description, keys, headers. Only display_name / base_url /
//     prefix / headers are read here; key-pool state lives in rotator.zig.
//   * timeout_ms: u32 matches ProxyConfig.timeout_ms in models.zig.
//   * Only 2xx upstream responses are relayed to `writer`. Anything else is
//     returned as a status code with NO bytes written, so proxy.zig can fail
//     over to the next healthy key and retry without corrupting the client
//     stream. The last error body (bounded) is captured on ForwardResult for
//     the "all keys exhausted" path.
//   * Transport failures never surface as Zig errors: they map to synthetic
//     statuses (0 = timeout, 502 = other transport failure) so the rotator
//     can feed them straight into reportResult(). Only error.OutOfMemory and
//     downstream-writer errors propagate as Zig errors.
//   * Thread safety: every call builds its own std.http.Client, so concurrent
//     calls from proxy worker threads share no mutable state. The WithIo
//     variants accept the app's shared std.Io; the plain wrappers use the
//     process-wide single-threaded Io.
//
// Timeout semantics (read carefully): std.http.Client exposes no per-request
// deadline on its high-level request path, so timeout_ms is a soft deadline:
// it is stamped on every result as elapsed_ms for logging, and a transport
// failure whose elapsed time already exceeds timeout_ms is reported as status
// 0 (timeout). A hung connection past the deadline can still block the caller;
// proxy.zig should therefore also treat elapsed_ms > timeout_ms on 2xx as a
// slow-response signal in its logs / metrics.
//
// SSE relay: bytes pass through untouched (framing-agnostic, works for both
// chunked and content-length bodies). saw_done is a convenience flag set when
// the "[DONE]" terminator is observed, including markers split across chunk
// boundaries; end-of-stream is authoritative, not the flag.
//
// Toolchain note: this file targets the installed Zig 0.16 std.http.Client
// flow (client.request / sendBodyComplete / receiveHead / response.reader).
// Zig 0.13 used the older open / send / finish / wait spelling — the pure
// helpers (URL join, body rewrite, DoneScanner, classification, model parse)
// are version-agnostic, but the transport core needs that spelling adjusted
// when porting back. No ArrayList is used anywhere (manual slice growth
// only), precisely to avoid the 0.13-managed / 0.15+-unmanaged split.

const std = @import("std");
const builtin = @import("builtin");
const models = @import("models.zig");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Synthetic statuses and size caps
// ---------------------------------------------------------------------------

/// Synthetic status for timed-out / deadline-exceeded upstream attempts.
/// Never a real HTTP code; tells the rotator to cool the key down.
pub const status_timeout: u16 = 0;

/// Synthetic status for non-timeout transport failures (DNS, refused,
/// reset, TLS, malformed responses). Treated as a generic upstream error.
pub const status_transport_error: u16 = 502;

/// Cap for a buffered (non-streaming) completion body. Larger bodies fail
/// the relay as truncated rather than growing memory without bound.
pub const max_buffered_body_bytes: usize = 16 * 1024 * 1024;

/// Cap for a captured upstream error body (ForwardResult.error_body).
pub const max_error_body_bytes: usize = 64 * 1024;

/// Cap for a /models response body.
pub const max_models_body_bytes: usize = 8 * 1024 * 1024;

/// SSE terminator scanned for while relaying (flag only; EOF is authoritative).
const done_marker: []const u8 = "[DONE]";

// ---------------------------------------------------------------------------
// Endpoint selection
// ---------------------------------------------------------------------------

/// Which OpenAI-compatible completions path to POST to. forwardChatCompletions
/// always uses .chat; the general forwardCompletions takes either.
pub const Endpoint = enum {
    chat,
    plain,

    pub fn path(self: Endpoint) []const u8 {
        return switch (self) {
            .chat => "/chat/completions",
            .plain => "/completions",
        };
    }
};

// ---------------------------------------------------------------------------
// Response-time measurement
// ---------------------------------------------------------------------------

/// Wall-clock milliseconds since the Unix epoch. Exposed so proxy.zig /
/// metrics.zig can stamp request logs with the same clock family this module
/// reports in. Uses a direct OS clock read so it is safe from any thread,
/// including proxy worker threads that must not touch the global Io.
pub fn nowMs() i64 {
    if (@hasDecl(std.time, "milliTimestamp")) return std.time.milliTimestamp();
    if (builtin.os.tag == .windows) {
        const ticks_100ns: i64 = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        return @divFloor(ticks_100ns, 10_000) - 11_644_473_600_000;
    }
    var ts: std.posix.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1_000 + @divFloor(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Milliseconds elapsed since `start_ms` (see nowMs). Wall clock: fine for
/// log stamps, prefer Stopwatch for latency measurement.
pub fn elapsedMsSince(start_ms: i64) i64 {
    return nowMs() - start_ms;
}

/// Monotonic start/elapsed helper for upstream latency measurement. Immune
/// to wall-clock jumps (NTP / manual changes), unlike nowMs.
pub const Stopwatch = struct {
    io: std.Io,
    start_ts: std.Io.Clock.Timestamp,

    pub fn start(io: std.Io) Stopwatch {
        return .{ .io = io, .start_ts = .now(io, .awake) };
    }

    pub fn elapsedMs(self: Stopwatch) i64 {
        const now_ts = std.Io.Clock.Timestamp.now(self.io, .awake);
        const delta_ns = now_ts.raw.nanoseconds - self.start_ts.raw.nanoseconds;
        return @intCast(@divTrunc(delta_ns, std.time.ns_per_ms));
    }

    pub fn restart(self: *Stopwatch) void {
        self.start_ts = std.Io.Clock.Timestamp.now(self.io, .awake);
    }
};

// ---------------------------------------------------------------------------
// Forward result
// ---------------------------------------------------------------------------

/// Outcome of one upstream forward attempt.
///
/// Ownership: error_body (when non-null) is heap-owned; call deinit() exactly
/// once when done. All other fields are plain values. deinit() is safe to
/// call on any result, including ones with a null error_body.
pub const ForwardResult = struct {
    /// Upstream HTTP status, or a synthetic status_timeout (0) /
    /// status_transport_error (502) when no usable response arrived.
    status: u16,
    /// Wall-clock milliseconds for the whole attempt (soft-deadline clock).
    elapsed_ms: i64,
    /// Bytes relayed downstream (0 unless status was 2xx).
    bytes_relayed: usize = 0,
    /// True when the "[DONE]" SSE terminator was observed while streaming.
    saw_done: bool = false,
    /// True when the body could not be relayed/captured in full (mid-stream
    /// read failure, or a body larger than the configured cap).
    truncated: bool = false,
    /// Bounded upstream error body, captured only for non-2xx responses.
    /// Null on success, on streams that failed mid-flight, and when the
    /// upstream sent no body. Owned; see deinit().
    error_body: ?[]u8 = null,

    pub fn deinit(self: *ForwardResult, allocator: Allocator) void {
        if (self.error_body) |b| {
            allocator.free(b);
            self.error_body = null;
        }
    }
};

// ---------------------------------------------------------------------------
// Public forward entry points
// ---------------------------------------------------------------------------

/// POST body_json to <provider>/chat/completions as an OpenAI-style chat.
///
/// Parameters:
///   * provider — routing + header source (base_url, headers).
///   * api_key — the single key selected by the rotator for this attempt.
///   * stripped_model — upstream model name (prefix already removed); when
///     empty, the body's "model" field is left untouched.
///   * body_json — raw client payload; "model" and "stream" are normalized
///     to stripped_model / is_stream before sending (see rewriteOutboundBody).
///   * is_stream — true selects verbatim SSE relay, false buffered relay.
///   * writer — downstream sink with writeAll(); receives bytes ONLY on 2xx.
///   * timeout_ms — soft deadline, 0 disables deadline classification.
///
/// Uses the process-wide single-threaded Io. Prefer
/// forwardChatCompletionsWithIo with the app's shared Io on hot paths.
pub fn forwardChatCompletions(
    allocator: Allocator,
    provider: *const models.Provider,
    api_key: []const u8,
    stripped_model: []const u8,
    body_json: []const u8,
    is_stream: bool,
    writer: anytype,
    timeout_ms: u32,
) !ForwardResult {
    return forwardCompletions(
        allocator,
        provider,
        api_key,
        stripped_model,
        body_json,
        .chat,
        is_stream,
        writer,
        timeout_ms,
    );
}

/// forwardChatCompletions with an explicit Io (app-owned Threaded pool).
pub fn forwardChatCompletionsWithIo(
    allocator: Allocator,
    io: std.Io,
    provider: *const models.Provider,
    api_key: []const u8,
    stripped_model: []const u8,
    body_json: []const u8,
    is_stream: bool,
    writer: anytype,
    timeout_ms: u32,
) !ForwardResult {
    return forwardCompletionsWithIo(
        allocator,
        io,
        provider,
        api_key,
        stripped_model,
        body_json,
        .chat,
        is_stream,
        writer,
        timeout_ms,
    );
}

/// General completions forwarder (chat or plain endpoint). Same contract as
/// forwardChatCompletions; uses the process-wide single-threaded Io.
pub fn forwardCompletions(
    allocator: Allocator,
    provider: *const models.Provider,
    api_key: []const u8,
    stripped_model: []const u8,
    body_json: []const u8,
    endpoint: Endpoint,
    is_stream: bool,
    writer: anytype,
    timeout_ms: u32,
) !ForwardResult {
    const io = std.Io.Threaded.global_single_threaded.io();
    return forwardCompletionsWithIo(
        allocator,
        io,
        provider,
        api_key,
        stripped_model,
        body_json,
        endpoint,
        is_stream,
        writer,
        timeout_ms,
    );
}

/// General completions forwarder with an explicit Io.
pub fn forwardCompletionsWithIo(
    allocator: Allocator,
    io: std.Io,
    provider: *const models.Provider,
    api_key: []const u8,
    stripped_model: []const u8,
    body_json: []const u8,
    endpoint: Endpoint,
    is_stream: bool,
    writer: anytype,
    timeout_ms: u32,
) !ForwardResult {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    return forwardWithClient(
        &client,
        provider,
        api_key,
        stripped_model,
        body_json,
        endpoint,
        is_stream,
        writer,
        timeout_ms,
    );
}

// ---------------------------------------------------------------------------
// Forward core (shared by every entry point)
// ---------------------------------------------------------------------------

fn forwardWithClient(
    client: *std.http.Client,
    provider: *const models.Provider,
    api_key: []const u8,
    stripped_model: []const u8,
    body_json: []const u8,
    endpoint: Endpoint,
    is_stream: bool,
    writer: anytype,
    timeout_ms: u32,
) !ForwardResult {
    const allocator = client.allocator;
    const watch = Stopwatch.start(client.io);
    var result = ForwardResult{ .status = status_transport_error, .elapsed_ms = 0 };
    errdefer result.deinit(allocator);

    const fail = struct {
        fn status(elapsed_ms: i64, budget_ms: u32, err: anyerror) u16 {
            if (budget_ms != 0 and elapsed_ms >= @as(i64, budget_ms))
                return status_timeout;
            return classifyTransportError(err);
        }
    }.status;

    const url = try buildUrl(allocator, provider.base_url, endpoint.path());
    defer allocator.free(url);

    const uri = std.Uri.parse(url) catch {
        // Invalid base_url is a config error; surface it like a transport
        // failure so the caller never writes a partial downstream response.
        result.status = status_transport_error;
        result.elapsed_ms = watch.elapsedMs();
        return result;
    };

    const outbound = try rewriteOutboundBody(allocator, body_json, stripped_model, is_stream);
    defer allocator.free(outbound);

    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(bearer);

    const extra = try allocator.alloc(std.http.Header, provider.headers.len);
    defer allocator.free(extra);
    var extra_count: usize = 0;
    for (provider.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.key, "user-agent") or
            std.ascii.eqlIgnoreCase(h.key, "authorization") or
            std.ascii.eqlIgnoreCase(h.key, "content-type") or
            std.ascii.eqlIgnoreCase(h.key, "accept-encoding") or
            std.ascii.eqlIgnoreCase(h.key, "host") or
            std.ascii.eqlIgnoreCase(h.key, "content-length") or
            std.ascii.eqlIgnoreCase(h.key, "connection")) continue;
        extra[extra_count] = .{ .name = h.key, .value = h.value };
        extra_count += 1;
    }

    var req = client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = provider.findHeader("authorization") orelse bearer },
            .user_agent = if (provider.findHeader("user-agent")) |ua| .{ .override = ua } else .default,
            // Force an identity body: the relay passes bytes through
            // verbatim and must never forward gzip/deflate upstream bytes
            // to a client expecting plain SSE/JSON.
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = extra[0..extra_count],
    }) catch |err| {
        if (err == error.OutOfMemory) return err;
        result.status = fail(watch.elapsedMs(), timeout_ms, err);
        result.elapsed_ms = watch.elapsedMs();
        return result;
    };
    defer req.deinit();

    req.sendBodyComplete(outbound) catch |err| {
        if (err == error.OutOfMemory) return err;
        result.status = fail(watch.elapsedMs(), timeout_ms, err);
        result.elapsed_ms = watch.elapsedMs();
        return result;
    };

    var redirect_buf: [512]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        if (err == error.OutOfMemory) return err;
        result.status = fail(watch.elapsedMs(), timeout_ms, err);
        result.elapsed_ms = watch.elapsedMs();
        return result;
    };

    const status: u16 = @as(u16, @intFromEnum(response.head.status));
    result.status = status;

    if (response.head.content_encoding != .identity) {
        // Upstream ignored `accept-encoding: identity`; relaying encoded
        // bytes would corrupt the client stream, so fail the attempt and let
        // the rotator pick another key / surface 502 when exhausted.
        drainResponse(&response);
        result.status = status_transport_error;
        result.elapsed_ms = watch.elapsedMs();
        return result;
    }

    var transfer: [4096]u8 = undefined;
    const reader = response.reader(&transfer);

    if (status < 200 or status >= 300) {
        result.error_body = blk: {
            const captured = readBuffered(
                allocator,
                reader,
                response.head.content_length,
                max_error_body_bytes,
            ) catch |err| {
                if (err == error.OutOfMemory) return err;
                result.truncated = true;
                break :blk null;
            };
            break :blk captured;
        };
        result.elapsed_ms = watch.elapsedMs();
        return result;
    }

    if (is_stream) {
        relayStream(reader, writer, &result) catch |err| {
            // Only downstream-writer errors escape relayStream (upstream
            // read failures set truncated and end the loop instead).
            if (err == error.OutOfMemory) return err;
            result.elapsed_ms = watch.elapsedMs();
            return err;
        };
    } else {
        const body = readBuffered(
            allocator,
            reader,
            response.head.content_length,
            max_buffered_body_bytes,
        ) catch |err| {
            if (err == error.OutOfMemory) return err;
            result.truncated = true;
            result.elapsed_ms = watch.elapsedMs();
            return result;
        };
        defer allocator.free(body);
        try writer.writeAll(body);
        result.bytes_relayed = body.len;
    }

    result.elapsed_ms = watch.elapsedMs();
    return result;
}

/// Best-effort drain so a consumed connection returns to the pool clean.
fn drainResponse(response: *std.http.Client.Response) void {
    var transfer: [512]u8 = undefined;
    const reader = response.reader(&transfer);
    _ = reader.discardRemaining() catch {};
}

/// SSE / chunked relay: upstream bytes pass through untouched. Upstream read
/// failures end the relay with truncated=true; downstream writer errors
/// propagate to the caller.
fn relayStream(
    reader: *std.Io.Reader,
    writer: anytype,
    result: *ForwardResult,
) !void {
    var scanner = DoneScanner{};
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk) catch {
            result.truncated = true;
            return;
        };
        if (n == 0) return;
        const piece = chunk[0..n];
        if (scanner.feed(piece)) result.saw_done = true;
        try writer.writeAll(piece);
        result.bytes_relayed += n;
        if (n < chunk.len) return;
    }
}

/// Read a full response body with an upper bound. Known content-length uses a
/// single allocation; unknown length grows geometrically. Returns
/// error.StreamTooLong past `cap_bytes`. error.OutOfMemory propagates;
/// every other failure is a transport problem for the caller to classify.
fn readBuffered(
    allocator: Allocator,
    reader: *std.Io.Reader,
    content_length: ?u64,
    cap_bytes: usize,
) ![]u8 {
    if (content_length) |len| {
        if (len > @as(u64, cap_bytes)) return error.StreamTooLong;
        const exact: usize = @intCast(len);
        const buf = try allocator.alloc(u8, exact);
        errdefer allocator.free(buf);
        try reader.readSliceAll(buf);
        return buf;
    }

    var storage: []u8 = &.{};
    var len: usize = 0;
    var capacity: usize = 0;
    errdefer if (capacity > 0) allocator.free(storage[0..capacity]);

    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = try reader.readSliceShort(&chunk);
        if (n == 0) break;
        if (len + n > cap_bytes) return error.StreamTooLong;
        if (len + n > capacity) {
            var grown_by: usize = if (capacity == 0) 8192 else capacity * 2;
            while (grown_by < len + n) grown_by *= 2;
            grown_by = @min(grown_by, cap_bytes);
            const grown = if (capacity == 0)
                try allocator.alloc(u8, grown_by)
            else
                try allocator.realloc(storage[0..capacity], grown_by);
            storage = grown;
            capacity = grown_by;
        }
        @memcpy(storage[len..][0..n], chunk[0..n]);
        len += n;
        if (n < chunk.len) break;
    }

    if (len == 0) {
        if (capacity > 0) allocator.free(storage[0..capacity]);
        return try allocator.dupe(u8, "");
    }
    if (len < capacity) storage = try allocator.realloc(storage[0..capacity], len);
    return storage[0..len];
}

// ---------------------------------------------------------------------------
// [DONE] scanner (chunk-boundary safe)
// ---------------------------------------------------------------------------

/// Tracks the "[DONE]" SSE terminator across relay chunks. feed() returns
/// true once the marker has been observed (sticky). Correct for markers
/// split across any number of chunk boundaries: the tail always holds the
/// last up-to-5 bytes of the whole stream seen so far.
const DoneScanner = struct {
    tail: [done_marker.len - 1]u8 = undefined,
    tail_len: usize = 0,
    saw_done: bool = false,

    fn feed(self: *DoneScanner, chunk: []const u8) bool {
        if (self.saw_done) return true;
        if (std.mem.indexOf(u8, chunk, done_marker) != null) {
            self.saw_done = true;
            return true;
        }
        if (self.tail_len > 0) {
            var probe: [(done_marker.len - 1) * 2]u8 = undefined;
            const head_len = @min(chunk.len, done_marker.len - 1);
            @memcpy(probe[0..self.tail_len], self.tail[0..self.tail_len]);
            @memcpy(probe[self.tail_len..][0..head_len], chunk[0..head_len]);
            if (std.mem.indexOf(u8, probe[0 .. self.tail_len + head_len], done_marker) != null) {
                self.saw_done = true;
                return true;
            }
        }
        const total = self.tail_len + chunk.len;
        if (total <= done_marker.len - 1) {
            @memcpy(self.tail[self.tail_len..][0..chunk.len], chunk);
            self.tail_len = total;
        } else if (chunk.len >= done_marker.len - 1) {
            const keep = done_marker.len - 1;
            @memcpy(self.tail[0..keep], chunk[chunk.len - keep ..]);
            self.tail_len = keep;
        } else {
            const from_old = (done_marker.len - 1) - chunk.len;
            const old_start = self.tail_len - from_old;
            std.mem.copyForwards(u8, self.tail[0..from_old], self.tail[old_start..][0..from_old]);
            @memcpy(self.tail[from_old..][0..chunk.len], chunk);
            self.tail_len = done_marker.len - 1;
        }
        return false;
    }
};

// ---------------------------------------------------------------------------
// Transport error classification
// ---------------------------------------------------------------------------

/// Map a std.http.Client (or socket/TLS) failure to a synthetic status for
/// the rotator: 0 when the attempt plausibly timed out, 502 otherwise.
/// error.OutOfMemory is never passed here — callers propagate it.
fn classifyTransportError(err: anyerror) u16 {
    return switch (err) {
        error.Timeout,
        error.TimedOut,
        error.ConnectionTimedOut,
        => status_timeout,
        else => status_transport_error,
    };
}

// ---------------------------------------------------------------------------
// URL + outbound body helpers (pure, unit-tested)
// ---------------------------------------------------------------------------

/// Join base_url and an endpoint path, tolerating a trailing slash on the
/// base ("https://opencode.ai/zen/v1/" + "/chat/completions").
/// Caller owns the result.
fn buildUrl(allocator: Allocator, base_url: []const u8, endpoint_path: []const u8) ![]u8 {
    // Manual trailing-slash strip (stable across std versions).
    var base = base_url;
    while (base.len > 0 and base[base.len - 1] == '/') base = base[0 .. base.len - 1];
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, endpoint_path });
}

/// Normalize the client payload for upstream delivery: set "model" to
/// stripped_model (skipped when empty) and force "stream" to is_stream so the
/// relay mode always matches what the client asked for. All other fields pass
/// through unchanged (numbers may be reformatted by the JSON round-trip).
/// Falls back to a verbatim copy when the body is not a JSON object — the
/// upstream then rejects it with a real status instead of us failing shut.
/// Caller owns the result.
fn rewriteOutboundBody(
    allocator: Allocator,
    body_json: []const u8,
    stripped_model: []const u8,
    is_stream: bool,
) ![]u8 {
    return rewriteOutboundBodyInner(allocator, body_json, stripped_model, is_stream) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => allocator.dupe(u8, body_json),
    };
}

fn rewriteOutboundBodyInner(
    allocator: Allocator,
    body_json: []const u8,
    stripped_model: []const u8,
    is_stream: bool,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), body_json, .{});
    defer parsed.deinit();

    var root = parsed.value;
    const obj = switch (root) {
        .object => |*o| o,
        else => return error.NotAJsonObject,
    };
    if (stripped_model.len > 0) {
        try obj.put(arena.allocator(), "model", .{ .string = stripped_model });
    }
    try obj.put(arena.allocator(), "stream", .{ .bool = is_stream });

    // Same version shim as models.zig: valueAlloc on newer std, stringifyAlloc
    // on 0.13.x. Stringify `root` (not parsed.value): put() on a new key
    // mutates this local union copy's map header.
    if (comptime @hasDecl(std.json.Stringify, "valueAlloc")) {
        return try std.json.Stringify.valueAlloc(allocator, root, .{});
    } else {
        return try std.json.stringifyAlloc(allocator, root, .{});
    }
}

// ---------------------------------------------------------------------------
// /models aggregation
// ---------------------------------------------------------------------------

/// One aggregated catalog entry. All three strings are heap-owned; free with
/// ModelEntry.free or ModelList.deinit.
pub const ModelEntry = struct {
    /// Client-facing id with the provider prefix ("oc/deepseek-r1").
    id: []const u8,
    /// Raw upstream id ("deepseek-r1").
    upstream_id: []const u8,
    /// Snapshot of the provider display name at fetch time.
    provider_name: []const u8,

    pub fn free(self: *const ModelEntry, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.upstream_id);
        allocator.free(self.provider_name);
    }
};

/// Owned list of ModelEntry. Call deinit() exactly once. Manual slice growth
/// (no ArrayList) so this file stays version-agnostic.
pub const ModelList = struct {
    allocator: Allocator,
    items: []ModelEntry = &.{},

    pub fn empty(allocator: Allocator) ModelList {
        return .{ .allocator = allocator };
    }

    pub fn append(self: *ModelList, entry: ModelEntry) Allocator.Error!void {
        if (self.items.len == 0) {
            const fresh = try self.allocator.alloc(ModelEntry, 1);
            fresh[0] = entry;
            self.items = fresh;
            return;
        }
        const grown = try self.allocator.realloc(self.items, self.items.len + 1);
        grown[grown.len - 1] = entry;
        self.items = grown;
    }

    pub fn deinit(self: *ModelList) void {
        if (self.items.len > 0) {
            for (self.items) |*e| e.free(self.allocator);
            self.allocator.free(self.items);
            self.items = &.{};
        }
    }
};

/// Outcome of one provider's /models fetch. models is always safe to deinit,
/// including on failure (empty then). Only error.OutOfMemory escapes as a Zig
/// error; every transport/parse problem is reported via status with an empty
/// list so aggregation over providers can continue.
pub const FetchModelsResult = struct {
    status: u16,
    elapsed_ms: i64,
    models: ModelList,
};

/// GET <provider>/models with `Authorization: Bearer <api_key>` plus the
/// provider's static headers. Uses the process-wide single-threaded Io; see
/// fetchModelsWithIo for the app-shared-Io variant.
pub fn fetchModels(
    allocator: Allocator,
    provider: *const models.Provider,
    api_key: []const u8,
    timeout_ms: u32,
) error{OutOfMemory}!FetchModelsResult {
    const io = std.Io.Threaded.global_single_threaded.io();
    return fetchModelsWithIo(allocator, io, provider, api_key, timeout_ms);
}

/// fetchModels with an explicit Io.
pub fn fetchModelsWithIo(
    allocator: Allocator,
    io: std.Io,
    provider: *const models.Provider,
    api_key: []const u8,
    timeout_ms: u32,
) error{OutOfMemory}!FetchModelsResult {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    return fetchModelsWithClient(&client, provider, api_key, timeout_ms);
}

fn fetchModelsWithClient(
    client: *std.http.Client,
    provider: *const models.Provider,
    api_key: []const u8,
    timeout_ms: u32,
) error{OutOfMemory}!FetchModelsResult {
    const allocator = client.allocator;
    const watch = Stopwatch.start(client.io);
    var out = FetchModelsResult{
        .status = status_transport_error,
        .elapsed_ms = 0,
        .models = ModelList.empty(allocator),
    };
    errdefer out.models.deinit();

    const finish = struct {
        fn fail(
            result: *FetchModelsResult,
            elapsed_ms: i64,
            budget_ms: u32,
            err: anyerror,
        ) void {
            if (budget_ms != 0 and elapsed_ms >= @as(i64, budget_ms)) {
                result.status = status_timeout;
            } else {
                result.status = classifyTransportError(err);
            }
            result.elapsed_ms = elapsed_ms;
        }
    }.fail;

    const url = try buildUrl(allocator, provider.base_url, "/models");
    defer allocator.free(url);

    const uri = std.Uri.parse(url) catch {
        out.elapsed_ms = watch.elapsedMs();
        return out;
    };

    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(bearer);

    const extra = try allocator.alloc(std.http.Header, provider.headers.len);
    defer allocator.free(extra);
    var extra_count: usize = 0;
    for (provider.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.key, "user-agent") or
            std.ascii.eqlIgnoreCase(h.key, "authorization") or
            std.ascii.eqlIgnoreCase(h.key, "content-type") or
            std.ascii.eqlIgnoreCase(h.key, "accept-encoding") or
            std.ascii.eqlIgnoreCase(h.key, "host") or
            std.ascii.eqlIgnoreCase(h.key, "content-length") or
            std.ascii.eqlIgnoreCase(h.key, "connection")) continue;
        extra[extra_count] = .{ .name = h.key, .value = h.value };
        extra_count += 1;
    }

    var req = client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = .{ .override = provider.findHeader("authorization") orelse bearer },
            .user_agent = if (provider.findHeader("user-agent")) |ua| .{ .override = ua } else .default,
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = extra[0..extra_count],
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        finish(&out, watch.elapsedMs(), timeout_ms, err);
        return out;
    };
    defer req.deinit();

    req.sendBodiless() catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        finish(&out, watch.elapsedMs(), timeout_ms, err);
        return out;
    };

    var redirect_buf: [512]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        finish(&out, watch.elapsedMs(), timeout_ms, err);
        return out;
    };

    const status: u16 = @as(u16, @intFromEnum(response.head.status));
    out.status = status;
    if (status != 200 or response.head.content_encoding != .identity) {
        if (status == 200) out.status = status_transport_error;
        drainResponse(&response);
        out.elapsed_ms = watch.elapsedMs();
        return out;
    }

    var transfer: [4096]u8 = undefined;
    const body = readBuffered(
        allocator,
        response.reader(&transfer),
        response.head.content_length,
        max_models_body_bytes,
    ) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        finish(&out, watch.elapsedMs(), timeout_ms, err);
        return out;
    };
    defer allocator.free(body);

    out.models = try parseModelsBody(allocator, provider, body);
    out.elapsed_ms = watch.elapsedMs();
    return out;
}

/// Parse an OpenAI /models document into prefixed entries. Tolerant: any
/// malformed shape yields an empty (or partial) list, never an error — only
/// error.OutOfMemory escapes. Public so proxy.zig can reuse it for cached or
/// offline model documents, and so tests can cover it without a network.
pub fn parseModelsBody(
    allocator: Allocator,
    provider: *const models.Provider,
    body: []const u8,
) error{OutOfMemory}!ModelList {
    var list = ModelList.empty(allocator);
    errdefer list.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return list;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return list,
    };
    const data_val = obj.get("data") orelse return list;
    const entries = switch (data_val) {
        .array => |a| a,
        else => return list,
    };

    for (entries.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const id_val = item_obj.get("id") orelse continue;
        const upstream_id = switch (id_val) {
            .string => |s| s,
            else => continue,
        };

        const exposed = try std.fmt.allocPrint(allocator, "{s}{s}", .{ provider.prefix, upstream_id });
        errdefer allocator.free(exposed);
        const upstream_copy = try allocator.dupe(u8, upstream_id);
        errdefer allocator.free(upstream_copy);
        const provider_copy = try allocator.dupe(u8, provider.display_name);
        errdefer allocator.free(provider_copy);
        try list.append(.{
            .id = exposed,
            .upstream_id = upstream_copy,
            .provider_name = provider_copy,
        });
    }
    return list;
}

// ---------------------------------------------------------------------------
// Unit tests (offline: pure helpers only; transport is covered by e2e)
// ---------------------------------------------------------------------------

test "endpoint paths match the OpenAI-compatible surface" {
    try std.testing.expectEqualStrings("/chat/completions", Endpoint.chat.path());
    try std.testing.expectEqualStrings("/completions", Endpoint.plain.path());
}

test "buildUrl tolerates a trailing slash on the base" {
    const allocator = std.testing.allocator;
    const a = try buildUrl(allocator, "https://opencode.ai/zen/v1/", "/chat/completions");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1/chat/completions", a);

    const b = try buildUrl(allocator, "https://api.kilo.ai/api/gateway", "/models");
    defer allocator.free(b);
    try std.testing.expectEqualStrings("https://api.kilo.ai/api/gateway/models", b);
}

test "rewriteOutboundBody swaps model and stream, keeps the rest" {
    const allocator = std.testing.allocator;
    const out = try rewriteOutboundBody(
        allocator,
        \\{"model":"oc/deepseek-r1","stream":false,"temperature":0.7,"messages":[]}
    ,
        "deepseek-r1",
        true,
    );
    defer allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("deepseek-r1", parsed.value.object.get("model").?.string);
    try std.testing.expectEqual(true, parsed.value.object.get("stream").?.bool);
    try std.testing.expect(parsed.value.object.get("temperature").? == .float);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("messages").?.array.items.len);
}

test "rewriteOutboundBody leaves model alone when stripped_model is empty" {
    const allocator = std.testing.allocator;
    const body =
        \\{"model":"x","a":1}
    ;
    const out = try rewriteOutboundBody(allocator, body, "", false);
    defer allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("x", parsed.value.object.get("model").?.string);
    try std.testing.expectEqual(false, parsed.value.object.get("stream").?.bool);
}

test "rewriteOutboundBody falls back to verbatim on malformed input" {
    const allocator = std.testing.allocator;
    const out = try rewriteOutboundBody(allocator, "not json{{", "m", true);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("not json{{", out);
}

test "DoneScanner finds whole and boundary-split markers" {
    // Whole marker in one chunk.
    var s1 = DoneScanner{};
    try std.testing.expect(!s1.feed("data: hello\n"));
    try std.testing.expect(s1.feed("data: [DONE]\n"));
    try std.testing.expect(s1.saw_done);

    // Split at every possible offset of "[DONE]".
    var offset: usize = 1;
    while (offset < done_marker.len) : (offset += 1) {
        var s = DoneScanner{};
        try std.testing.expect(!s.feed(done_marker[0..offset]));
        try std.testing.expect(s.feed(done_marker[offset..]));
        try std.testing.expect(s.saw_done);
    }
}

test "DoneScanner survives marker split across many tiny chunks" {
    var s = DoneScanner{};
    const pieces = [_][]const u8{ "da", "ta: [D", "O", "N", "E]\n" };
    for (pieces[0 .. pieces.len - 1]) |p| try std.testing.expect(!s.feed(p));
    try std.testing.expect(s.feed(pieces[pieces.len - 1]));
    try std.testing.expect(s.saw_done);
}

test "DoneScanner flags a marker completed by the next chunk" {
    var s = DoneScanner{};
    try std.testing.expect(!s.feed("data: [DON"));
    // "[DONE]" completes across the boundary here, so this must flag.
    try std.testing.expect(s.feed("E] more text"));
    try std.testing.expect(s.saw_done);
}

test "DoneScanner ignores lookalikes split across chunks" {
    var s = DoneScanner{};
    try std.testing.expect(!s.feed("[DONX"));
    try std.testing.expect(!s.feed("E]"));
    try std.testing.expect(!s.saw_done);
}

test "classifyTransportError maps timeouts to 0, rest to 502" {
    try std.testing.expectEqual(status_timeout, classifyTransportError(error.Timeout));
    try std.testing.expectEqual(status_timeout, classifyTransportError(error.TimedOut));
    try std.testing.expectEqual(status_timeout, classifyTransportError(error.ConnectionTimedOut));
    try std.testing.expectEqual(status_transport_error, classifyTransportError(error.ConnectionRefused));
    try std.testing.expectEqual(status_transport_error, classifyTransportError(error.HttpHeadersInvalid));
}

test "Stopwatch measures non-negative elapsed time" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var w = Stopwatch.start(io);
    try std.testing.expect(w.elapsedMs() >= 0);
    w.restart();
    try std.testing.expect(w.elapsedMs() >= 0);
    try std.testing.expect(nowMs() > 0);
    try std.testing.expect(elapsedMsSince(nowMs()) >= 0);
}

test "ModelList append and deinit own every string" {
    const allocator = std.testing.allocator;
    var list = ModelList.empty(allocator);
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 0), list.items.len);

    try list.append(.{
        .id = try allocator.dupe(u8, "oc/a"),
        .upstream_id = try allocator.dupe(u8, "a"),
        .provider_name = try allocator.dupe(u8, "OpenCode Zen"),
    });
    try list.append(.{
        .id = try allocator.dupe(u8, "oc/b"),
        .upstream_id = try allocator.dupe(u8, "b"),
        .provider_name = try allocator.dupe(u8, "OpenCode Zen"),
    });
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("oc/b", list.items[1].id);
}

test "parseModelsBody prefixes ids and tolerates bad shapes" {
    const allocator = std.testing.allocator;
    var provider = try models.defaultKiloProvider(allocator);
    defer provider.deinit(allocator);

    var good = try parseModelsBody(
        allocator,
        &provider,
        \\{"object":"list","data":[{"id":"llama-3.3","object":"model"},{"id":42},{"nope":true}]}
        ,
    );
    defer good.deinit();
    try std.testing.expectEqual(@as(usize, 1), good.items.len);
    try std.testing.expectEqualStrings("kilo/llama-3.3", good.items[0].id);
    try std.testing.expectEqualStrings("llama-3.3", good.items[0].upstream_id);
    try std.testing.expectEqualStrings("Kilo Gateway", good.items[0].provider_name);

    var malformed = try parseModelsBody(allocator, &provider, "{{oops");
    defer malformed.deinit();
    try std.testing.expectEqual(@as(usize, 0), malformed.items.len);

    const wrong_doc =
        \\{"data":{"id":"x"}}
    ;
    var wrong_shape = try parseModelsBody(allocator, &provider, wrong_doc);
    defer wrong_shape.deinit();
    try std.testing.expectEqual(@as(usize, 0), wrong_shape.items.len);
}

test "ForwardResult deinit frees a captured error body" {
    const allocator = std.testing.allocator;
    var r = ForwardResult{
        .status = 429,
        .elapsed_ms = 12,
        .error_body = try allocator.dupe(u8, "rate limited"),
    };
    r.deinit(allocator);
    try std.testing.expect(r.error_body == null);
    // Second call is a safe no-op.
    r.deinit(allocator);
}

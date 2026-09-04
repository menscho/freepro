// tests/e2e_proxy.zig
//
// freepro end-to-end proxy tests (Wave3-Task05): drive the real Proxy from
// src/proxy.zig over loopback sockets against stub upstream servers.
//
// Covered over real TCP with std only (no GUI, no third-party packages):
//   1. 429 failover: first key hits 429 -> proxy retries with the next key,
//      forwards the stripped model name, and cools the burned key down.
//   2. Prefix routing: oc/ and kilo/ models route to the right stub with the
//      prefix stripped, on both /v1/chat/completions and /v1/completions.
//   3. Catalog merge: GET /v1/models merges every stub with prefixes applied.
//   0. Harness smoke (keeper): stub answers a direct POST without the proxy,
//      proving the test transport itself before the proxy is involved.
//
// Run (from the repo root; needs loopback):
//   zig test --dep proxy -Mroot=tests/e2e_proxy.zig -Mproxy=src/proxy.zig
// Bare `zig test tests/e2e_proxy.zig` cannot work on Zig 0.16: a module is
// confined to its own directory, so tests/ has no relative path into src/
// and the `proxy` name must be wired explicitly. Under `zig build test` this
// root needs ONLY the `proxy` named import (proxy.zig pulls models/rotator
// in relatively inside its own module); do not also wire a `models` module
// for this root or src/models.zig lands in two modules and the build fails.
// Ports 18211..18214 (proxy) and 18311..18314,18321 (stubs) are reserved for
// this file so reruns and sibling test binaries do not collide.
//
// Transport note: on Windows this file uses raw blocking Winsock (WinNet
// below), NOT std.Io.net; other platforms use std.Io.net, matching
// proxy.zig's own selection. Rationale, verified 2026-09-04 while debugging
// this suite: std.Io.Reader.readSliceShort in Zig 0.16.0 loops its readVec
// until the WHOLE destination fills or EOF (lib/std/Io/Reader.zig:
// readSliceShort keeps calling readVec while buffer.len - i != 0). Framing
// loops that pass it an 8 KiB scratch buffer therefore hang on persistent
// connections: the peer sent a complete 181 B request and waits, the reader
// waits for 8011 more bytes or EOF, neither ever comes. The harness side
// here only ever single-recvs (raw recvShort on Windows, one readVec per
// fill elsewhere), so it is immune. The test client additionally
// half-closes its write side after sending (shutdownSend): that turns the
// proxy's read-full wait into an EOF-terminated short read, which unblocks
// proxy.zig's current readSliceShort-based framing without changing what it
// parses. The half-close is size-independent, valid HTTP/TCP behavior, and
// harmless once the proxy switches to single-recv framing — at which point
// it can be dropped (search shutdownSend).

const std = @import("std");
const builtin = @import("builtin");

// Single named import: `proxy` (wired by the runner, see Run above).
// This file deliberately does NOT import `models`: tests/ cannot relatively
// import ../src/* (Zig 0.16 confines a module to the directory holding its
// root), and declaring a second `models` module would place src/models.zig
// in two modules at once (rejected: "files must belong to only one module").
// The config type is derived from Proxy's public `config` field instead,
// and test configs are built from JSON text (see parseTestConfig).
const proxy_mod = @import("proxy");

const Allocator = std.mem.Allocator;
const is_windows = builtin.os.tag == .windows;

// ---------------------------------------------------------------------------
// Bridging proxy-owned types (see the import note above)
// ---------------------------------------------------------------------------

fn StructField(comptime T: type, comptime name: []const u8) type {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.type;
    }
    @compileError("proxy type has no field '" ++ name ++ "'");
}

const Proxy = proxy_mod.Proxy;
const ProxyConfig = std.meta.Child(StructField(Proxy, "config"));

/// Build a test ProxyConfig from JSON text. std.json honors the struct
/// defaults (e.g. Key.state = .Active), so the documents below only spell
/// out what the test needs. The caller owns the result (deinit with the
/// same allocator).
fn parseTestConfig(alloc: Allocator, json_text: []const u8) !ProxyConfig {
    const parsed = try std.json.parseFromSlice(ProxyConfig, alloc, json_text, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    return try parsed.value.clone(alloc);
}

/// Compare a KeyState without naming its type (it lives in the proxy's
/// private models instance).
fn expectStateName(state: anytype, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, @tagName(state));
}

fn spinYield() void {
    std.Thread.yield() catch {};
}

// ---------------------------------------------------------------------------
// Transport: Listener (bind/accept) + Conn (connected peer)
//
// Windows goes through raw blocking Winsock (see the file header); other
// platforms wrap std.Io.net. Both expose the same shape so the stub, the
// client and the framing below are written once:
//   Listener.listen(port) !Listener / accept() !Conn / close()
//   Conn.connectTo(port) !Conn / readFramed(alloc) ![]u8 (one HTTP message)
//   Conn.sendAll(bytes) !void / readAll(alloc) ![]u8 (till clean EOF) / close()
// ---------------------------------------------------------------------------

const Listener = if (is_windows) WinListener else StdListener;
const Conn = if (is_windows) WinConn else StdConn;

// -- shared message helpers (operate on bytes only) --------------------------

const max_head_bytes: usize = 64 * 1024;

fn parseContentLength(head: []const u8) usize {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "content-length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, value, 10) catch 0;
    }
    return 0;
}

const MiniRequest = struct {
    method: []const u8,
    target: []const u8,
    body: []const u8,
};

fn parseMiniRequest(raw: []const u8) !MiniRequest {
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadRequest;
    const head = raw[0..head_end];
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return error.BadRequest;
    var parts = std.mem.splitScalar(u8, head[0..line_end], ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    if (parts.next() == null) return error.BadRequest;
    const content_len = parseContentLength(head);
    const body_off = head_end + 4;
    if (raw.len < body_off + content_len) return error.BadRequest;
    return .{ .method = method, .target = target, .body = raw[body_off .. body_off + content_len] };
}

// -- Windows: raw blocking Winsock -------------------------------------------
//
// Minimal trim of the approach proven by src/netwin.zig: plain blocking
// calls have no APC/overlapped quirk surface and behave identically on every
// thread. No Reader/Writer vtables here: framing recvs directly with
// caller-sized buffers, so over-reads are impossible by construction.

const WinNet = struct {
    const SOCKET = usize;
    const INVALID: SOCKET = ~@as(SOCKET, 0);

    extern "ws2_32" fn socket(af: c_int, socket_type: c_int, protocol: c_int) callconv(.winapi) SOCKET;
    extern "ws2_32" fn bind(s: SOCKET, addr: *const SockAddrIn, namelen: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn listen(s: SOCKET, backlog: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn accept(s: SOCKET, addr: ?*SockAddrIn, addrlen: ?*c_int) callconv(.winapi) SOCKET;
    extern "ws2_32" fn connect(s: SOCKET, addr: *const SockAddrIn, namelen: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn shutdown(s: SOCKET, how: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;
    extern "ws2_32" fn setsockopt(s: SOCKET, level: c_int, optname: c_int, optval: [*]const u8, optlen: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn WSAStartup(wVersionRequired: u16, lpWSAData: *WSADATA) callconv(.winapi) c_int;

    const WSADATA = extern struct {
        wVersion: u16,
        wHighVersion: u16,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?[*:0]u8,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
    };

    const SockAddrIn = extern struct {
        sin_family: u16,
        sin_port: u16,
        sin_addr: u32,
        sin_zero: [8]u8,
    };

    // Process-lifetime Winsock init with real once semantics: losers block on
    // the mutex until the winner finishes. (A racy swap-and-proceed flag is
    // NOT enough: the loser would call socket() before WSAStartup completes
    // and fail with 10093/WSANOTINITIALISED.)
    var wsa_mu: Mutex = .{};
    var wsa_done: bool = false;

    fn ensureWsa() void {
        wsa_mu.lock();
        defer wsa_mu.unlock();
        if (wsa_done) return;
        var data: WSADATA = undefined;
        const rc = WSAStartup(0x0202, &data);
        std.debug.assert(rc == 0);
        wsa_done = true;
    }

    fn loopback(port: u16) SockAddrIn {
        return .{
            .sin_family = 2, // AF_INET
            .sin_port = std.mem.nativeToBig(u16, port),
            .sin_addr = 0x0100007F, // 127.0.0.1 in network order
            .sin_zero = [_]u8{0} ** 8,
        };
    }

    fn open() !SOCKET {
        ensureWsa();
        const s = socket(2, 1, 6); // AF_INET, SOCK_STREAM, IPPROTO_TCP
        if (s == INVALID) return error.SocketCreateFailed;
        return s;
    }

    fn sendAll(s: SOCKET, buf: []const u8) !void {
        var off: usize = 0;
        while (off < buf.len) {
            const chunk = @min(buf.len - off, std.math.maxInt(c_int));
            const n = send(s, buf.ptr + off, @as(c_int, @intCast(chunk)), 0);
            if (n <= 0) return error.SendFailed;
            off += @as(usize, @intCast(n));
        }
    }
};

const WinListener = struct {
    sock: WinNet.SOCKET,

    pub fn listen(port: u16) !WinListener {
        const s = try WinNet.open();
        errdefer _ = WinNet.closesocket(s);
        const one: u32 = 1;
        _ = WinNet.setsockopt(s, 0xffff, 0x0004, @ptrCast(&one), @sizeOf(u32)); // SOL_SOCKET, SO_REUSEADDR
        var sa = WinNet.loopback(port);
        if (WinNet.bind(s, &sa, @sizeOf(WinNet.SockAddrIn)) != 0) return error.BindFailed;
        if (WinNet.listen(s, 128) != 0) return error.ListenFailed;
        return .{ .sock = s };
    }

    pub fn accept(self: WinListener) !WinConn {
        const c = WinNet.accept(self.sock, null, null);
        if (c == WinNet.INVALID) return error.AcceptFailed;
        return .{ .sock = c };
    }

    pub fn close(self: WinListener) void {
        if (self.sock != WinNet.INVALID) _ = WinNet.closesocket(self.sock);
    }
};

const WinConn = struct {
    sock: WinNet.SOCKET,

    pub fn connectTo(port: u16) !WinConn {
        const s = try WinNet.open();
        errdefer _ = WinNet.closesocket(s);
        var sa = WinNet.loopback(port);
        if (WinNet.connect(s, &sa, @sizeOf(WinNet.SockAddrIn)) != 0) return error.ConnectFailed;
        return .{ .sock = s };
    }

    /// One recv; 0 means the peer cleanly closed. Never over-reads: at most
    /// buf.len bytes land in buf.
    pub fn recvShort(self: WinConn, buf: []u8) !usize {
        if (buf.len == 0) return 0;
        const chunk = @min(buf.len, std.math.maxInt(c_int));
        const n = WinNet.recv(self.sock, buf.ptr, @as(c_int, @intCast(chunk)), 0);
        if (n > 0) return @as(usize, @intCast(n));
        if (n == 0) return 0;
        return error.ReadFailed;
    }

    pub fn sendAll(self: WinConn, bytes: []const u8) !void {
        try WinNet.sendAll(self.sock, bytes);
    }

    /// Half-close the write side: the peer observes EOF right after the bytes
    /// already sent, while this side can still read the response. Used by the
    /// test client (see clientRoundTrip).
    pub fn shutdownSend(self: WinConn) !void {
        if (WinNet.shutdown(self.sock, 1) != 0) return error.ShutdownFailed; // SD_SEND
    }

    /// One full HTTP message (head + Content-Length body), appended into an
    /// owned buffer. Clean EOF before/within the message reads as
    /// error.EndOfStream so stop-pokes stay uncounted.
    pub fn readFramed(self: WinConn, alloc: Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        var tmp: [8192]u8 = undefined;
        while (std.mem.indexOf(u8, buf.items, "\r\n\r\n") == null) {
            if (buf.items.len >= max_head_bytes) return error.HeadersTooLarge;
            const n = try self.recvShort(&tmp);
            if (n == 0) return error.EndOfStream;
            try buf.appendSlice(alloc, tmp[0..n]);
        }
        const head_end = std.mem.indexOf(u8, buf.items, "\r\n\r\n").? + 4;
        const total = head_end + parseContentLength(buf.items[0..head_end]);
        while (buf.items.len < total) {
            const n = try self.recvShort(&tmp);
            if (n == 0) return error.EndOfStream;
            try buf.appendSlice(alloc, tmp[0..n]);
        }
        return buf.items;
    }

    /// Everything until clean EOF. Transport errors propagate.
    pub fn readAll(self: WinConn, alloc: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        var chunk: [8192]u8 = undefined;
        while (true) {
            const n = try self.recvShort(&chunk);
            if (n == 0) break;
            try out.appendSlice(alloc, chunk[0..n]);
        }
        if (out.items.len == 0) return try alloc.dupe(u8, "");
        return try out.toOwnedSlice(alloc);
    }

    pub fn close(self: WinConn) void {
        if (self.sock != WinNet.INVALID) _ = WinNet.closesocket(self.sock);
    }
};

// -- other platforms: thin std.Io.net wrappers --------------------------------
//
// std.Io.net is healthy off Windows, and each Conn performs exactly one
// read phase, so transient per-call Reader/Writer objects are exact (no
// cross-call buffering to lose). Io comes from the global single-threaded
// instance; plain blocking socket calls run on the calling thread there.

const StdNet = std.Io.net;

fn stdIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// One recv through a std Reader: serves its internal buffer first, then at
/// most ONE socket read. Never use readSliceShort for framing here: in Zig
/// 0.16 it loops until the whole destination is full (or EOF), which hangs
/// on persistent connections (see the file header). A 0 return means clean
/// EOF.
fn stdRecvOnce(reader: *std.Io.Reader, buf: []u8) !usize {
    var vec: [1][]u8 = .{buf};
    return try reader.readVec(&vec);
}

fn stdReadFramed(reader: *std.Io.Reader, alloc: Allocator) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    var tmp: [8192]u8 = undefined;
    while (std.mem.indexOf(u8, buf.items, "\r\n\r\n") == null) {
        if (buf.items.len >= max_head_bytes) return error.HeadersTooLarge;
        const n = try stdRecvOnce(reader, &tmp);
        if (n == 0) return error.EndOfStream;
        try buf.appendSlice(alloc, tmp[0..n]);
    }
    const head_end = std.mem.indexOf(u8, buf.items, "\r\n\r\n").? + 4;
    const total = head_end + parseContentLength(buf.items[0..head_end]);
    while (buf.items.len < total) {
        const n = try stdRecvOnce(reader, &tmp);
        if (n == 0) return error.EndOfStream;
        try buf.appendSlice(alloc, tmp[0..n]);
    }
    return buf.items;
}

const StdListener = struct {
    server: StdNet.Server,

    pub fn listen(port: u16) !StdListener {
        const io = stdIo();
        const addr = try StdNet.IpAddress.parseIp4("127.0.0.1", port);
        return .{ .server = try addr.listen(io, .{ .reuse_address = true }) };
    }

    pub fn accept(self: *StdListener) !StdConn {
        const io = stdIo();
        return .{ .stream = try self.server.accept(io) };
    }

    pub fn close(self: *StdListener) void {
        self.server.deinit(stdIo());
    }
};

const StdConn = struct {
    stream: StdNet.Stream,

    pub fn connectTo(port: u16) !StdConn {
        const io = stdIo();
        const addr = try StdNet.IpAddress.parseIp4("127.0.0.1", port);
        return .{ .stream = try addr.connect(io, .{ .mode = .stream }) };
    }

    pub fn readFramed(self: StdConn, alloc: Allocator) ![]u8 {
        var rbuf: [8192]u8 = undefined;
        var sr = self.stream.reader(stdIo(), &rbuf);
        return try stdReadFramed(&sr.interface, alloc);
    }

    pub fn sendAll(self: StdConn, bytes: []const u8) !void {
        var wbuf: [8192]u8 = undefined;
        var sw = self.stream.writer(stdIo(), &wbuf);
        try sw.interface.writeAll(bytes);
        try sw.interface.flush();
    }

    /// Half-close the write side; see WinConn.shutdownSend.
    pub fn shutdownSend(self: StdConn) !void {
        try self.stream.shutdown(stdIo(), .send);
    }

    pub fn readAll(self: StdConn, alloc: Allocator) ![]u8 {
        var rbuf: [8192]u8 = undefined;
        var sr = self.stream.reader(stdIo(), &rbuf);
        var out: std.ArrayList(u8) = .empty;
        var chunk: [8192]u8 = undefined;
        while (true) {
            const n = try stdRecvOnce(&sr.interface, &chunk);
            if (n == 0) break;
            try out.appendSlice(alloc, chunk[0..n]);
        }
        if (out.items.len == 0) return try alloc.dupe(u8, "");
        return try out.toOwnedSlice(alloc);
    }

    pub fn close(self: StdConn) void {
        self.stream.close(stdIo());
    }
};

// ---------------------------------------------------------------------------
// Downstream test client (talks to the proxy under test)
// ---------------------------------------------------------------------------

/// Connect to loopback, retrying briefly so listener startup races (stub or
/// proxy thread still binding) cannot flake the suite.
fn connectLoopback(port: u16) !Conn {
    var spins: u32 = 0;
    while (true) {
        if (Conn.connectTo(port)) |c| {
            return c;
        } else |_| {
            if (spins >= 20_000) return error.ConnectTimeout;
            spins += 1;
            spinYield();
        }
    }
}

fn clientRoundTrip(alloc: Allocator, port: u16, request: []const u8) ![]u8 {
    const conn = try connectLoopback(port);
    defer conn.close();
    try conn.sendAll(request);
    // Half-close the write side: the proxy's 0.16 framing reads with
    // readSliceShort, which only returns when its 8 KiB destination fills or
    // EOF arrives. Without this FIN it would wait for 8 KiB on every request
    // that arrives whole (see the file header). The read side stays open for
    // the response, so this is size-independent and harmless once the proxy
    // switches to single-recv framing.
    try conn.shutdownSend();
    return try conn.readAll(alloc);
}

fn respStatus(resp: []const u8) !u16 {
    const eol = std.mem.indexOf(u8, resp, "\r\n") orelse return error.BadResponse;
    var parts = std.mem.splitScalar(u8, resp[0..eol], ' ');
    _ = parts.next() orelse return error.BadResponse;
    return try std.fmt.parseInt(u16, parts.next() orelse return error.BadResponse, 10);
}

fn respBody(resp: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return &.{};
    return resp[idx + 4 ..];
}

fn postJson(alloc: Allocator, port: u16, path: []const u8, json: []const u8) ![]u8 {
    const req = try std.fmt.allocPrint(
        alloc,
        "POST {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ path, json.len, json },
    );
    defer alloc.free(req);
    return try clientRoundTrip(alloc, port, req);
}

fn getPath(alloc: Allocator, port: u16, path: []const u8) ![]u8 {
    const req = try std.fmt.allocPrint(
        alloc,
        "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
        .{path},
    );
    defer alloc.free(req);
    return try clientRoundTrip(alloc, port, req);
}

// ---------------------------------------------------------------------------
// Stub upstream: canned OpenAI-compatible server on loopback
//
// GET  -> 200 with options.models_body (the /v1/models document).
// POST -> options.fail_first_post turns the first POST into a 429 (failover
//         test); every other POST answers options.chat_ok_body.
// Every parsed request records its Authorization header, method, target path
// and (for POST) the forwarded model name. Recording happens BEFORE the
// response is written, so once the downstream client has its reply every
// observation is already visible (reads still take mu for safety).
// ---------------------------------------------------------------------------

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

const StubOptions = struct {
    models_body: []const u8 = "{\"object\":\"list\",\"data\":[]}",
    chat_ok_body: []const u8 = "{\"id\":\"chatcmpl-e2e\",\"object\":\"chat.completion\",\"choices\":[]}",
    fail_first_post: bool = false,
};

const StubUpstream = struct {
    port: u16,
    options: StubOptions,
    running: std.atomic.Value(bool),
    total_requests: std.atomic.Value(usize),
    post_requests: std.atomic.Value(usize),
    mu: Mutex,
    auth_count: usize,
    auths: [8][64]u8,
    auth_lens: [8]usize,
    last_model: [128]u8,
    last_model_len: usize,
    last_method: [16]u8,
    last_method_len: usize,
    last_target: [256]u8,
    last_target_len: usize,

    fn init(port: u16, options: StubOptions) StubUpstream {
        return .{
            .port = port,
            .options = options,
            .running = std.atomic.Value(bool).init(true),
            .total_requests = std.atomic.Value(usize).init(0),
            .post_requests = std.atomic.Value(usize).init(0),
            .mu = .{},
            .auth_count = 0,
            .auths = undefined,
            .auth_lens = [_]usize{0} ** 8,
            .last_model = undefined,
            .last_model_len = 0,
            .last_method = undefined,
            .last_method_len = 0,
            .last_target = undefined,
            .last_target_len = 0,
        };
    }

    fn run(self: *StubUpstream) void {
        var server = Listener.listen(self.port) catch return;
        defer server.close();
        while (self.running.load(.seq_cst)) {
            const conn = server.accept() catch {
                if (!self.running.load(.seq_cst)) break;
                continue;
            };
            // Poke-to-stop connections carry no bytes; serve() tolerates EOF
            // without counting them.
            self.serve(conn) catch {};
        }
    }

    /// Wake a blocking accept() so run() exits; call before join().
    fn stop(self: *StubUpstream) void {
        self.running.store(false, .seq_cst);
        const poke = Conn.connectTo(self.port) catch return;
        poke.close();
    }

    fn serve(self: *StubUpstream, conn: Conn) !void {
        defer conn.close();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const raw = conn.readFramed(alloc) catch return;
        const req = parseMiniRequest(raw) catch return;

        const is_post = std.ascii.eqlIgnoreCase(req.method, "POST");
        const slot = self.total_requests.fetchAdd(1, .seq_cst);

        self.mu.lock();
        {
            const mlen = @min(req.method.len, self.last_method.len);
            @memcpy(self.last_method[0..mlen], req.method[0..mlen]);
            self.last_method_len = mlen;
            const tlen = @min(req.target.len, self.last_target.len);
            @memcpy(self.last_target[0..tlen], req.target[0..tlen]);
            self.last_target_len = tlen;
            recordAuthLocked(self, raw, slot);
            if (is_post) recordModelLocked(self, alloc, req.body);
        }
        self.mu.unlock();

        var status: u16 = 200;
        var phrase: []const u8 = "OK";
        var body: []const u8 = self.options.models_body;
        if (is_post) {
            const n = self.post_requests.fetchAdd(1, .seq_cst);
            if (self.options.fail_first_post and n == 0) {
                status = 429;
                phrase = "Too Many Requests";
                body = "{\"error\":{\"message\":\"slow down\",\"type\":\"rate_limit\"}}";
            } else {
                body = self.options.chat_ok_body;
            }
        }

        var head: [256]u8 = undefined;
        const head_len = (std.fmt.bufPrint(
            &head,
            "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ status, phrase, body.len },
        ) catch return).len;
        try conn.sendAll(head[0..head_len]);
        try conn.sendAll(body);
    }

    fn recordAuthLocked(self: *StubUpstream, raw: []const u8, slot: usize) void {
        if (slot >= self.auths.len) return;
        const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return;
        var lines = std.mem.splitSequence(u8, raw[0..head_end], "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "authorization")) continue;
            const v = std.mem.trim(u8, line[colon + 1 ..], " \t");
            const len = @min(v.len, self.auths[slot].len);
            @memcpy(self.auths[slot][0..len], v[0..len]);
            self.auth_lens[slot] = len;
            self.auth_count = @max(self.auth_count, slot + 1);
            return;
        }
    }

    fn recordModelLocked(self: *StubUpstream, alloc: Allocator, body: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return;
        const m = switch (parsed.value) {
            .object => |o| switch (o.get("model") orelse return) {
                .string => |s| s,
                else => return,
            },
            else => return,
        };
        const len = @min(m.len, self.last_model.len);
        @memcpy(self.last_model[0..len], m[0..len]);
        self.last_model_len = len;
    }

    // -- observation accessors (mu-guarded copies into caller buffers) --------

    fn authAt(self: *StubUpstream, slot: usize, buf: *[64]u8) []const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        if (slot >= self.auth_count) return &.{};
        const len = self.auth_lens[slot];
        @memcpy(buf[0..len], self.auths[slot][0..len]);
        return buf[0..len];
    }

    fn lastModel(self: *StubUpstream, buf: *[128]u8) []const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        @memcpy(buf[0..self.last_model_len], self.last_model[0..self.last_model_len]);
        return buf[0..self.last_model_len];
    }

    fn lastMethod(self: *StubUpstream, buf: *[16]u8) []const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        @memcpy(buf[0..self.last_method_len], self.last_method[0..self.last_method_len]);
        return buf[0..self.last_method_len];
    }

    fn lastTarget(self: *StubUpstream, buf: *[256]u8) []const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        @memcpy(buf[0..self.last_target_len], self.last_target[0..self.last_target_len]);
        return buf[0..self.last_target_len];
    }
};

// ---------------------------------------------------------------------------
// E2E tests
// ---------------------------------------------------------------------------

test "e2e harness: stub answers a direct POST without the proxy" {
    const alloc = std.testing.allocator;

    var stub = StubUpstream.init(18321, .{});
    const stub_thread = try std.Thread.spawn(.{}, StubUpstream.run, .{&stub});
    defer {
        stub.stop();
        stub_thread.join();
    }
    {
        const s = try connectLoopback(18321);
        s.close();
    }

    const resp = try postJson(alloc, 18321, "/oc/v1/chat/completions", "{\"model\":\"direct-model\"}");
    defer alloc.free(resp);
    try std.testing.expectEqual(@as(u16, 200), try respStatus(resp));
    try std.testing.expect(std.mem.indexOf(u8, respBody(resp), "chatcmpl-e2e") != null);
    try std.testing.expectEqual(@as(usize, 1), stub.post_requests.load(.seq_cst));
    var mbuf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("direct-model", stub.lastModel(&mbuf));
}

test "e2e: 429 failover rotates bearer key and strips oc/ prefix" {
    const alloc = std.testing.allocator;

    var stub = StubUpstream.init(18311, .{ .fail_first_post = true });
    const stub_thread = try std.Thread.spawn(.{}, StubUpstream.run, .{&stub});
    defer {
        stub.stop();
        stub_thread.join();
    }
    // Block until the stub is bound so the proxy can never outrun it.
    {
        const s = try connectLoopback(18311);
        s.close();
    }

    var cfg: ProxyConfig = try parseTestConfig(alloc,
        \\{
        \\  "port": 18211,
        \\  "providers": [
        \\    {
        \\      "display_name": "OC Stub",
        \\      "base_url": "http://127.0.0.1:18311/oc/v1/",
        \\      "prefix": "oc/",
        \\      "description": "e2e stub",
        \\      "keys": [{ "key": "KEY-ONE" }, { "key": "KEY-TWO" }],
        \\      "headers": []
        \\    }
        \\  ],
        \\  "auto_start": false,
        \\  "cooldown_secs": 60,
        \\  "timeout_ms": 30000
        \\}
    );
    defer cfg.deinit(alloc);
    var proxy = Proxy.init(alloc, &cfg, .{});
    try proxy.start();
    defer proxy.stop();

    const resp = try postJson(
        alloc,
        18211,
        "/v1/chat/completions",
        "{\"model\":\"oc/magic-model\",\"messages\":[],\"stream\":false}",
    );
    defer alloc.free(resp);

    // Client sees success even though the first key burned.
    try std.testing.expectEqual(@as(u16, 200), try respStatus(resp));
    try std.testing.expect(std.mem.indexOf(u8, respBody(resp), "chatcmpl-e2e") != null);

    // Upstream saw exactly two attempts with distinct bearer keys ...
    try std.testing.expectEqual(@as(usize, 2), stub.post_requests.load(.seq_cst));
    var abuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Bearer KEY-ONE", stub.authAt(0, &abuf));
    try std.testing.expectEqualStrings("Bearer KEY-TWO", stub.authAt(1, &abuf));

    // ... both carrying the prefix-stripped model on the joined endpoint ...
    var mbuf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("magic-model", stub.lastModel(&mbuf));
    var tbuf: [256]u8 = undefined;
    try std.testing.expect(std.mem.eql(u8, "/oc/v1/chat/completions", stub.lastTarget(&tbuf)));

    // ... and the burned key cooled down while the good key stayed active.
    try expectStateName(cfg.providers[0].keys[0].state, "CoolingDown");
    try expectStateName(cfg.providers[0].keys[1].state, "Active");
}

test "e2e: kilo/ prefix routes to its stub with prefix stripped on both completion endpoints" {
    const alloc = std.testing.allocator;

    var stub = StubUpstream.init(18312, .{});
    const stub_thread = try std.Thread.spawn(.{}, StubUpstream.run, .{&stub});
    defer {
        stub.stop();
        stub_thread.join();
    }
    {
        const s = try connectLoopback(18312);
        s.close();
    }

    var cfg: ProxyConfig = try parseTestConfig(alloc,
        \\{
        \\  "port": 18212,
        \\  "providers": [
        \\    {
        \\      "display_name": "Kilo Stub",
        \\      "base_url": "http://127.0.0.1:18312/gw",
        \\      "prefix": "kilo/",
        \\      "description": "e2e stub",
        \\      "keys": [{ "key": "KILO-KEY" }],
        \\      "headers": []
        \\    }
        \\  ],
        \\  "auto_start": false,
        \\  "cooldown_secs": 60,
        \\  "timeout_ms": 30000
        \\}
    );
    defer cfg.deinit(alloc);
    var proxy = Proxy.init(alloc, &cfg, .{});
    try proxy.start();
    defer proxy.stop();

    const chat = try postJson(
        alloc,
        18212,
        "/v1/chat/completions",
        "{\"model\":\"kilo/llama-3.3\",\"messages\":[]}",
    );
    defer alloc.free(chat);
    try std.testing.expectEqual(@as(u16, 200), try respStatus(chat));

    var tbuf: [256]u8 = undefined;
    try std.testing.expect(std.mem.eql(u8, "/gw/chat/completions", stub.lastTarget(&tbuf)));

    const plain = try postJson(
        alloc,
        18212,
        "/v1/completions",
        "{\"model\":\"kilo/llama-3.3\",\"prompt\":\"hi\"}",
    );
    defer alloc.free(plain);
    try std.testing.expectEqual(@as(u16, 200), try respStatus(plain));
    try std.testing.expect(std.mem.eql(u8, "/gw/completions", stub.lastTarget(&tbuf)));

    try std.testing.expectEqual(@as(usize, 2), stub.post_requests.load(.seq_cst));
    var mbuf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("llama-3.3", stub.lastModel(&mbuf));
    var abuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Bearer KILO-KEY", stub.authAt(1, &abuf));
}

test "e2e: GET /v1/models merges stub catalogs with oc/ and kilo/ prefixes" {
    const alloc = std.testing.allocator;

    var stub_oc = StubUpstream.init(18313, .{
        .models_body = "{\"object\":\"list\",\"data\":[{\"id\":\"gpt-4o\",\"object\":\"model\"},{\"id\":\"deepseek-r1\"}]}",
    });
    const thread_oc = try std.Thread.spawn(.{}, StubUpstream.run, .{&stub_oc});
    defer {
        stub_oc.stop();
        thread_oc.join();
    }
    var stub_kilo = StubUpstream.init(18314, .{
        .models_body = "{\"data\":[{\"id\":\"llama-3.3\"}]}",
    });
    const thread_kilo = try std.Thread.spawn(.{}, StubUpstream.run, .{&stub_kilo});
    defer {
        stub_kilo.stop();
        thread_kilo.join();
    }
    {
        const a = try connectLoopback(18313);
        a.close();
        const b = try connectLoopback(18314);
        b.close();
    }

    var cfg: ProxyConfig = try parseTestConfig(alloc,
        \\{
        \\  "port": 18213,
        \\  "providers": [
        \\    {
        \\      "display_name": "OC Stub",
        \\      "base_url": "http://127.0.0.1:18313/oc/v1/",
        \\      "prefix": "oc/",
        \\      "description": "e2e stub",
        \\      "keys": [{ "key": "A-KEY" }],
        \\      "headers": []
        \\    },
        \\    {
        \\      "display_name": "Kilo Stub",
        \\      "base_url": "http://127.0.0.1:18314/gw",
        \\      "prefix": "kilo/",
        \\      "description": "e2e stub",
        \\      "keys": [{ "key": "B-KEY" }],
        \\      "headers": []
        \\    }
        \\  ],
        \\  "auto_start": false,
        \\  "cooldown_secs": 60,
        \\  "timeout_ms": 30000
        \\}
    );
    defer cfg.deinit(alloc);
    var proxy = Proxy.init(alloc, &cfg, .{});
    try proxy.start();
    defer proxy.stop();

    const resp = try getPath(alloc, 18213, "/v1/models");
    defer alloc.free(resp);
    try std.testing.expectEqual(@as(u16, 200), try respStatus(resp));

    const body = respBody(resp);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"object\":\"list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":\"oc/gpt-4o\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":\"oc/deepseek-r1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":\"kilo/llama-3.3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"owned_by\":\"OC Stub\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"owned_by\":\"Kilo Stub\"") != null);

    // Each stub served exactly one GET against its models endpoint, authed.
    try std.testing.expectEqual(@as(usize, 1), stub_oc.total_requests.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), stub_kilo.total_requests.load(.seq_cst));
    var mbuf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("GET", stub_oc.lastMethod(&mbuf));
    try std.testing.expectEqualStrings("GET", stub_kilo.lastMethod(&mbuf));
    var tbuf: [256]u8 = undefined;
    try std.testing.expect(std.mem.eql(u8, "/oc/v1/models", stub_oc.lastTarget(&tbuf)));
    try std.testing.expect(std.mem.eql(u8, "/gw/models", stub_kilo.lastTarget(&tbuf)));
    var abuf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Bearer A-KEY", stub_oc.authAt(0, &abuf));
    try std.testing.expectEqualStrings("Bearer B-KEY", stub_kilo.authAt(0, &abuf));
}

//! Blocking Winsock transport for freepro on Windows.
//!
//! Why this exists: Zig 0.16's `std.Io.net` Windows backend drives sockets
//! through overlapped AFD ioctls with APC waits. In practice (0.16.0) that
//! path misbehaves for a multithreaded loopback server: connections accepted
//! while client bytes are already queued yield sockets whose first RECEIVE
//! never completes (or fails spuriously), hanging workers forever. Plain
//! blocking Winsock calls have no APC/quirk surface and work identically on
//! every thread, so the proxy listener and its accepted connections use them
//! here. The upstream forwarder (`std.http.Client`) and the pool machinery
//! keep using `std.Io` — those paths are verified working.
//!
//! Non-Windows builds do not use this file at all: proxy.zig selects
//! `std.Io.net` there, which shares the type and method names below so the
//! proxy code compiles unchanged on every OS.
//!
//! Threading: all calls are blocking syscalls with per-call stack buffers;
//! no shared mutable state except a process-lifetime WSAStartup once-flag.
//! Any thread (pool workers included) may call into this module.

const std = @import("std");
const builtin = @import("builtin");

/// Zig's 16 MiB Windows default is far more than these loops need; see
/// models.thread_stack_size.
const thread_stack_size: usize = 2 * 1024 * 1024;

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("netwin.zig is Windows-only; other platforms use std.Io.net");
    }
}

const windows = std.os.windows;
const ws2 = windows.ws2_32;
const Io = std.Io;

const SOCKET = usize;
const INVALID_SOCKET: SOCKET = ~@as(SOCKET, 0);

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

// Free-function wrappers so the same verbs can also be method names below.
fn wsListen(s: SOCKET, backlog: c_int) c_int {
    return listen(s, backlog);
}

fn wsAccept(s: SOCKET) SOCKET {
    return accept(s, null, null);
}

fn wsConnect(s: SOCKET, addr: *const SockAddrIn) c_int {
    return connect(s, addr, @sizeOf(SockAddrIn));
}

fn wsShutdown(s: SOCKET, how: c_int) c_int {
    return shutdown(s, how);
}

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

const AF_INET: u16 = 2;
const SOCK_STREAM: c_int = 1;
const IPPROTO_TCP: c_int = 6;
const SOL_SOCKET: c_int = 0xffff;
const SO_REUSEADDR: c_int = 0x0004;

var wsa_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn ensureWsa() void {
    // WSAStartup is refcounted and thread-safe; calling it more than once
    // is harmless, so a racy once-flag is sufficient (no teardown: the
    // sockets outlive any scope that could call WSACleanup safely).
    if (!wsa_ready.swap(true, .seq_cst)) {
        var data: WSADATA = undefined;
        _ = WSAStartup(0x0202, &data);
    }
}

fn loopbackAddr(port: u16) SockAddrIn {
    return .{
        .sin_family = AF_INET,
        .sin_port = std.mem.nativeToBig(u16, port),
        .sin_addr = 0x0100007F, // 127.0.0.1, already network order
        .sin_zero = [_]u8{0} ** 8,
    };
}

fn openStream() !SOCKET {
    ensureWsa();
    const s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return error.SocketCreateFailed;
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

/// IPv4 loopback address. Wraps `std.Io.net.IpAddress` for validation and
/// exposes the same `listen`/`connect` surface the proxy uses, so call sites
/// are identical on every OS.
pub const IpAddress = struct {
    inner: std.Io.net.IpAddress,

    pub fn parseIp4(s: []const u8, port: u16) !IpAddress {
        return .{ .inner = try std.Io.net.IpAddress.parseIp4(s, port) };
    }

    pub fn listen(self: IpAddress, io: Io, opts: ListenOptions) !Server {
        _ = io;
        const s = try openStream();
        errdefer _ = closesocket(s);
        if (opts.reuse_address) {
            const one: u32 = 1;
            _ = setsockopt(s, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&one), @sizeOf(u32));
        }
        const ip4 = self.inner.ip4;
        const sa = SockAddrIn{
            .sin_family = AF_INET,
            .sin_port = std.mem.nativeToBig(u16, ip4.port),
            .sin_addr = @as(u32, @bitCast(ip4.bytes)),
            .sin_zero = [_]u8{0} ** 8,
        };
        if (bind(s, &sa, @sizeOf(SockAddrIn)) != 0) return error.BindFailed;
        if (wsListen(s, 128) != 0) return error.ListenFailed;
        return .{ .sock = s };
    }

    pub fn connect(self: IpAddress, io: Io, opts: ConnectOptions) !Stream {
        _ = io;
        _ = opts;
        const s = try openStream();
        errdefer _ = closesocket(s);
        const ip4 = self.inner.ip4;
        var sa = SockAddrIn{
            .sin_family = AF_INET,
            .sin_port = std.mem.nativeToBig(u16, ip4.port),
            .sin_addr = @as(u32, @bitCast(ip4.bytes)),
            .sin_zero = [_]u8{0} ** 8,
        };
        if (wsConnect(s, &sa) != 0) return error.ConnectFailed;
        return .{ .sock = s };
    }
};

pub const ListenOptions = struct {
    reuse_address: bool = false,
};

pub const ConnectOptions = struct {
    mode: std.Io.net.Socket.Mode = .stream,
};

pub const Server = struct {
    sock: SOCKET,

    pub const AcceptError = error{
        AcceptFailed,
        ServerClosed,
        OutOfMemory,
    };

    pub fn accept(s: *Server, io: Io) AcceptError!Stream {
        _ = io;
        if (s.sock == INVALID_SOCKET) return error.ServerClosed;
        const c = wsAccept(s.sock);
        if (c == INVALID_SOCKET) return error.AcceptFailed;
        return .{ .sock = c };
    }

    pub fn deinit(s: *Server, io: Io) void {
        _ = io;
        if (s.sock != INVALID_SOCKET) {
            _ = closesocket(s.sock);
            s.sock = INVALID_SOCKET;
        }
        s.* = undefined;
    }
};

pub const Stream = struct {
    sock: SOCKET,

    pub fn reader(s: Stream, io: Io, buffer: []u8) Reader {
        _ = io;
        return .{
            .sock = s.sock,
            .interface = .{
                .vtable = &.{ .stream = Reader.streamImpl, .readVec = Reader.readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .err = null,
        };
    }

    pub fn writer(s: Stream, io: Io, buffer: []u8) Writer {
        _ = io;
        return .{
            .sock = s.sock,
            .interface = .{
                .vtable = &.{ .drain = Writer.drain, .sendFile = Writer.sendFile },
                .buffer = buffer,
            },
            .err = null,
        };
    }

    /// Winsock calls are blocking and do not observe std.Io cancellation.
    /// OS deadlines are required even when the caller also races an Io timer.
    pub fn setTimeouts(s: Stream, receive_ms: u32, send_ms: u32) !void {
        if (setsockopt(s.sock, SOL_SOCKET, ws2.SO.RCVTIMEO, @ptrCast(&receive_ms), @sizeOf(u32)) != 0 or
            setsockopt(s.sock, SOL_SOCKET, ws2.SO.SNDTIMEO, @ptrCast(&send_ms), @sizeOf(u32)) != 0)
            return error.SocketTimeoutSetupFailed;
    }

    pub fn shutdown(s: *const Stream, io: Io, how: Io.net.ShutdownHow) !void {
        _ = io;
        const direction: c_int = switch (how) {
            .recv => 0,
            .send => 1,
            .both => 2,
        };
        if (wsShutdown(s.sock, direction) != 0) return error.SocketShutdownFailed;
    }

    pub fn close(s: *const Stream, io: Io) void {
        _ = io;
        if (s.sock != INVALID_SOCKET) {
            _ = closesocket(s.sock);
        }
    }
};

pub const Reader = struct {
    sock: SOCKET,
    interface: Io.Reader,
    err: ?anyerror,

    fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", io_r));
        for (data) |buf| {
            if (buf.len == 0) continue;
            const chunk = @min(buf.len, std.math.maxInt(c_int));
            const n = recv(r.sock, buf.ptr, @as(c_int, @intCast(chunk)), 0);
            if (n > 0) return @as(usize, @intCast(n));
            if (n == 0) return error.EndOfStream;
            return error.ReadFailed;
        }
        return 0;
    }
};

/// Read one available chunk into `dest`, returning as soon as ANY bytes are
/// in hand (never blocking to fill `dest`). Buffered bytes are consumed
/// first. Returns 0 only at clean EOF. This is the primitive the proxy's
/// HTTP framing and SSE relay need; `std.Io.Reader.readSliceShort` fills its
/// whole destination buffer and only short-reads at EOF, which deadlocks a
/// request/response loop (the peer waits for our reply while we wait for the
/// peer's next bytes).
pub fn readAvailable(r: *Reader, dest: []u8) !usize {
    const io_r = &r.interface;
    const contents = io_r.buffer[io_r.seek..io_r.end];
    if (contents.len != 0) {
        const copy_len = @min(contents.len, dest.len);
        @memcpy(dest[0..copy_len], contents[0..copy_len]);
        io_r.seek += copy_len;
        return copy_len;
    }
    var data = [1][]u8{dest};
    const n = Reader.readVec(io_r, &data) catch |err| switch (err) {
        error.EndOfStream => return 0,
        else => return err,
    };
    // Bytes landed directly in `dest`; keep the internal buffer empty.
    io_r.seek = 0;
    io_r.end = 0;
    return n;
}

pub const Writer = struct {
    sock: SOCKET,
    interface: Io.Writer,
    err: ?anyerror,

    fn sendFile(io_w: *Io.Writer, file_reader: *Io.File.Reader, limit: Io.Limit) Io.Writer.FileError!usize {
        _ = io_w;
        _ = file_reader;
        _ = limit;
        return error.Unimplemented; // TODO
    }

    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", io_w));
        var total: usize = 0;
        const buffered = io_w.buffered();
        sendAll(w.sock, buffered) catch return error.WriteFailed;
        total += buffered.len;
        if (data.len > 0) {
            for (data[0 .. data.len - 1]) |buf| {
                sendAll(w.sock, buf) catch return error.WriteFailed;
                total += buf.len;
            }
            const pattern = data[data.len - 1];
            var i: usize = 0;
            while (i < splat) : (i += 1) {
                sendAll(w.sock, pattern) catch return error.WriteFailed;
                total += pattern.len;
            }
        }
        return io_w.consume(total);
    }
};

test "winsock loopback roundtrip" {
    const t = std.testing;
    const addr = try IpAddress.parseIp4("127.0.0.1", 17205);
    var server = try addr.listen(std.testing.io, .{ .reuse_address = true });
    defer server.deinit(std.testing.io);

    const T = struct {
        fn run(srv: *Server) void {
            var conn = srv.accept(std.testing.io) catch return;
            defer conn.close(std.testing.io);
            var rbuf: [1024]u8 = undefined;
            var rd = conn.reader(std.testing.io, &rbuf);
            var tmp: [256]u8 = undefined;
            const n = readAvailable(&rd, &tmp) catch 0;
            if (n != 11) return;
            var wbuf: [1024]u8 = undefined;
            var wr = conn.writer(std.testing.io, &wbuf);
            wr.interface.writeAll("hello-back!") catch return;
            wr.interface.flush() catch return;
        }
    };
    const th = try std.Thread.spawn(.{ .stack_size = thread_stack_size }, T.run, .{&server});

    var cli = try addr.connect(std.testing.io, .{});
    defer cli.close(std.testing.io);
    var wbuf: [1024]u8 = undefined;
    var wr = cli.writer(std.testing.io, &wbuf);
    try wr.interface.writeAll("hello-srv!!");
    try wr.interface.flush();
    var rbuf: [1024]u8 = undefined;
    var rd = cli.reader(std.testing.io, &rbuf);
    var out: [32]u8 = undefined;
    const n = try readAvailable(&rd, &out);
    th.join();
    try t.expectEqualStrings("hello-back!", out[0..n]);
}

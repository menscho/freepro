// src/logger.zig — thread-safe ring-buffer log for the Live Request Console.
//
// std only (no httpz/DVUI dependency). The proxy pushes lines from worker
// threads; the UI polls via Subscriber or latest()/drainSince(). Messages live
// in fixed-size inline buffers so logging never allocates and never fails.
//
// Integration: main.zig owns one `Logger` (or uses `Logger.global`) and hands
// `*Logger` to the proxy/rotator; the UI holds a `Subscriber` cursor.

const std = @import("std");
const builtin = @import("builtin");

pub const capacity: usize = 512;
pub const max_msg_len: usize = 256;

pub const Level = enum {
    info,
    request,
    failover,
    warn,
    err,

    pub fn tag(self: Level) []const u8 {
        return switch (self) {
            .info => "INFO",
            .request => "REQ",
            .failover => "FAILOVER",
            .warn => "WARN",
            .err => "ERROR",
        };
    }
};

pub const LogLine = struct {
    seq: u64,
    timestamp_ms: i64,
    level: Level,
    len: usize,
    msg: [max_msg_len]u8,

    pub fn text(self: *const LogLine) []const u8 {
        return self.msg[0..self.len];
    }
};

/// Mutual exclusion for the ring buffer. Prefers the blocking OS mutex where
/// the standard library provides one (`std.Thread.Mutex` on Zig <= 0.15) and
/// falls back to a yield-spinning lock on toolchains that removed it (0.16
/// only ships the `std.atomic.Mutex` spinlock). Critical sections are tiny
/// and never block on I/O while held, so a spin is only ever brief.
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

/// Wall-clock time in unix milliseconds for log-line timestamps.
/// `std.time.milliTimestamp` where present (Zig <= 0.15), else a direct OS
/// read (Windows `RtlGetSystemTimePrecise`, otherwise libc `clock_gettime`)
/// so the logger stays Io-free and its API keeps no Io parameter.
/// Seconds since epoch from libc clock_gettime (POSIX only; Windows uses
/// RtlGetSystemTimePrecise above). Zig 0.16 spells the timespec fields
/// `sec`/`nsec` on every libc.
fn posixRealtimeSec() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return ts.sec;
}

fn posixRealtimeMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divFloor(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn realtimeMillis() i64 {
    if (@hasDecl(std.time, "milliTimestamp")) {
        return std.time.milliTimestamp();
    }
    if (builtin.os.tag == .windows) {
        // 100ns ticks since 1601-01-01; 11_644_473_600_000ms = 1601 -> 1970.
        const ticks_100ns: i64 = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        return @divFloor(ticks_100ns, 10_000) - 11_644_473_600_000;
    }
    return posixRealtimeMs();
}

pub const Logger = struct {
    mu: Mutex,
    buf: [capacity]LogLine,
    head: usize,
    count: usize,
    next_seq: u64,

    pub fn init() Logger {
        return .{
            .mu = .{},
            .buf = [_]LogLine{.{
                .seq = 0,
                .timestamp_ms = 0,
                .level = .info,
                .len = 0,
                .msg = [_]u8{0} ** max_msg_len,
            }} ** capacity,
            .head = 0,
            .count = 0,
            .next_seq = 0,
        };
    }

    /// Optional shared instance for apps that prefer a global over plumbing.
    pub var global: Logger = Logger.init();

    /// Core append. Truncates messages longer than max_msg_len.
    pub fn push(self: *Logger, level: Level, comptime fmt: []const u8, args: anytype) void {
        var tmp: [max_msg_len]u8 = undefined;
        const line = std.fmt.bufPrint(&tmp, fmt, args) catch tmp[0..];
        const clipped = line[0..@min(line.len, max_msg_len)];

        self.mu.lock();
        defer self.mu.unlock();
        const slot = &self.buf[self.head];
        slot.seq = self.next_seq;
        slot.timestamp_ms = realtimeMillis();
        slot.level = level;
        slot.len = clipped.len;
        @memcpy(slot.msg[0..clipped.len], clipped);
        self.next_seq += 1;
        self.head = (self.head + 1) % capacity;
        if (self.count < capacity) self.count += 1;
    }

    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.push(.info, fmt, args);
    }

    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.push(.warn, fmt, args);
    }

    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.push(.err, fmt, args);
    }

    /// Exact wire format the console shows on rotation:
    /// `[FAILOVER] Key #N hit 429 -> Rotating to Key #M` (1-based key numbers).
    pub fn failover(self: *Logger, from_key_1based: usize, status: u16, to_key_1based: usize) void {
        self.push(.failover, "[FAILOVER] Key #{d} hit {d} -> Rotating to Key #{d}", .{ from_key_1based, status, to_key_1based });
    }

    /// One line per proxied client call, e.g. `POST /v1/chat/completions -> 200 (42ms)`.
    pub fn logRequest(self: *Logger, method: []const u8, path: []const u8, status: u16, latency_ms: u64) void {
        self.push(.request, "{s} {s} -> {d} ({d}ms)", .{ method, path, status, latency_ms });
    }

    pub fn len(self: *Logger) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.count;
    }

    /// Copy the newest `out.len` (or fewer) lines, oldest first. Returns lines written.
    pub fn latest(self: *Logger, out: []LogLine) usize {
        self.mu.lock();
        defer self.mu.unlock();
        const n = @min(out.len, self.count);
        const start = self.count - n;
        for (0..n) |i| {
            out[i] = self.buf[(self.head + capacity - self.count + start + i) % capacity];
        }
        return n;
    }

    /// Copy lines with seq > cursor.*, oldest first, advancing the cursor.
    /// UI polls this each frame. Returns lines written.
    pub fn drainSince(self: *Logger, cursor: *u64, out: []LogLine) usize {
        self.mu.lock();
        defer self.mu.unlock();
        const newest_seq = self.next_seq;
        const oldest_seq: u64 = if (newest_seq > self.count) newest_seq - self.count else 0;
        if (cursor.* < oldest_seq) cursor.* = oldest_seq; // entries overwritten; skip gap
        var n: usize = 0;
        var s = cursor.*;
        while (s < newest_seq and n < out.len) : (s += 1) {
            out[n] = self.buf[(self.head + capacity - self.count + @as(usize, @intCast(s - oldest_seq))) % capacity];
            n += 1;
        }
        cursor.* = s;
        return n;
    }

    pub fn subscriber(self: *Logger) Subscriber {
        return .{ .logger = self, .cursor = 0 };
    }
};

/// UI-side cursor over a Logger. Poll each frame with poll().
pub const Subscriber = struct {
    logger: *Logger,
    cursor: u64,

    /// Copy newly arrived lines into `out`, oldest first. Returns lines written.
    pub fn poll(self: *Subscriber, out: []LogLine) usize {
        return self.logger.drainSince(&self.cursor, out);
    }

    /// Start from the current tail, ignoring backlog (e.g. on view open).
    pub fn skipBacklog(self: *Subscriber) void {
        const l = self.logger;
        l.mu.lock();
        defer l.mu.unlock();
        self.cursor = l.next_seq;
    }
};

/// Format a millisecond epoch timestamp as `HH:MM:SS` (local time) for console display.
pub fn formatTimeOfDay(timestamp_ms: i64, out: *[8]u8) []const u8 {
    const secs = std.time.epoch.EpochSeconds{ .secs = @intCast(@divFloor(timestamp_ms, 1000)) };
    const day = secs.getDaySeconds();
    const h: u8 = day.getHoursIntoDay();
    const m: u8 = day.getMinutesIntoHour();
    const s: u8 = day.getSecondsIntoMinute();
    return std.fmt.bufPrint(out, "{d:0>2}:{d:0>2}:{d:0>2}", .{ h, m, s }) catch out[0..0];
}

test "logger failover format + request line + subscriber" {
    var l = Logger.init();
    l.failover(2, 429, 3);
    l.logRequest("POST", "/v1/chat/completions", 200, 42);

    var lines: [4]LogLine = undefined;
    const n = l.latest(&lines);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("[FAILOVER] Key #2 hit 429 -> Rotating to Key #3", lines[0].text());
    try std.testing.expectEqual(Level.failover, lines[0].level);
    try std.testing.expectEqualStrings("POST /v1/chat/completions -> 200 (42ms)", lines[1].text());
    try std.testing.expectEqual(Level.request, lines[1].level);

    var sub = l.subscriber();
    var got: [4]LogLine = undefined;
    try std.testing.expectEqual(@as(usize, 2), sub.poll(&got));
    try std.testing.expectEqual(@as(usize, 0), sub.poll(&got)); // nothing new
    l.info("hello {s}", .{"world"});
    try std.testing.expectEqual(@as(usize, 1), sub.poll(&got));
    try std.testing.expectEqualStrings("hello world", got[0].text());
}

test "logger ring overwrites oldest" {
    var l = Logger.init();
    var i: usize = 0;
    while (i < capacity + 5) : (i += 1) {
        l.info("msg {d}", .{i});
    }
    try std.testing.expectEqual(capacity, l.len());
    var lines: [capacity]LogLine = undefined;
    const n = l.latest(&lines);
    try std.testing.expectEqual(capacity, n);
    try std.testing.expectEqualStrings("msg 5", lines[0].text()); // first 5 evicted
}

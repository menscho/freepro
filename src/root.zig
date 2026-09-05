//! freepro library root: single index over all internal modules.
//!
//! The `test` build step compiles this file, so every module listed here is
//! type-checked (and its embedded tests executed) on `zig build test`.
//! Modules import each other with relative paths (`@import("models.zig")`);
//! this index mirrors that convention instead of the named build modules.

const std = @import("std");
const builtin = @import("builtin");

pub const models = @import("models.zig");
pub const rotator = @import("rotator.zig");
pub const config = @import("config.zig");
pub const freeproxy = @import("freeproxy.zig");
pub const proxy = @import("proxy.zig");
pub const upstream = @import("upstream.zig");
pub const metrics = @import("metrics.zig");
pub const logger = @import("logger.zig");
pub const netwin = if (builtin.os.tag == .windows) @import("netwin.zig") else struct {};
pub const ui = @import("ui.zig");

pub const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 12 };

test {
    std.testing.refAllDecls(@This());
}

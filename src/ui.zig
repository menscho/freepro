//! freepro UI index: single entry point over every view module in src/ui/.
//!
//! The `test` build step compiles this file, so each view listed here is
//! type-checked (and its embedded tests executed) on `zig build test`.
//! Sibling sources import each other with relative paths
//! (`@import("ui/app.zig")` from src/, `@import("../models.zig")` from
//! inside src/ui/); this index mirrors that convention instead of named
//! build modules.

pub const app = @import("ui/app.zig");
pub const views_dashboard = @import("ui/views_dashboard.zig");
pub const views_models_console = @import("ui/views_models_console.zig");
pub const views_providers = @import("ui/views_providers.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}

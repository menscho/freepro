// src/models.zig
//
// freepro data-model layer (Wave 1, Task 02).
//
// std-only module: no httpz / DVUI / GUI dependency is required by this
// file. If the proxy or UI layers later need third-party packages, those
// dependencies belong in build.zig and in src/proxy.zig / src/ui/*, not here.
//
// Ownership contract (explicit allocator ownership):
//   * Every []const u8 field on Key / CustomHeader / Provider, and every
//     []Key / []CustomHeader / []Provider slice, is heap-owned.
//   * `clone(allocator)` performs a deep copy; the caller owns the result
//     and must call `deinit(allocator)` exactly once.
//   * `deinit(allocator)` frees all owned memory. Do not use the value after.
//   * `fromJson(allocator, text)` returns a fully independent copy; the
//     input slice is only borrowed during the call.
//   * Other agents import this file with `@import("models.zig")` using a
//     relative path (e.g. from src/rotator.zig or src/proxy.zig).

const std = @import("std");

const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// Defaults and preset constants (from plan.md section 3.C)
// ---------------------------------------------------------------------------

pub const default_port: u16 = 8080;
pub const default_cooldown_secs: u64 = 60;
pub const default_timeout_ms: u32 = 30_000;

pub const opencode_display_name: []const u8 = "OpenCode Zen";
pub const opencode_base_url: []const u8 = "https://opencode.ai/zen/v1/";
pub const opencode_prefix: []const u8 = "oc/";
pub const opencode_description: []const u8 = "Free tier endpoints via OpenCode Zen gateway.";
pub const opencode_note: []const u8 = "Limited Daily Usage 20-100m tokens, No creditcard needed, Daily Limit is IP-bound.";
pub const opencode_site_url: []const u8 = "https://opencode.ai";

pub const kilo_display_name: []const u8 = "Kilo Gateway";
pub const kilo_base_url: []const u8 = "https://api.kilo.ai/api/gateway";
pub const kilo_prefix: []const u8 = "kilo/";
pub const kilo_description: []const u8 = "High-throughput community gateway.";
pub const kilo_note: []const u8 = "Infinite Daily Usage, No creditcard needed.";
pub const kilo_site_url: []const u8 = "https://kilo.ai";

pub const bai_display_name: []const u8 = "b.ai";
pub const bai_base_url: []const u8 = "https://api.b.ai/v1";
pub const bai_prefix: []const u8 = "b/";
pub const bai_description: []const u8 = "b.ai gateway.";
pub const bai_note: []const u8 = "Infinite Daily Usage, No creditcard needed.";
pub const bai_site_url: []const u8 = "https://b.ai";

pub const tokenrouter_display_name: []const u8 = "TokenRouter";
pub const tokenrouter_base_url: []const u8 = "https://api.tokenrouter.com/v1";
pub const tokenrouter_prefix: []const u8 = "tr/";
pub const tokenrouter_description: []const u8 = "TokenRouter gateway.";
pub const tokenrouter_note: []const u8 = "Infinite Daily Usage, slow tps.";
pub const tokenrouter_site_url: []const u8 = "https://tokenrouter.com";

pub const cline_display_name: []const u8 = "Cline";
pub const cline_base_url: []const u8 = "https://api.cline.bot/api/v1";
pub const cline_prefix: []const u8 = "cline/";
pub const cline_description: []const u8 = "Cline gateway.";
pub const cline_note: []const u8 = "Limited Daily Usage 20-50m tokens depending on the model, Daily Limit is Account-bound.";
pub const cline_site_url: []const u8 = "https://cline.bot";

pub const nous_display_name: []const u8 = "Nous Research";
pub const nous_base_url: []const u8 = "https://inference-api.nousresearch.com/v1";
pub const nous_prefix: []const u8 = "nous/";
pub const nous_description: []const u8 = "Nous Research inference gateway.";
pub const nous_note: []const u8 = "Infinite Daily Usage, Creditcard needed.";
pub const nous_site_url: []const u8 = "https://portal.nousresearch.com";

/// Lookup helpers for the preset notes/site URLs, keyed by provider prefix.
pub fn noteForPrefix(prefix: []const u8) []const u8 {
    if (std.mem.eql(u8, prefix, opencode_prefix)) return opencode_note;
    if (std.mem.eql(u8, prefix, kilo_prefix)) return kilo_note;
    if (std.mem.eql(u8, prefix, bai_prefix)) return bai_note;
    if (std.mem.eql(u8, prefix, tokenrouter_prefix)) return tokenrouter_note;
    if (std.mem.eql(u8, prefix, cline_prefix)) return cline_note;
    if (std.mem.eql(u8, prefix, nous_prefix)) return nous_note;
    return "";
}

pub fn siteUrlForPrefix(prefix: []const u8) []const u8 {
    if (std.mem.eql(u8, prefix, opencode_prefix)) return opencode_site_url;
    if (std.mem.eql(u8, prefix, kilo_prefix)) return kilo_site_url;
    if (std.mem.eql(u8, prefix, bai_prefix)) return bai_site_url;
    if (std.mem.eql(u8, prefix, tokenrouter_prefix)) return tokenrouter_site_url;
    if (std.mem.eql(u8, prefix, cline_prefix)) return cline_site_url;
    if (std.mem.eql(u8, prefix, nous_prefix)) return nous_site_url;
    return "";
}

/// Default reasoning effort levels offered when the upstream catalog does
/// not document them (plan.md free-tier dashboard contract).
// Operator-selected defaults; per-model edits remain supported.
pub const default_reasoning_levels = "low,medium,high,xhigh,max";
pub fn isLegacyReasoningLevels(levels: []const u8) bool {
    return std.mem.eql(u8, levels, "max,xhigh,high,low,none") or
        std.mem.eql(u8, levels, "max,high,low,none");
}

/// The four seeded b.ai free models with their documented context windows.
pub const BaiSeedModel = struct {
    id: []const u8,
    context_window: u64,
};
pub const bai_seed_models = [_]BaiSeedModel{
    .{ .id = "hy3", .context_window = 1_000_000 },
    .{ .id = "mimo-v2.5", .context_window = 262_144 },
    .{ .id = "glm-5.3-flash", .context_window = 1_000_000 },
    .{ .id = "qwen3.8-flash", .context_window = 1_000_000 },
};

// ---------------------------------------------------------------------------
// Validation error set shared by all validate() helpers
// ---------------------------------------------------------------------------

pub const ValidateError = error{
    EmptyKeyMaterial,
    EmptyDisplayName,
    InvalidBaseUrl,
    EmptyPrefix,
    PrefixMissingTrailingSlash,
    DuplicatePrefix,
    DuplicateKeyMaterial,
    EmptyHeaderName,
    InvalidHeaderName,
    DuplicateHeaderName,
    InvalidPort,
    InvalidCooldown,
    InvalidTimeout,
};

// ---------------------------------------------------------------------------
// KeyState
// ---------------------------------------------------------------------------

/// Rotation / resilience state for a single API key (plan.md section 3.B).
/// Serialized to JSON as its field name ("Active", "CoolingDown", "Dead").
pub const KeyState = enum {
    Active,
    CoolingDown,
    Dead,
};

// ---------------------------------------------------------------------------
// Key
// ---------------------------------------------------------------------------

/// A single upstream API key plus its live rotation bookkeeping.
/// Field names match the shared contract: key / state / last_used /
/// cooldown_until / consecutive_errors / enabled.
pub const Key = struct {
    key: []const u8,
    state: KeyState = .Active,
    last_used: i64 = 0,
    cooldown_until: i64 = 0,
    consecutive_errors: u32 = 0,
    enabled: bool = true,

    /// Borrowed-string constructor (no allocation). The caller keeps
    /// ownership of `key_material`; call `clone` for an owned copy.
    pub fn init(key_material: []const u8) Key {
        return .{ .key = key_material };
    }

    pub fn validate(self: Key) ValidateError!void {
        if (self.key.len == 0) return ValidateError.EmptyKeyMaterial;
    }

    /// True when the rotator may dispatch a request to this key at time
    /// `now_unix` (unix seconds). Pure: never mutates state.
    pub fn isUsable(self: Key, now_unix: i64) bool {
        if (!self.enabled) return false;
        return switch (self.state) {
            .Active => true,
            .CoolingDown => now_unix >= self.cooldown_until,
            .Dead => false,
        };
    }

    /// Promote an expired CoolingDown key back to Active. Returns true when
    /// a transition happened. Dead keys are never auto-promoted.
    pub fn tryPromote(self: *Key, now_unix: i64) bool {
        if (self.state == .CoolingDown and now_unix >= self.cooldown_until) {
            self.state = .Active;
            self.consecutive_errors = 0;
            return true;
        }
        return false;
    }

    /// Record a successful request: clear error counters, stamp last_used.
    pub fn markSuccess(self: *Key, now_unix: i64) void {
        self.state = .Active;
        self.consecutive_errors = 0;
        self.last_used = now_unix;
    }

    /// Record a rate-limit / transient failure: enter CoolingDown.
    pub fn markCooldown(self: *Key, now_unix: i64, cooldown_secs: u64) void {
        self.state = .CoolingDown;
        self.last_used = now_unix;
        self.consecutive_errors +|= 1;
        const delta: i64 = @intCast(cooldown_secs);
        self.cooldown_until = now_unix + delta;
    }

    /// Record an auth / banned failure: permanently Dead until re-enabled.
    pub fn markDead(self: *Key, now_unix: i64) void {
        self.state = .Dead;
        self.last_used = now_unix;
        self.consecutive_errors +|= 1;
    }

    pub fn clone(self: Key, allocator: Allocator) !Key {
        return .{
            .key = try allocator.dupe(u8, self.key),
            .state = self.state,
            .last_used = self.last_used,
            .cooldown_until = self.cooldown_until,
            .consecutive_errors = self.consecutive_errors,
            .enabled = self.enabled,
        };
    }

    pub fn deinit(self: *Key, allocator: Allocator) void {
        allocator.free(self.key);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// CustomHeader
// ---------------------------------------------------------------------------

/// One provider-specific static header injected on every upstream request.
pub const CustomHeader = struct {
    key: []const u8,
    value: []const u8,

    pub fn init(name: []const u8, val: []const u8) CustomHeader {
        return .{ .key = name, .value = val };
    }

    pub fn validate(self: CustomHeader) ValidateError!void {
        if (self.key.len == 0) return ValidateError.EmptyHeaderName;
        for (self.key) |c| {
            if (c == ':' or c <= 0x20 or c == 0x7f) return ValidateError.InvalidHeaderName;
        }
        for (self.value) |c| {
            if (c == '\r' or c == '\n') return ValidateError.InvalidHeaderName;
        }
    }

    pub fn eql(self: CustomHeader, other: CustomHeader) bool {
        return std.mem.eql(u8, self.key, other.key) and
            std.mem.eql(u8, self.value, other.value);
    }

    pub fn clone(self: CustomHeader, allocator: Allocator) !CustomHeader {
        const name = try allocator.dupe(u8, self.key);
        errdefer allocator.free(name);
        const val = try allocator.dupe(u8, self.value);
        return .{ .key = name, .value = val };
    }

    pub fn deinit(self: *CustomHeader, allocator: Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// An upstream LLM gateway: display metadata, routing prefix, key pool and
/// the static headers injected on every forwarded request.
pub const WireApi = enum {
    /// OpenAI Chat Completions (/chat/completions + /completions).
    chat_completions,
    /// OpenAI Responses (/responses); requests/responses are translated.
    openai_responses,
};

pub const Provider = struct {
    display_name: []const u8,
    base_url: []const u8,
    prefix: []const u8,
    description: []const u8,
    keys: []Key,
    headers: []CustomHeader,
    /// Cached model catalog (fetched from the upstream /models endpoint).
    /// Empty until the first successful fetch; /v1/models falls back to a
    /// live fetch while it is empty.
    models: []ModelInfo = &.{},
    /// Short operator-facing usage note shown under the provider name in
    /// the dashboard (limits, signup requirements). Owned.
    note: []const u8 = "",
    /// Provider website shown as a link in the dashboard. Owned.
    site_url: []const u8 = "",
    /// Experimental: route this provider's upstream traffic through the
    /// free public proxy pool. Adds latency and API-key ban risk.
    use_free_proxy: bool = false,
    /// Upstream wire protocol; Zen selects its endpoint per model.
    wire_api: WireApi = .chat_completions,

    pub fn validate(self: Provider) ValidateError!void {
        if (self.display_name.len == 0) return ValidateError.EmptyDisplayName;
        if (!std.mem.startsWith(u8, self.base_url, "http://") and
            !std.mem.startsWith(u8, self.base_url, "https://"))
            return ValidateError.InvalidBaseUrl;
        if (self.prefix.len == 0) return ValidateError.EmptyPrefix;
        if (!std.mem.endsWith(u8, self.prefix, "/")) return ValidateError.PrefixMissingTrailingSlash;

        for (self.headers) |h| try h.validate();
        for (self.keys) |k| try k.validate();

        // No duplicate key material within one provider.
        for (self.keys, 0..) |a, i| {
            for (self.keys[0..i]) |b| {
                if (std.mem.eql(u8, a.key, b.key)) return ValidateError.DuplicateKeyMaterial;
            }
        }
        // No duplicate header names within one provider.
        for (self.headers, 0..) |a, i| {
            for (self.headers[0..i]) |b| {
                if (std.ascii.eqlIgnoreCase(a.key, b.key)) return ValidateError.DuplicateHeaderName;
            }
        }
    }

    /// Number of keys currently in Active state (regardless of `enabled`).
    pub fn activeKeyCount(self: Provider) usize {
        var n: usize = 0;
        for (self.keys) |k| {
            if (k.state == .Active) n += 1;
        }
        return n;
    }

    /// Number of keys the rotator may use right now.
    pub fn usableKeyCount(self: Provider, now_unix: i64) usize {
        var n: usize = 0;
        for (self.keys) |k| {
            if (k.isUsable(now_unix)) n += 1;
        }
        return n;
    }

    /// Look up a static header value by name. Returns null when absent.
    pub fn findHeader(self: Provider, name: []const u8) ?[]const u8 {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.key, name)) return h.value;
        }
        return null;
    }

    /// True when this provider claims the model id (prefix match).
    pub fn claimsModel(self: Provider, model: []const u8) bool {
        return std.mem.startsWith(u8, model, self.prefix);
    }

    /// Strip this provider's prefix. Returns the input unchanged when the
    /// prefix does not match.
    pub fn stripPrefix(self: Provider, model: []const u8) []const u8 {
        if (self.claimsModel(model)) return model[self.prefix.len..];
        return model;
    }

    pub fn clone(self: Provider, allocator: Allocator) !Provider {
        const display_name = try allocator.dupe(u8, self.display_name);
        errdefer allocator.free(display_name);
        const base_url = try allocator.dupe(u8, self.base_url);
        errdefer allocator.free(base_url);
        const prefix = try allocator.dupe(u8, self.prefix);
        errdefer allocator.free(prefix);
        const description = try allocator.dupe(u8, self.description);
        errdefer allocator.free(description);

        const keys = try allocator.alloc(Key, self.keys.len);
        var keys_filled: usize = 0;
        errdefer {
            for (keys[0..keys_filled]) |*k| k.deinit(allocator);
            allocator.free(keys);
        }
        for (self.keys, 0..) |k, i| {
            keys[i] = try k.clone(allocator);
            keys_filled = i + 1;
        }

        const headers = try allocator.alloc(CustomHeader, self.headers.len);
        var headers_filled: usize = 0;
        errdefer {
            for (headers[0..headers_filled]) |*h| h.deinit(allocator);
            allocator.free(headers);
        }
        for (self.headers, 0..) |h, i| {
            headers[i] = try h.clone(allocator);
            headers_filled = i + 1;
        }

        const catalog = try allocator.alloc(ModelInfo, self.models.len);
        var catalog_filled: usize = 0;
        errdefer {
            for (catalog[0..catalog_filled]) |*m| m.deinit(allocator);
            allocator.free(catalog);
        }
        for (self.models, 0..) |m, i| {
            catalog[i] = try m.clone(allocator);
            catalog_filled = i + 1;
        }

        const note = try allocator.dupe(u8, self.note);
        errdefer allocator.free(note);
        const site_url = try allocator.dupe(u8, self.site_url);
        errdefer allocator.free(site_url);
        return .{
            .display_name = display_name,
            .base_url = base_url,
            .prefix = prefix,
            .description = description,
            .keys = keys,
            .headers = headers,
            .models = catalog,
            .note = note,
            .site_url = site_url,
            .use_free_proxy = self.use_free_proxy,
            .wire_api = self.wire_api,
        };
    }

    pub fn deinit(self: *Provider, allocator: Allocator) void {
        for (self.keys) |*k| k.deinit(allocator);
        allocator.free(self.keys);
        for (self.headers) |*h| h.deinit(allocator);
        allocator.free(self.headers);
        for (self.models) |*m| m.deinit(allocator);
        allocator.free(self.models);
        if (self.note.len != 0) allocator.free(self.note);
        if (self.site_url.len != 0) allocator.free(self.site_url);
        allocator.free(self.display_name);
        allocator.free(self.base_url);
        allocator.free(self.prefix);
        allocator.free(self.description);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// ModelInfo: per-model catalog entry (persisted in the config JSON)
// ---------------------------------------------------------------------------

/// One entry of the merged model catalog. Persisted inside the config JSON
/// so enabled/disabled choices survive restarts. All strings heap-owned;
/// released with deinit(). `context_window` mirrors the upstream-reported
/// or documented token limit (0 = unknown).
pub const ModelInfo = struct {
    id: []const u8,
    upstream_id: []const u8,
    provider_name: []const u8,
    provider_prefix: []const u8,
    context_window: u64 = 0,
    enabled: bool = true,
    /// True when the upstream documents reasoning support (e.g. a
    /// "reasoning" / "reasoning_effort" entry in supported_parameters).
    supports_reasoning: bool = false,
    /// Comma-separated reasoning effort levels for this model, e.g.
    /// "max,high,low,none". Owned. Empty = no reasoning exposed.
    reasoning_levels: []const u8 = "",
    /// True when the model is on a free tier. Seeded for the b.ai presets
    /// and for any id ending in "-free" / ":free"; otherwise set by the user.
    free: bool = false,

    pub fn clone(self: ModelInfo, allocator: Allocator) !ModelInfo {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .upstream_id = try allocator.dupe(u8, self.upstream_id),
            .provider_name = try allocator.dupe(u8, self.provider_name),
            .provider_prefix = try allocator.dupe(u8, self.provider_prefix),
            .context_window = self.context_window,
            .enabled = self.enabled,
            .supports_reasoning = self.supports_reasoning,
            .reasoning_levels = try allocator.dupe(u8, self.reasoning_levels),
            .free = self.free,
        };
    }

    pub fn deinit(self: *ModelInfo, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.upstream_id);
        allocator.free(self.provider_name);
        allocator.free(self.provider_prefix);
        if (self.reasoning_levels.len != 0) allocator.free(self.reasoning_levels);
        self.* = undefined;
    }

    pub fn validate(self: ModelInfo) ValidateError!void {
        if (self.id.len == 0) return ValidateError.EmptyPrefix;
        if (self.upstream_id.len == 0) return ValidateError.EmptyPrefix;
        if (self.provider_name.len == 0) return ValidateError.EmptyDisplayName;
        if (self.provider_prefix.len == 0) return ValidateError.EmptyPrefix;
        if (!std.mem.endsWith(u8, self.provider_prefix, "/")) return ValidateError.PrefixMissingTrailingSlash;
    }

    /// True when the model is on a free tier: flagged directly, or the id
    /// ends in "-free" / ":free" (plan.md free tiers).
    pub fn isFree(self: ModelInfo) bool {
        if (self.free) return true;
        return std.mem.endsWith(u8, self.id, "-free") or std.mem.endsWith(u8, self.id, ":free");
    }
};

// ---------------------------------------------------------------------------
// ProxyConfig
// ---------------------------------------------------------------------------

/// One UTC day of aggregated token usage (persisted, last 30 kept).
/// `day` is days since the Unix epoch (floor(now_sec / 86400)).
pub const UsageDay = struct {
    day: u32 = 0,
    input: u64 = 0,
    output: u64 = 0,
    cached: u64 = 0,
    requests: u64 = 0,

    pub fn clone(self: UsageDay, allocator: Allocator) !UsageDay {
        _ = allocator;
        return self;
    }

    pub fn deinit(self: *UsageDay, allocator: Allocator) void {
        _ = allocator;
        self.* = undefined;
    }
};

pub const UsageModel = struct {
    model: []const u8,
    input: u64 = 0,
    output: u64 = 0,
    cached: u64 = 0,
    requests: u64 = 0,
    days: []UsageDay = &.{},

    pub fn clone(self: UsageModel, a: Allocator) !UsageModel {
        const name = try a.dupe(u8, self.model);
        errdefer a.free(name);
        return .{ .model = name, .input = self.input, .output = self.output, .cached = self.cached, .requests = self.requests, .days = try a.dupe(UsageDay, self.days) };
    }
    pub fn deinit(self: *UsageModel, a: Allocator) void {
        a.free(self.model);
        if (self.days.len != 0) a.free(self.days);
    }
};

/// Top-level application configuration, persisted as JSON.
/// Field names match the shared contract: port / providers / auto_start /
/// cooldown_secs / timeout_ms.
pub const ProxyConfig = struct {
    port: u16 = default_port,
    providers: []Provider = &.{},
    auto_start: bool = false,
    cooldown_secs: u64 = default_cooldown_secs,
    timeout_ms: u32 = default_timeout_ms,
    /// Free mode: only models whose id ends in "-free" or ":free" are
    /// exposed via /v1/models; the rest are deactivated and hidden in the
    /// dashboard catalog.
    free_mode: bool = false,
    /// Hide paid models: non-free models are deactivated and hidden from the
    /// dashboard catalog. On by default (free-first dashboard).
    hide_paid: bool = true,
    /// Lifetime token usage totals, persisted so the dashboard survives
    /// restarts. The live counters live in metrics; these are synced on save.
    usage_in: u64 = 0,
    usage_out: u64 = 0,
    usage_cached: u64 = 0,
    usage_requests: u64 = 0,
    usage_days: []UsageDay = &.{},
    usage_models: []UsageModel = &.{},

    pub fn validate(self: ProxyConfig) ValidateError!void {
        if (self.port == 0) return ValidateError.InvalidPort;
        if (self.cooldown_secs == 0 or self.cooldown_secs > 86_400) return ValidateError.InvalidCooldown;
        if (self.timeout_ms == 0 or self.timeout_ms > 600_000) return ValidateError.InvalidTimeout;

        for (self.providers) |p| try p.validate();

        // Provider prefixes must be unique so routing is unambiguous.
        for (self.providers, 0..) |a, i| {
            for (self.providers[0..i]) |b| {
                if (std.mem.eql(u8, a.prefix, b.prefix)) return ValidateError.DuplicatePrefix;
            }
        }
    }

    /// Longest-prefix routing: index of the provider claiming `model`.
    pub fn findProviderForModel(self: ProxyConfig, model: []const u8) ?usize {
        var best: ?usize = null;
        var best_len: usize = 0;
        for (self.providers, 0..) |p, i| {
            if (p.claimsModel(model) and p.prefix.len > best_len) {
                best = i;
                best_len = p.prefix.len;
            }
        }
        return best;
    }

    /// Route a client-facing model id to its provider and upstream name.
    /// Returns null when no provider claims the model.
    pub fn routeModel(self: ProxyConfig, model: []const u8) ?RoutedModel {
        const idx = self.findProviderForModel(model) orelse return null;
        return .{
            .provider_index = idx,
            .upstream_model = self.providers[idx].stripPrefix(model),
        };
    }

    pub fn clone(self: ProxyConfig, allocator: Allocator) !ProxyConfig {
        const providers = try allocator.alloc(Provider, self.providers.len);
        var filled: usize = 0;
        errdefer {
            for (providers[0..filled]) |*p| p.deinit(allocator);
            allocator.free(providers);
        }
        for (self.providers, 0..) |p, i| {
            providers[i] = try p.clone(allocator);
            filled = i + 1;
        }
        const usage_days = try allocator.alloc(UsageDay, self.usage_days.len);
        var days_filled: usize = 0;
        errdefer {
            allocator.free(usage_days[0..days_filled]);
        }
        for (self.usage_days) |d| {
            usage_days[days_filled] = try d.clone(allocator);
            days_filled += 1;
        }
        const usage_models = try allocator.alloc(UsageModel, self.usage_models.len);
        var models_filled: usize = 0;
        errdefer {
            for (usage_models[0..models_filled]) |*m| m.deinit(allocator);
            allocator.free(usage_models);
        }
        for (self.usage_models, 0..) |m, i| {
            usage_models[i] = try m.clone(allocator);
            models_filled += 1;
        }
        return .{
            .port = self.port,
            .providers = providers,
            .auto_start = self.auto_start,
            .cooldown_secs = self.cooldown_secs,
            .timeout_ms = self.timeout_ms,
            .free_mode = self.free_mode,
            .hide_paid = self.hide_paid,
            .usage_in = self.usage_in,
            .usage_out = self.usage_out,
            .usage_cached = self.usage_cached,
            .usage_requests = self.usage_requests,
            .usage_days = usage_days,
            .usage_models = usage_models,
        };
    }

    pub fn deinit(self: *ProxyConfig, allocator: Allocator) void {
        for (self.providers) |*p| p.deinit(allocator);
        allocator.free(self.providers);
        if (self.usage_days.len != 0) allocator.free(self.usage_days);
        for (self.usage_models) |*m| m.deinit(allocator);
        if (self.usage_models.len != 0) allocator.free(self.usage_models);
        self.* = undefined;
    }

    /// Serialize to a pretty-printed JSON document. Caller owns the result.
    /// Uses Stringify.valueAlloc where available (Zig >= 0.14) and falls
    /// back to json.stringifyAlloc on 0.13.x.
    pub fn toJsonAlloc(self: ProxyConfig, allocator: Allocator) ![]u8 {
        if (comptime @hasDecl(std.json.Stringify, "valueAlloc")) {
            return try std.json.Stringify.valueAlloc(allocator, self, .{ .whitespace = .indent_2 });
        } else {
            return try std.json.stringifyAlloc(allocator, self, .{ .whitespace = .indent_2 });
        }
    }

    /// Parse a JSON document into an owned config (see ownership contract).
    pub fn parse(allocator: Allocator, json_text: []const u8) !ProxyConfig {
        const parsed = try std.json.parseFromSlice(
            ProxyConfig,
            allocator,
            json_text,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();
        return try parsed.value.clone(allocator);
    }

    /// Build the out-of-the-box config: the six bundled provider presets.
    /// Caller owns the result (must call deinit).
    pub fn defaultConfig(allocator: Allocator) !ProxyConfig {
        var opencode = try defaultOpenCodeProvider(allocator);
        errdefer opencode.deinit(allocator);
        var kilo = try defaultKiloProvider(allocator);
        errdefer kilo.deinit(allocator);
        var bai = try defaultBaiProvider(allocator);
        errdefer bai.deinit(allocator);
        var tokenrouter = try defaultBareTokenRouter(allocator);
        errdefer tokenrouter.deinit(allocator);
        var cline = try defaultBareCline(allocator);
        errdefer cline.deinit(allocator);
        var nous = try defaultBareNous(allocator);
        errdefer nous.deinit(allocator);

        const providers = try allocator.alloc(Provider, 6);
        providers[0] = opencode;
        providers[1] = kilo;
        providers[2] = bai;
        providers[3] = tokenrouter;
        providers[4] = cline;
        providers[5] = nous;
        return .{
            .port = default_port,
            .providers = providers,
            .auto_start = false,
            .cooldown_secs = default_cooldown_secs,
            .timeout_ms = default_timeout_ms,
        };
    }
};

/// Result of ProxyConfig.routeModel.
pub const RoutedModel = struct {
    provider_index: usize,
    upstream_model: []const u8,
};

// ---------------------------------------------------------------------------
// HTTP status classification helpers (shared with src/rotator.zig)
// ---------------------------------------------------------------------------

/// 2xx counts as a healthy upstream response.
pub fn isHealthyStatus(status: u16) bool {
    return status >= 200 and status < 300;
}

/// Transient failures worth a cooldown + failover: 429, 408 and 5xx
/// (except 501 which is a permanent "not implemented").
pub fn statusSuggestsCooldown(status: u16) bool {
    if (status == 429 or status == 408) return true;
    if (status == 501) return false;
    return status >= 500 and status < 600;
}

/// Auth failures that mark a key Dead: 401 / 403 (expired / banned).
pub fn statusSuggestsDead(status: u16) bool {
    return status == 401 or status == 403;
}

// ---------------------------------------------------------------------------
// Preset providers (plan.md section 3.C)
// ---------------------------------------------------------------------------

/// The five mandatory static headers for the OpenCode Zen preset.
pub fn defaultOpenCodeHeaders(allocator: Allocator) ![]CustomHeader {
    const preset = [_]CustomHeader{
        .{ .key = "User-Agent", .value = "opencode/1.18.26" },
        .{ .key = "x-opencode-project", .value = "global" },
        .{ .key = "x-opencode-session", .value = "ses_19f6c1805ffe2ziZ0G3WZCdgAW" },
        .{ .key = "x-opencode-request", .value = "msg_8c4e2a91b7d03f5e" },
        .{ .key = "x-opencode-client", .value = "cli" },
    };
    const headers = try allocator.alloc(CustomHeader, preset.len);
    var filled: usize = 0;
    errdefer {
        for (headers[0..filled]) |*h| h.deinit(allocator);
        allocator.free(headers);
    }
    for (preset, 0..) |h, i| {
        headers[i] = try h.clone(allocator);
        filled = i + 1;
    }
    return headers;
}

/// OpenCode Zen preset. Starts with an empty key pool for the user to fill.
/// Caller owns the result (must call deinit).
pub fn defaultOpenCodeProvider(allocator: Allocator) !Provider {
    const display_name = try allocator.dupe(u8, opencode_display_name);
    errdefer allocator.free(display_name);
    const base_url = try allocator.dupe(u8, opencode_base_url);
    errdefer allocator.free(base_url);
    const prefix = try allocator.dupe(u8, opencode_prefix);
    errdefer allocator.free(prefix);
    const description = try allocator.dupe(u8, opencode_description);
    errdefer allocator.free(description);
    const note = try allocator.dupe(u8, opencode_note);
    errdefer allocator.free(note);
    const site_url = try allocator.dupe(u8, opencode_site_url);
    errdefer allocator.free(site_url);
    const headers = try defaultOpenCodeHeaders(allocator);
    errdefer {
        for (headers) |*h| h.deinit(allocator);
        allocator.free(headers);
    }
    const keys = try allocator.alloc(Key, 0);
    return .{
        .display_name = display_name,
        .base_url = base_url,
        .prefix = prefix,
        .description = description,
        .keys = keys,
        .headers = headers,
        .note = note,
        .site_url = site_url,
        .wire_api = .openai_responses,
    };
}

/// Kilo Gateway preset (bearer-token auth, no static headers).
/// Caller owns the result (must call deinit).
pub fn defaultKiloProvider(allocator: Allocator) !Provider {
    const display_name = try allocator.dupe(u8, kilo_display_name);
    errdefer allocator.free(display_name);
    const base_url = try allocator.dupe(u8, kilo_base_url);
    errdefer allocator.free(base_url);
    const prefix = try allocator.dupe(u8, kilo_prefix);
    errdefer allocator.free(prefix);
    const description = try allocator.dupe(u8, kilo_description);
    errdefer allocator.free(description);
    const note = try allocator.dupe(u8, kilo_note);
    errdefer allocator.free(note);
    const site_url = try allocator.dupe(u8, kilo_site_url);
    errdefer allocator.free(site_url);
    const headers = try allocator.alloc(CustomHeader, 0);
    errdefer allocator.free(headers);
    const keys = try allocator.alloc(Key, 0);
    errdefer allocator.free(keys);
    return .{
        .display_name = display_name,
        .base_url = base_url,
        .prefix = prefix,
        .description = description,
        .keys = keys,
        .headers = headers,
        .note = note,
        .site_url = site_url,
    };
}

/// b.ai preset: seeded with the four known free models so the catalog works
/// before the first successful upstream fetch. Caller owns the result.
pub fn defaultBaiProvider(allocator: Allocator) !Provider {
    const display_name = try allocator.dupe(u8, bai_display_name);
    errdefer allocator.free(display_name);
    const base_url = try allocator.dupe(u8, bai_base_url);
    errdefer allocator.free(base_url);
    const prefix = try allocator.dupe(u8, bai_prefix);
    errdefer allocator.free(prefix);
    const description = try allocator.dupe(u8, bai_description);
    errdefer allocator.free(description);
    const note = try allocator.dupe(u8, bai_note);
    errdefer allocator.free(note);
    const site_url = try allocator.dupe(u8, bai_site_url);
    errdefer allocator.free(site_url);
    const headers = try allocator.alloc(CustomHeader, 0);
    errdefer allocator.free(headers);
    const keys = try allocator.alloc(Key, 0);
    errdefer allocator.free(keys);

    const models = try allocator.alloc(ModelInfo, bai_seed_models.len);
    var filled: usize = 0;
    errdefer {
        for (models[0..filled]) |*m| m.deinit(allocator);
        allocator.free(models);
    }
    for (bai_seed_models) |seed| {
        models[filled] = .{
            .id = try std.fmt.allocPrint(allocator, "{s}{s}", .{ bai_prefix, seed.id }),
            .upstream_id = try allocator.dupe(u8, seed.id),
            .provider_name = try allocator.dupe(u8, bai_display_name),
            .provider_prefix = try allocator.dupe(u8, bai_prefix),
            .context_window = seed.context_window,
            .enabled = true,
            .reasoning_levels = try allocator.dupe(u8, default_reasoning_levels),
            .free = true,
        };
        filled += 1;
    }
    return .{
        .display_name = display_name,
        .base_url = base_url,
        .prefix = prefix,
        .description = description,
        .keys = keys,
        .headers = headers,
        .note = note,
        .site_url = site_url,
        .models = models,
    };
}

/// Bare gateway preset: no static headers, no keys, empty catalog (the
/// dashboard populates it from the upstream /models on first refresh).
/// Caller owns the result (must call deinit).
pub fn defaultBareProvider(
    allocator: Allocator,
    display_name: []const u8,
    base_url: []const u8,
    prefix: []const u8,
    description: []const u8,
    note: []const u8,
    site_url: []const u8,
) !Provider {
    const dn = try allocator.dupe(u8, display_name);
    errdefer allocator.free(dn);
    const bu = try allocator.dupe(u8, base_url);
    errdefer allocator.free(bu);
    const px = try allocator.dupe(u8, prefix);
    errdefer allocator.free(px);
    const de = try allocator.dupe(u8, description);
    errdefer allocator.free(de);
    const nt = try allocator.dupe(u8, note);
    errdefer allocator.free(nt);
    const su = try allocator.dupe(u8, site_url);
    errdefer allocator.free(su);
    const headers = try allocator.alloc(CustomHeader, 0);
    errdefer allocator.free(headers);
    const keys = try allocator.alloc(Key, 0);
    errdefer allocator.free(keys);
    return .{
        .display_name = dn,
        .base_url = bu,
        .prefix = px,
        .description = de,
        .keys = keys,
        .headers = headers,
        .note = nt,
        .site_url = su,
    };
}

/// TokenRouter preset. Caller owns the result (must call deinit).
pub fn defaultBareTokenRouter(allocator: Allocator) !Provider {
    return defaultBareProvider(allocator, tokenrouter_display_name, tokenrouter_base_url, tokenrouter_prefix, tokenrouter_description, tokenrouter_note, tokenrouter_site_url);
}

/// Cline preset. Caller owns the result (must call deinit).
pub fn defaultBareCline(allocator: Allocator) !Provider {
    return defaultBareProvider(allocator, cline_display_name, cline_base_url, cline_prefix, cline_description, cline_note, cline_site_url);
}

/// Nous Research preset. Caller owns the result (must call deinit).
pub fn defaultBareNous(allocator: Allocator) !Provider {
    return defaultBareProvider(allocator, nous_display_name, nous_base_url, nous_prefix, nous_description, nous_note, nous_site_url);
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "presets carry the plan.md base urls, prefixes and static headers" {
    const allocator = std.testing.allocator;
    var cfg = try ProxyConfig.defaultConfig(allocator);
    defer cfg.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 6), cfg.providers.len);
    try cfg.validate();

    const oc = cfg.providers[0];
    try std.testing.expectEqualStrings("OpenCode Zen", oc.display_name);
    try std.testing.expectEqualStrings("https://opencode.ai/zen/v1/", oc.base_url);
    try std.testing.expectEqualStrings("oc/", oc.prefix);
    try std.testing.expectEqual(@as(usize, 5), oc.headers.len);
    try std.testing.expectEqualStrings("opencode/1.18.26", oc.findHeader("User-Agent").?);
    try std.testing.expectEqualStrings("global", oc.findHeader("x-opencode-project").?);
    try std.testing.expectEqualStrings("ses_19f6c1805ffe2ziZ0G3WZCdgAW", oc.findHeader("x-opencode-session").?);
    try std.testing.expectEqualStrings("msg_8c4e2a91b7d03f5e", oc.findHeader("x-opencode-request").?);
    try std.testing.expectEqualStrings("cli", oc.findHeader("x-opencode-client").?);

    const kilo = cfg.providers[1];
    try std.testing.expectEqualStrings("Kilo Gateway", kilo.display_name);
    try std.testing.expectEqualStrings("https://api.kilo.ai/api/gateway", kilo.base_url);
    try std.testing.expectEqualStrings("kilo/", kilo.prefix);
}

test "key state machine: usable, cooldown, promote, dead" {
    var k = Key.init("sk-test-123");
    try k.validate();
    try std.testing.expect(k.isUsable(1_000));

    k.markCooldown(1_000, 60);
    try std.testing.expectEqual(KeyState.CoolingDown, k.state);
    try std.testing.expect(!k.isUsable(1_030));
    try std.testing.expect(!k.tryPromote(1_030));
    try std.testing.expect(k.tryPromote(1_060));
    try std.testing.expectEqual(KeyState.Active, k.state);
    try std.testing.expect(k.isUsable(1_060));

    k.markDead(2_000);
    try std.testing.expectEqual(KeyState.Dead, k.state);
    try std.testing.expect(!k.isUsable(9_999_999));
    try std.testing.expect(!k.tryPromote(9_999_999));

    k.enabled = false;
    k.state = .Active;
    try std.testing.expect(!k.isUsable(2_001));

    var empty = Key.init("");
    try std.testing.expectError(ValidateError.EmptyKeyMaterial, empty.validate());
    empty.key = "x";
    try empty.validate();
}

test "provider validation rejects bad urls, prefixes and duplicates" {
    const allocator = std.testing.allocator;
    var p = try defaultKiloProvider(allocator);
    defer p.deinit(allocator);
    try p.validate();

    const saved_url = p.base_url;
    p.base_url = "ftp://example.com/x";
    try std.testing.expectError(ValidateError.InvalidBaseUrl, p.validate());
    p.base_url = saved_url;

    const saved_prefix = p.prefix;
    p.prefix = "kilo";
    try std.testing.expectError(ValidateError.PrefixMissingTrailingSlash, p.validate());
    p.prefix = saved_prefix;

    // Duplicate key material.
    p.keys = try allocator.alloc(Key, 2);
    p.keys[0] = .{ .key = "dup" };
    p.keys[1] = .{ .key = "dup" };
    try std.testing.expectError(ValidateError.DuplicateKeyMaterial, p.validate());
    allocator.free(p.keys);
    p.keys = try allocator.alloc(Key, 0);

    // Bad header name.
    p.headers = try allocator.alloc(CustomHeader, 1);
    p.headers[0] = .{ .key = "X-Bad:Name", .value = "v" };
    try std.testing.expectError(ValidateError.InvalidHeaderName, p.validate());
    allocator.free(p.headers);
    p.headers = try allocator.alloc(CustomHeader, 0);

    try p.validate();
}

test "config validation rejects duplicate prefixes and bad scalars" {
    const allocator = std.testing.allocator;
    var cfg = try ProxyConfig.defaultConfig(allocator);
    defer cfg.deinit(allocator);

    allocator.free(cfg.providers[1].prefix);
    cfg.providers[1].prefix = try allocator.dupe(u8, "oc/");
    try std.testing.expectError(ValidateError.DuplicatePrefix, cfg.validate());

    allocator.free(cfg.providers[1].prefix);
    cfg.providers[1].prefix = try allocator.dupe(u8, kilo_prefix);
    try cfg.validate();

    cfg.port = 0;
    try std.testing.expectError(ValidateError.InvalidPort, cfg.validate());
    cfg.port = default_port;

    cfg.cooldown_secs = 0;
    try std.testing.expectError(ValidateError.InvalidCooldown, cfg.validate());
    cfg.cooldown_secs = default_cooldown_secs;

    cfg.timeout_ms = 0;
    try std.testing.expectError(ValidateError.InvalidTimeout, cfg.validate());
    cfg.timeout_ms = default_timeout_ms;

    try cfg.validate();
}

test "json roundtrip preserves config including key state" {
    const allocator = std.testing.allocator;
    var cfg = try ProxyConfig.defaultConfig(allocator);
    defer cfg.deinit(allocator);

    // Give OpenCode two keys with distinct states.
    allocator.free(cfg.providers[0].keys);
    var keys = try allocator.alloc(Key, 2);
    keys[0] = try (Key{ .key = "oc-key-1" }).clone(allocator);
    keys[1] = try (Key{ .key = "oc-key-2", .state = .CoolingDown, .cooldown_until = 9_999, .consecutive_errors = 2 }).clone(allocator);
    cfg.providers[0].keys = keys;
    cfg.auto_start = true;

    const text = try cfg.toJsonAlloc(allocator);
    defer allocator.free(text);

    var restored = try ProxyConfig.parse(allocator, text);
    defer restored.deinit(allocator);

    try restored.validate();
    try std.testing.expectEqual(cfg.port, restored.port);
    try std.testing.expectEqual(cfg.auto_start, restored.auto_start);
    try std.testing.expectEqual(cfg.cooldown_secs, restored.cooldown_secs);
    try std.testing.expectEqual(cfg.timeout_ms, restored.timeout_ms);
    try std.testing.expectEqual(@as(usize, 6), restored.providers.len);
    try std.testing.expectEqualStrings("oc-key-1", restored.providers[0].keys[0].key);
    try std.testing.expectEqual(KeyState.Active, restored.providers[0].keys[0].state);
    try std.testing.expectEqualStrings("oc-key-2", restored.providers[0].keys[1].key);
    try std.testing.expectEqual(KeyState.CoolingDown, restored.providers[0].keys[1].state);
    try std.testing.expectEqual(@as(i64, 9_999), restored.providers[0].keys[1].cooldown_until);
    try std.testing.expectEqualStrings("opencode/1.18.26", restored.providers[0].findHeader("User-Agent").?);
}

test "model routing matches prefixes and strips them" {
    const allocator = std.testing.allocator;
    var cfg = try ProxyConfig.defaultConfig(allocator);
    defer cfg.deinit(allocator);

    const a = cfg.routeModel("oc/deepseek-r1").?;
    try std.testing.expectEqual(@as(usize, 0), a.provider_index);
    try std.testing.expectEqualStrings("deepseek-r1", a.upstream_model);

    const b = cfg.routeModel("kilo/llama-3.3").?;
    try std.testing.expectEqual(@as(usize, 1), b.provider_index);
    try std.testing.expectEqualStrings("llama-3.3", b.upstream_model);

    try std.testing.expect(cfg.routeModel("unknown/model") == null);
}

test "status classification matches the rotation contract" {
    try std.testing.expect(isHealthyStatus(200));
    try std.testing.expect(!isHealthyStatus(429));
    try std.testing.expect(statusSuggestsCooldown(429));
    try std.testing.expect(statusSuggestsCooldown(503));
    try std.testing.expect(!statusSuggestsCooldown(501));
    try std.testing.expect(!statusSuggestsCooldown(200));
    try std.testing.expect(statusSuggestsDead(401));
    try std.testing.expect(statusSuggestsDead(403));
    try std.testing.expect(!statusSuggestsDead(429));
}

test "HTTP header lookup and duplicates are case insensitive" {
    var headers = [_]CustomHeader{ .{ .key = "USER-AGENT", .value = "test" }, .{ .key = "user-agent", .value = "duplicate" } };
    const p = Provider{ .display_name = "Test", .base_url = "https://example.com/v1", .prefix = "t/", .description = "", .keys = &.{}, .headers = &headers };
    try std.testing.expectEqualStrings("test", p.findHeader("User-Agent").?);
    try std.testing.expectError(ValidateError.DuplicateHeaderName, p.validate());
}

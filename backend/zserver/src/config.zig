//! Configuration loaded from environment variables.

const std = @import("std");

const log = std.log.scoped(.config);

pub const AppConfig = struct {
    allow_signup: bool,
    google_client_id: []const u8,
    workspace_creation_disabled: bool,
    daemon_server_url: ?[]const u8,
    daemon_app_url: ?[]const u8,
    posthog_key: ?[]const u8,
    posthog_host: ?[]const u8,
    analytics_environment: []const u8,
};

pub const Config = struct {
    port: u16,
    db_url: []const u8,
    jwt_secret: []const u8,
    redis_url: ?[]const u8,
    public_url: []const u8,
    allowed_origins: []const []const u8,
    trusted_proxies: []const []const u8,
    allowed_emails: []const []const u8,
    allowed_email_domains: []const []const u8,
    app_env: []const u8,
    cookie_domain: ?[]const u8,
    auth_token_ttl: i64,
    rate_limit_auth: u32,
    rate_limit_auth_verify: u32,
    dev_verification_code: ?[]const u8,
    stripe_webhook_secret: ?[]const u8,
    github_webhook_secret: ?[]const u8,
    google_client_id: ?[]const u8,
    google_client_secret: ?[]const u8,
    resend_api_key: ?[]const u8,
    resend_from_email: []const u8,
    github_app_slug: ?[]const u8,
    /// Shared secret used by `RequireServiceOrWorkspaceRole` to bypass
    /// the workspace-role check. Empty string disables the bypass; set
    /// `ONEPERSON_SERVICE_TOKEN` in the environment to enable it. The
    /// value is read-only and lives for the lifetime of the process.
    service_token: []const u8,
    app: AppConfig,

    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *const Config) void {
        var mut = self.*;
        mut.arena.deinit();
    }
};

pub const Options = struct {
    port: ?u16 = null,
    db_url: ?[]const u8 = null,
};

/// Case-insensitive production-environment check. Production gates
/// safety-critical behaviour: no-DB mode is forbidden, JWT_SECRET is
/// mandatory, and dev-only shortcuts (fixed verification codes, format-only
/// token checks) are disabled.
pub fn isProduction(app_env: []const u8) bool {
    return std.ascii.eqlIgnoreCase(app_env, "production");
}

pub fn load(parent_allocator: std.mem.Allocator, environ: *std.process.Environ.Map, opts: Options, io: std.Io) !Config {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const port: u16 = blk: {
        if (opts.port) |p| break :blk p;
        const raw = getEnvOwned(allocator, environ, "PORT") catch |err| switch (err) {
            error.NotFound => break :blk 8080,
            else => return err,
        };
        break :blk try std.fmt.parseInt(u16, raw, 10);
    };

    const app_env_raw = try getEnvOwnedDefault(allocator, environ, "APP_ENV", "development");
    const app_env = try allocator.dupe(u8, std.mem.trim(u8, app_env_raw, &std.ascii.whitespace));

    const db_url = blk: {
        if (opts.db_url) |u| break :blk try allocator.dupe(u8, u);
        break :blk getEnvOwned(allocator, environ, "DATABASE_URL") catch |err| switch (err) {
            error.NotFound => try allocator.dupe(u8, "postgres://1person:1person@localhost:5432/1person?sslmode=disable"),
            else => return err,
        };
    };

    const jwt_secret_env = try getEnvOwnedOptional(allocator, environ, "JWT_SECRET");
    const jwt_secret = jwt_secret_env orelse blk: {
        if (std.ascii.eqlIgnoreCase(app_env, "production")) {
            log.err("JWT_SECRET must be set in production — refusing to start with a guessable secret", .{});
            return error.JwtSecretRequired;
        }
        // Dev: generate a fresh random secret so a defaulted instance is
        // not running on a publicly-known key. Tokens issued before a
        // restart become invalid — acceptable for local development.
        var bytes: [32]u8 = undefined;
        io.randomSecure(&bytes) catch {
            log.err("JWT_SECRET not set and no OS entropy available — refusing to start", .{});
            return error.JwtSecretRequired;
        };
        const hex = std.fmt.bytesToHex(bytes, .lower);
        const secret = try std.fmt.allocPrint(allocator, "dev-{s}", .{hex});
        log.warn("JWT_SECRET is not set — generated a random dev secret (existing tokens invalidate on restart). Set JWT_SECRET to persist.", .{});
        break :blk secret;
    };
    const redis_url = try getEnvOwnedOptional(allocator, environ, "REDIS_URL");
    const cookie_domain = try getEnvOwnedOptional(allocator, environ, "COOKIE_DOMAIN");

    const auth_token_ttl = blk: {
        const raw = try getEnvOwnedDefault(allocator, environ, "AUTH_TOKEN_TTL", "2592000");
        defer allocator.free(raw);
        break :blk try std.fmt.parseInt(i64, raw, 10);
    };

    const rate_limit_auth = blk: {
        const raw = try getEnvOwnedDefault(allocator, environ, "RATE_LIMIT_AUTH", "5");
        defer allocator.free(raw);
        break :blk try std.fmt.parseInt(u32, raw, 10);
    };

    const rate_limit_auth_verify = blk: {
        const raw = try getEnvOwnedDefault(allocator, environ, "RATE_LIMIT_AUTH_VERIFY", "20");
        defer allocator.free(raw);
        break :blk try std.fmt.parseInt(u32, raw, 10);
    };

    const public_url_raw = try getEnvOwnedDefault(allocator, environ, "ONEPERSON_PUBLIC_URL", "");
    const public_url_trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, public_url_raw, &std.ascii.whitespace), "/");
    const public_url = try allocator.dupe(u8, public_url_trimmed);

    const allowed_origins = try splitCommaEnv(allocator, environ, "CORS_ALLOWED_ORIGINS", &.{ "http://localhost:3000", "http://localhost:5173", "http://localhost:5174" });
    const trusted_proxies = try splitCommaEnv(allocator, environ, "ONEPERSON_TRUSTED_PROXIES", &.{});
    const allowed_emails = try splitCommaEnv(allocator, environ, "ALLOWED_EMAILS", &.{});
    const allowed_email_domains = try splitCommaEnv(allocator, environ, "ALLOWED_EMAIL_DOMAINS", &.{});

    const dev_verification_code = blk: {
        if (std.ascii.eqlIgnoreCase(app_env, "production")) break :blk null;
        const raw = try getEnvOwnedOptional(allocator, environ, "ONEPERSON_DEV_VERIFICATION_CODE");
        if (raw) |r| {
            const trimmed = std.mem.trim(u8, r, &std.ascii.whitespace);
            if (trimmed.len == 6) {
                var ok = true;
                for (trimmed) |c| {
                    if (c < '0' or c > '9') ok = false;
                }
                if (ok) break :blk trimmed;
            }
            allocator.free(r);
        }
        break :blk null;
    };

    const stripe_webhook_secret = try getEnvOwnedOptional(allocator, environ, "STRIPE_WEBHOOK_SECRET");
    const github_webhook_secret = try getEnvOwnedOptional(allocator, environ, "GITHUB_WEBHOOK_SECRET");
    const google_client_id = try getEnvOwnedOptional(allocator, environ, "GOOGLE_CLIENT_ID");
    const google_client_secret = try getEnvOwnedOptional(allocator, environ, "GOOGLE_CLIENT_SECRET");
    const resend_api_key = try getEnvOwnedOptional(allocator, environ, "RESEND_API_KEY");
    const resend_from_email = try getEnvOwnedDefault(allocator, environ, "RESEND_FROM_EMAIL", "noreply@1person.xyz");
    const github_app_slug = try getEnvOwnedOptional(allocator, environ, "GITHUB_APP_SLUG");

    // `ONEPERSON_SERVICE_TOKEN` enables the service-account bypass in
    // `RequireServiceOrWorkspaceRole`. Empty / unset disables the bypass
    // (the default), so existing deployments keep their original
    // workspace-role-only behaviour.
    const service_token = try getEnvOwnedDefault(allocator, environ, "ONEPERSON_SERVICE_TOKEN", "");

    const app = try loadAppConfig(allocator, environ, app_env);

    return Config{
        .port = port,
        .db_url = db_url,
        .jwt_secret = jwt_secret,
        .redis_url = redis_url,
        .public_url = public_url,
        .allowed_origins = allowed_origins,
        .trusted_proxies = trusted_proxies,
        .allowed_emails = allowed_emails,
        .allowed_email_domains = allowed_email_domains,
        .app_env = app_env,
        .cookie_domain = cookie_domain,
        .auth_token_ttl = auth_token_ttl,
        .rate_limit_auth = rate_limit_auth,
        .rate_limit_auth_verify = rate_limit_auth_verify,
        .dev_verification_code = dev_verification_code,
        .stripe_webhook_secret = stripe_webhook_secret,
        .github_webhook_secret = github_webhook_secret,
        .google_client_id = google_client_id,
        .google_client_secret = google_client_secret,
        .resend_api_key = resend_api_key,
        .resend_from_email = resend_from_email,
        .github_app_slug = github_app_slug,
        .service_token = service_token,
        .app = app,
        .arena = arena,
    };
}

fn loadAppConfig(allocator: std.mem.Allocator, environ: *std.process.Environ.Map, app_env: []const u8) !AppConfig {
    const allow_signup_env = try getEnvOwnedDefault(allocator, environ, "ALLOW_SIGNUP", "true");
    const allow_signup = !std.mem.eql(u8, allow_signup_env, "false");

    const google_client_id = try getEnvOwnedDefault(allocator, environ, "GOOGLE_CLIENT_ID", "");

    const disable_ws_env = try getEnvOwnedDefault(allocator, environ, "DISABLE_WORKSPACE_CREATION", "false");
    const workspace_creation_disabled = std.mem.eql(u8, disable_ws_env, "true");

    const public_url = try getEnvOwnedDefault(allocator, environ, "ONEPERSON_PUBLIC_URL", "");
    const app_url_env = try getEnvOwnedDefault(allocator, environ, "ONEPERSON_APP_URL", "");

    const daemon = daemonSetupURLs(allocator, environ, public_url, app_url_env);

    const analytics_disabled_env = try getEnvOwnedDefault(allocator, environ, "ANALYTICS_DISABLED", "false");
    const analytics_disabled = std.mem.eql(u8, analytics_disabled_env, "true") or std.mem.eql(u8, analytics_disabled_env, "1");

    var posthog_key: ?[]const u8 = null;
    var posthog_host: ?[]const u8 = null;
    var analytics_environment: []const u8 = undefined;

    if (!analytics_disabled) {
        posthog_key = try getEnvOwnedOptional(allocator, environ, "POSTHOG_API_KEY");
        posthog_host = try getEnvOwnedOptional(allocator, environ, "POSTHOG_HOST");
        analytics_environment = try allocator.dupe(u8, analyticsEnvironmentFromEnv(allocator, environ, app_env));
    } else {
        analytics_environment = try allocator.dupe(u8, "production");
    }

    if (posthog_host == null and posthog_key != null) {
        posthog_host = try allocator.dupe(u8, "https://us.i.posthog.com");
    }

    return AppConfig{
        .allow_signup = allow_signup,
        .google_client_id = google_client_id,
        .workspace_creation_disabled = workspace_creation_disabled,
        .daemon_server_url = daemon.server_url,
        .daemon_app_url = daemon.app_url,
        .posthog_key = posthog_key,
        .posthog_host = posthog_host,
        .analytics_environment = analytics_environment,
    };
}

const DaemonUrls = struct {
    server_url: ?[]const u8,
    app_url: ?[]const u8,
};

fn daemonSetupURLs(allocator: std.mem.Allocator, environ: *std.process.Environ.Map, public_url: []const u8, app_url: []const u8) DaemonUrls {
    var server = normalizeURL(allocator, public_url) catch null;
    var app = normalizeURL(allocator, app_url) catch null;

    if (app == null or app.?.len == 0) {
        const frontend_origin = getEnvOwnedDefault(allocator, environ, "FRONTEND_ORIGIN", "") catch "";
        app = normalizeURL(allocator, frontend_origin) catch null;
    }

    if (app == null or app.?.len == 0) {
        return .{ .server_url = null, .app_url = null };
    }

    if (server == null or server.?.len == 0) {
        server = allocator.dupe(u8, app.?) catch null;
    }

    if (isOfficialCloud(app.?)) {
        return .{ .server_url = null, .app_url = null };
    }

    return .{ .server_url = server, .app_url = app };
}

fn normalizeURL(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    const without_slash = std.mem.trimEnd(u8, trimmed, "/");
    return try allocator.dupe(u8, without_slash);
}

fn isOfficialCloud(app_url: []const u8) bool {
    const host = canonicalURLHost(app_url);
    return std.mem.eql(u8, host, "1person.xyz") or std.mem.eql(u8, host, "app.1person.xyz");
}

fn canonicalURLHost(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) return "";

    var buf: [512]u8 = undefined;
    const with_scheme = if (std.mem.indexOf(u8, trimmed, "://")) |_|
        trimmed
    else
        std.fmt.bufPrint(&buf, "https://{s}", .{trimmed}) catch return "";

    const scheme_end = std.mem.indexOf(u8, with_scheme, "://") orelse return "";
    const after_scheme = with_scheme[scheme_end + 3 ..];
    const host_port = if (std.mem.indexOf(u8, after_scheme, "/")) |i| after_scheme[0..i] else after_scheme;
    const host = if (std.mem.indexOfScalar(u8, host_port, ':')) |i| host_port[0..i] else host_port;
    return std.mem.trimEnd(u8, host, ".");
}

fn analyticsEnvironmentFromEnv(allocator: std.mem.Allocator, environ: *std.process.Environ.Map, app_env: []const u8) []const u8 {
    const raw = environ.get("ANALYTICS_ENVIRONMENT") orelse "";
    if (raw.len > 0) return allocator.dupe(u8, raw) catch "production";
    if (std.ascii.eqlIgnoreCase(app_env, "production")) return allocator.dupe(u8, "production") catch "production";
    return allocator.dupe(u8, "development") catch "development";
}

fn getEnvOwned(allocator: std.mem.Allocator, environ: *std.process.Environ.Map, name: []const u8) ![]const u8 {
    const value = environ.get(name) orelse return error.NotFound;
    return try allocator.dupe(u8, value);
}

fn getEnvOwnedOptional(allocator: std.mem.Allocator, environ: *std.process.Environ.Map, name: []const u8) !?[]const u8 {
    const value = environ.get(name) orelse return null;
    // Treat empty / whitespace-only values as unset — .env files
    // conventionally ship blank optionals (RESEND_API_KEY=, GOOGLE_CLIENT_ID=)
    // and a literal empty string is not a usable credential.
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn getEnvOwnedDefault(allocator: std.mem.Allocator, environ: *std.process.Environ.Map, name: []const u8, default: []const u8) ![]const u8 {
    const value = environ.get(name) orelse return try allocator.dupe(u8, default);
    return try allocator.dupe(u8, value);
}

fn splitCommaEnv(allocator: std.mem.Allocator, environ: *std.process.Environ.Map, name: []const u8, defaults: []const []const u8) ![]const []const u8 {
    const raw = environ.get(name) orelse {
        var out = try allocator.alloc([]const u8, defaults.len);
        for (defaults, 0..) |d, i| {
            out[i] = try allocator.dupe(u8, d);
        }
        return out;
    };

    var list: std.ArrayList([]const u8) = .empty;
    defer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        try list.append(allocator, try allocator.dupe(u8, trimmed));
    }

    if (list.items.len == 0) {
        var out = try allocator.alloc([]const u8, defaults.len);
        for (defaults, 0..) |d, i| {
            out[i] = try allocator.dupe(u8, d);
        }
        return out;
    }

    return try list.toOwnedSlice(allocator);
}

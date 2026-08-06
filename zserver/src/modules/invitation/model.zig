//! Invitation module — data layer.
//!
//! Per the zfinal `examples/ruoyi-gen/` convention, `model.zig` holds
//! the data structs (in-memory row shape + DTO shapes) and any
//! escape-hatch SQL helpers. `service.zig` wraps this with the
//! business logic + the in-memory `mem_invitations` registry.
//!
//! The `workspace_invitation` table uses UUID PKs with TIMESTAMPTZ
//! columns (`expires_at`, `created_at`, `updated_at`) that the ORM
//! can't model cleanly, so all SQL goes through `zfinal.SqlParam` via
//! `deps.acquire()`. The in-memory fallback uses the `InvitationEntry`
//! struct defined here so the no-DB smoke-test path is exercised when
//! the DB is unconfigured.

const std = @import("std");
const zfinal = @import("zfinal");
const SqlParam = zfinal.SqlParam;
const deps = @import("../../deps.zig");
const common_mem = @import("../../common/mem.zig");

/// Borrow a `*zfinal.DB` from the process-wide pool. Returns `null`
/// in no-DB mode or when the pool is uninitialised.
pub fn borrowDb() ?*zfinal.DB {
        return common_mem.borrowDb();
    }

/// In-memory `workspace_invitation` row.
pub const InvitationEntry = struct {
    id: []const u8,
    workspace_id: []const u8,
    inviter_id: []const u8,
    invitee_email: []const u8,
    invitee_user_id: ?[]const u8,
    role: []const u8,
    status: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    expires_at: []const u8,
};

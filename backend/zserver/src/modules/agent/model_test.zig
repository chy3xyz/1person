//! Coverage for the runtime-consent rule that guards agent↔runtime binding.
//!
//! The rule mirrors upstream `service.RuntimeAllowsUser`
//! (`server/internal/service/runtime_access.go`): a runtime admits its
//! owner, a public runtime admits every workspace member, and an
//! ownerless runtime admits nobody.
//!
//! It matters because the fork's runtime picker filters to "mine"
//! (`owner_id === currentUser`) and marks everything else as locked.
//! When the server and the picker disagree about the same rule, the
//! dialog ends up with no selectable runtime and agent creation dies
//! silently — which is exactly what an ownerless runtime produced.

const std = @import("std");
const testing = std.testing;
const model = @import("model.zig");

const OWNER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";

fn runtime(owner: []const u8, visibility: []const u8) model.RuntimeBinding {
    return model.RuntimeBinding{
        .workspace_id = "ws-1",
        .owner_id = owner,
        .visibility = visibility,
    };
}

test "runtimeAllowsUser: the owner may always bind" {
    try testing.expect(model.runtimeAllowsUser(runtime(OWNER, "private"), OWNER));
    try testing.expect(model.runtimeAllowsUser(runtime(OWNER, "public"), OWNER));
}

test "runtimeAllowsUser: a public runtime admits any workspace member" {
    try testing.expect(model.runtimeAllowsUser(runtime(OWNER, "public"), OTHER));
}

test "runtimeAllowsUser: a private runtime is closed to everyone but its owner" {
    try testing.expect(!model.runtimeAllowsUser(runtime(OWNER, "private"), OTHER));
}

test "runtimeAllowsUser: an ownerless runtime admits nobody" {
    // Upstream treats an ownerless runtime as unusable: it cannot mint
    // task tokens, so binding an agent to it can only produce a
    // permanently stuck agent.
    try testing.expect(!model.runtimeAllowsUser(runtime("", "private"), OWNER));
    try testing.expect(!model.runtimeAllowsUser(runtime("", "public"), OWNER));
    try testing.expect(!model.runtimeAllowsUser(runtime("", "public"), OTHER));
}

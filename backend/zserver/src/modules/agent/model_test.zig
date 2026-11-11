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
const zfinal = @import("zfinal");
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

/// An `AgentEntry` with every column filled in, so a test can change
/// one `jsonb` column at a time.
fn entry() model.AgentEntry {
    return model.AgentEntry{
        .id = "agent-1",
        .workspace_id = "ws-1",
        .runtime_id = "rt-1",
        .name = "三源智能体",
        .description = "",
        .instructions = "",
        .avatar_url = "",
        .runtime_mode = "local",
        .runtime_config = "{}",
        .custom_args = "[]",
        .custom_env = "{}",
        .mcp_config = "",
        .visibility = "private",
        .status = "idle",
        .max_concurrent_tasks = 6,
        .model = "deepseek/deepseek-flash",
        .thinking_level = "",
        .owner_id = OWNER,
        .archived_at = "",
        .archived_by = "",
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    };
}

fn renderAgent(allocator: std.mem.Allocator, e: model.AgentEntry) ![]const u8 {
    const resp = try model.agentResponseFromEntry(allocator, e, &[_]@import("../skill/model.zig").SkillSummaryResponse{});
    return zfinal.JsonKit.stringify(allocator, resp);
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

test "agent response: a non-empty runtime_config reaches the client as a JSON object" {
    // Regression: the converter used to parse the `jsonb` columns into
    // a `std.json.Value` and release the parser's arena when it
    // returned. The response then pointed into freed memory and
    // `renderJson` walked it — a use-after-free that segfaulted the
    // server. An empty `{}` column hid the bug (there was nothing to
    // dereference); the first agent with a real `runtime_config` took
    // the process down.
    const allocator = std.testing.allocator;
    var e = entry();
    e.runtime_config = "{\"local_path\":\"/Users/someone/lab\"}";

    const json = try renderAgent(allocator, e);
    defer allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"runtime_config\":{\"local_path\":\"/Users/someone/lab\"}") != null);
}

test "agent response: custom_args stays an array of strings" {
    const allocator = std.testing.allocator;
    var e = entry();
    e.custom_args = "[\"--verbose\",\"--model\",\"x\"]";

    const json = try renderAgent(allocator, e);
    defer allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"custom_args\":[\"--verbose\",\"--model\",\"x\"]") != null);
}

test "agent response: a malformed jsonb column falls back instead of corrupting the body" {
    // The client types `custom_args` as `string[]` and
    // `runtime_config` as an object. A column that is neither would
    // serialise as something the schema rejects and drop the whole
    // agent record on the client, so it degrades to the empty value.
    const allocator = std.testing.allocator;
    var e = entry();
    e.custom_args = "{\"not\":\"an array\"}";
    e.runtime_config = "not json at all";

    const json = try renderAgent(allocator, e);
    defer allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"custom_args\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"runtime_config\":{}") != null);
}

test "agent response: the custom env key count survives the render" {
    const allocator = std.testing.allocator;
    var e = entry();
    e.custom_env = "{\"OPENAI_API_KEY\":\"x\",\"BASE_URL\":\"y\"}";

    const json = try renderAgent(allocator, e);
    defer allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"has_custom_env\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"custom_env_key_count\":2") != null);
}

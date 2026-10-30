//! Prompt assembly for agent tasks.
//!
//! The server is the side that can read the task's context (issue, chat
//! transcript, agent configuration), so it renders the final prompt text
//! and hands it to the daemon verbatim. The daemon then only has to run
//! the local agent CLI with that text — it never has to understand the
//! task queue or the database.
//!
//! The prompt language is English (the agent CLI's own convention), while
//! the agent's own `instructions` are passed through untouched: those are
//! written by the user, in whatever language they wrote them.

const std = @import("std");

/// One turn of a chat transcript.
pub const ChatTurn = struct {
    role: []const u8,
    content: []const u8,
};

/// One comment on the issue an agent was asked to work on.
pub const IssueComment = struct {
    author: []const u8,
    content: []const u8,
};

pub const ChatPromptOptions = struct {
    agent_name: []const u8,
    workspace_name: []const u8,
    instructions: []const u8,
    history: []const ChatTurn,
    /// The message that triggered this run.
    request: []const u8,
};

pub const IssuePromptOptions = struct {
    agent_name: []const u8,
    workspace_name: []const u8,
    instructions: []const u8,
    identifier: []const u8,
    title: []const u8,
    description: []const u8,
    status: []const u8,
    priority: []const u8,
    comments: []const IssueComment,
};

/// Preamble shared by every task: who the agent is and where it runs.
fn writePreamble(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, agent_name: []const u8, workspace_name: []const u8) !void {
    try buf.print(allocator, "You are an AI agent named \"{s}\", working in the 1Person workspace \"{s}\".\n\n", .{ agent_name, workspace_name });
}

/// The agent's own instructions, when it has any.
fn writeInstructions(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, instructions: []const u8) !void {
    const trimmed = std.mem.trim(u8, instructions, " \t\r\n");
    if (trimmed.len == 0) return;
    try buf.appendSlice(allocator, trimmed);
    try buf.appendSlice(allocator, "\n\n");
}

/// How the agent is allowed to work.
///
/// This fork's agent execution is text-only: the answer is posted by the
/// server, and the agent has no way to act on the workspace. Saying so
/// keeps the agent from trying to "help" by going through the machine.
fn writeHowToWork(buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try buf.appendSlice(
        allocator,
        "## How to work\n" ++
            "You have no tools: you cannot read or write files, run commands, or call APIs. " ++
            "Do not try to. Work only from the context above.\n\n",
    );
}

/// The deliverable: the answer is the whole reply, not a plan for one.
fn writeDeliveryRule(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, target: []const u8) !void {
    try buf.print(
        allocator,
        "## Deliverable\n" ++
            "Produce the {s} now, in this reply. The platform posts your reply for you — " ++
            "you do not post it yourself. Do not ask questions, do not propose a plan, and do not " ++
            "describe what you would do: state the result.\n",
        .{target},
    );
}

/// Render the prompt for a chat task.
pub fn buildChatPrompt(allocator: std.mem.Allocator, opts: ChatPromptOptions) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try writePreamble(&buf, allocator, opts.agent_name, opts.workspace_name);
    try writeInstructions(&buf, allocator, opts.instructions);
    try writeHowToWork(&buf, allocator);

    if (opts.history.len > 0) {
        try buf.appendSlice(allocator, "## Conversation\n");
        for (opts.history) |turn| {
            const label = if (std.mem.eql(u8, turn.role, "assistant")) "Assistant" else "User";
            try buf.print(allocator, "{s}: {s}\n", .{ label, std.mem.trim(u8, turn.content, " \t\r\n") });
        }
        try buf.appendSlice(allocator, "\n");
    }

    try buf.appendSlice(allocator, "## Request\n");
    try buf.print(allocator, "User: {s}\n\n", .{std.mem.trim(u8, opts.request, " \t\r\n")});
    try writeDeliveryRule(&buf, allocator, "final answer");

    return buf.toOwnedSlice(allocator);
}

/// Render the prompt for an issue task.
pub fn buildIssuePrompt(allocator: std.mem.Allocator, opts: IssuePromptOptions) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try writePreamble(&buf, allocator, opts.agent_name, opts.workspace_name);
    try writeInstructions(&buf, allocator, opts.instructions);
    try writeHowToWork(&buf, allocator);

    try buf.appendSlice(allocator, "## Task\n");
    try buf.print(allocator, "- Issue: {s}\n", .{opts.identifier});
    try buf.print(allocator, "- Title: {s}\n", .{opts.title});
    try buf.print(allocator, "- Status: {s}\n", .{opts.status});
    try buf.print(allocator, "- Priority: {s}\n", .{opts.priority});
    if (std.mem.trim(u8, opts.description, " \t\r\n").len > 0) {
        try buf.appendSlice(allocator, "- Description:\n");
        try buf.print(allocator, "{s}\n", .{std.mem.trim(u8, opts.description, " \t\r\n")});
    }
    try buf.appendSlice(allocator, "\n");

    if (opts.comments.len > 0) {
        try buf.appendSlice(allocator, "## Comments\n");
        for (opts.comments) |comment| {
            try buf.print(allocator, "- {s}: {s}\n", .{ comment.author, std.mem.trim(u8, comment.content, " \t\r\n") });
        }
        try buf.appendSlice(allocator, "\n");
    }

    try writeDeliveryRule(&buf, allocator, "final outcome for the issue — it is posted as a comment on it");

    return buf.toOwnedSlice(allocator);
}

// ──────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "chat prompt carries the agent identity, the transcript and the request" {
    const prompt = try buildChatPrompt(testing.allocator, .{
        .agent_name = "验收智能体",
        .workspace_name = "循义经济",
        .instructions = "你是一个严谨的验收机器人。",
        .history = &.{
            .{ .role = "user", .content = "第一条" },
            .{ .role = "assistant", .content = "收到" },
        },
        .request = "帮我验收这个待办",
    });
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "验收智能体") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "循义经济") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "严谨的验收机器人") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "User: 第一条") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "Assistant: 收到") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "User: 帮我验收这个待办") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "## Deliverable") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "You have no tools") != null);
}

test "chat prompt without instructions omits the instruction block" {
    const prompt = try buildChatPrompt(testing.allocator, .{
        .agent_name = "a",
        .workspace_name = "w",
        .instructions = "   \n",
        .history = &.{},
        .request = "hi",
    });
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "## Conversation") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "User: hi") != null);
}

test "issue prompt carries the issue fields and the comments" {
    const prompt = try buildIssuePrompt(testing.allocator, .{
        .agent_name = "三源智能体",
        .workspace_name = "循义经济",
        .instructions = "",
        .identifier = "XXX-4",
        .title = "编写PRD",
        .description = "写一份需求文档",
        .status = "todo",
        .priority = "urgent",
        .comments = &.{
            .{ .author = "neo", .content = "先写大纲" },
        },
    });
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "- Issue: XXX-4") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "- Title: 编写PRD") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "- Status: todo") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "- Priority: urgent") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "写一份需求文档") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "- neo: 先写大纲") != null);
    try testing.expect(std.mem.indexOf(u8, prompt, "posted as a comment on it") != null);
}

test "issue prompt without a description omits the description line" {
    const prompt = try buildIssuePrompt(testing.allocator, .{
        .agent_name = "a",
        .workspace_name = "w",
        .instructions = "",
        .identifier = "XXX-1",
        .title = "t",
        .description = "",
        .status = "todo",
        .priority = "none",
        .comments = &.{},
    });
    defer testing.allocator.free(prompt);

    try testing.expect(std.mem.indexOf(u8, prompt, "- Description:") == null);
    try testing.expect(std.mem.indexOf(u8, prompt, "## Comments") == null);
}

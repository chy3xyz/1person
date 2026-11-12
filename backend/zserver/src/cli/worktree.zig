//! Git worktree isolation for agent tasks.
//!
//! An agent that edits code must not edit the user's working copy. This
//! module gives every task its own git worktree — a private checkout of the
//! user's repository on its own branch — so the changes are reviewable and
//! the user's own files are never touched.
//!
//! The shape follows upstream multica's `local_directory` worktree mode:
//! the task branch lives in the user's repository (discoverable with
//! `git branch`), and the worktree itself is disposable.

const std = @import("std");
const out = @import("out.zig");
const zfinal = @import("zfinal");

/// How long any single git invocation may take.
///
/// These are local-only operations, so a slow one means a wedged index lock
/// rather than a slow remote. Failing the task beats hanging the daemon.
const git_timeout_ms: u64 = 120_000;

/// The outcome of a git invocation.
pub const GitResult = struct {
    /// The command's stdout, trimmed of trailing whitespace.
    stdout: []const u8,
    /// The command's stderr, trimmed. Empty when the command said nothing.
    stderr: []const u8,
    /// The exit code, or null when the process was killed by a signal.
    exit_code: ?u8,

    pub fn ok(self: GitResult) bool {
        return self.exit_code == 0;
    }
};

/// A worktree prepared for one agent task.
pub const Worktree = struct {
    /// The repository the worktree was created from.
    repo_root: []const u8,
    /// The worktree directory — the agent's working directory.
    path: []const u8,
    /// The branch the task's work is delivered on.
    branch: []const u8,
    /// The commit the branch started from.
    base_commit: []const u8,

    pub fn deinit(self: Worktree, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.path);
        allocator.free(self.branch);
        allocator.free(self.base_commit);
    }
};

/// The result of delivering a task's work.
pub const Delivery = struct {
    /// The branch the work was committed onto.
    branch: []const u8,
    /// The commit that carries the work, when anything was committed.
    commit: ?[]const u8,
    /// The number of files the task changed.
    files_changed: usize,

    pub fn deinit(self: Delivery, allocator: std.mem.Allocator) void {
        allocator.free(self.branch);
        if (self.commit) |c| allocator.free(c);
    }
};

/// Run git in `dir` and capture what it said.
///
/// `args` are the git arguments without the leading "git" — the caller's
/// directory and the command itself are added here.
///
/// The caller owns both returned strings.
pub fn runGit(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    args: []const []const u8,
) !GitResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    try argv.append(allocator, "-C");
    try argv.append(allocator, dir);
    try argv.appendSlice(allocator, args);

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(@intCast(git_timeout_ms)), .clock = .real } },
    }) catch |err| {
        out.printErr("git {s} failed to start ({s})\n", .{ args[0], @errorName(err) });
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return GitResult{
        .stdout = try allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n")),
        .stderr = try allocator.dupe(u8, std.mem.trim(u8, result.stderr, " \t\r\n")),
        .exit_code = switch (result.term) {
            .exited => |code| code,
            else => null,
        },
    };
}

/// Free a git result.
pub fn freeGitResult(allocator: std.mem.Allocator, result: GitResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

/// Find the repository root that contains `path`.
///
/// `path` may be a subdirectory of the repository: the agent's working
/// directory keeps the user's chosen depth, so a resource pointed at
/// `<repo>/services/api` lands the agent in `<worktree>/services/api`.
///
/// The caller owns the returned string.
pub fn resolveRepoRoot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    // A path that is not there at all is a different mistake from a path that
    // is there but is not a repository, and the user can only fix one of
    // them. Git reports both as a failed `rev-parse`, so the directory is
    // checked before git is asked.
    if (!directoryExists(io, path)) return error.DirectoryNotFound;

    const result = try runGit(allocator, io, path, &.{"rev-parse", "--show-toplevel"});
    defer freeGitResult(allocator, result);
    if (!result.ok() or result.stdout.len == 0) {
        return error.NotAGitRepository;
    }
    // The result's own buffer is released when this function returns, so
    // the path has to be copied out before it does. Handing out the
    // buffer itself would return freed memory — and the caller's own
    // `free` of it would be a double free.
    return allocator.dupe(u8, result.stdout);
}

/// Build the branch name a task's work is delivered on.
///
/// The name carries the agent and the task so the user can tell two tasks'
/// branches apart in `git branch`.
pub fn branchName(allocator: std.mem.Allocator, agent_name: []const u8, task_id: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "1p/");
    try appendComponent(allocator, &buf, agent_name, "agent");
    try buf.append(allocator, '/');
    try appendComponent(allocator, &buf, task_id, "task");
    return buf.toOwnedSlice(allocator);
}

/// Append one sanitized ref component to `buf`.
///
/// `fallback` is used when the text sanitizes away entirely: git rejects
/// a ref with an empty component.
fn appendComponent(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    text: []const u8,
    fallback: []const u8,
) !void {
    const start = buf.items.len;
    try appendSanitized(allocator, buf, text);
    if (buf.items.len == start) try buf.appendSlice(allocator, fallback);
}

/// Append `text` to `buf`, replacing anything a git ref cannot carry.
///
/// A ref component may not contain a space, a tilde, a caret, a colon, a
/// question mark, an asterisk, an open bracket, a backslash, or any control
/// character; it may not contain "..", may not begin with a dot, and may
/// not end with ".lock". The agent name is user-supplied and the task id
/// is a UUID, so both are sanitized rather than trusted.
///
/// The dot is replaced like any other unsafe character: it is the one
/// character that would let a name such as ".." escape the "1p/"
/// namespace, and a component that begins with one is invalid anyway.
///
/// Non-ASCII bytes are carried through unchanged: git ref names hold
/// UTF-8, and the agent's name is what the user recognises the branch
/// by.
fn appendSanitized(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        const safe = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => true,
            0x80...0xff => true,
            else => false,
        };
        try buf.append(allocator, if (safe) c else '-');
    }
}

/// Check that a bound directory path is one the daemon can act on.
///
/// The path must be absolute: a relative one is resolved against whatever
/// directory the daemon happens to run in, so the agent would work in a
/// repository the user never named. Both the CLI that writes the binding and
/// the daemon that reads it enforce this rule, so the binding cannot be
/// accepted on one side and rejected on the other.
pub fn validateLocalPath(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.PathNotAbsolute;
}

/// Whether `path` is a directory that exists.
fn directoryExists(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Whether `path` is inside a git work tree.
pub fn isGitWorkTree(allocator: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    const result = runGit(allocator, io, path, &.{"rev-parse", "--is-inside-work-tree"}) catch return false;
    defer freeGitResult(allocator, result);
    return result.ok() and std.mem.eql(u8, result.stdout, "true");
}

/// Whether the repository has at least one commit.
///
/// A worktree is created from a commit — there is nothing to branch from in
/// an empty repository — so a task on one cannot start.
pub fn hasCommit(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8) bool {
    const result = runGit(allocator, io, repo_root, &.{"rev-parse", "--verify", "HEAD"}) catch return false;
    defer freeGitResult(allocator, result);
    return result.ok();
}

/// Create the worktree for one task.
///
/// The branch is created from the repository's current HEAD and checked out
/// into `worktree_path`. The worktree is a private directory the agent may
/// edit freely; the user's own working copy is untouched.
///
/// The caller owns the returned worktree.
pub fn createWorktree(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo_root: []const u8,
    worktree_path: []const u8,
    branch: []const u8,
) !Worktree {
    if (!isGitWorkTree(allocator, io, repo_root)) return error.NotAGitRepository;
    if (!hasCommit(allocator, io, repo_root)) return error.NoCommit;

    // A worktree left over from an earlier run of the same task still
    // holds the branch, and git refuses to delete a branch that is
    // checked out somewhere. The leftover is taken down first and the
    // branch is dropped afterwards, so a retried task starts from a
    // clean base.
    //
    // The worktree path belongs to this task alone, so nothing else can
    // be living in it.
    removeWorktree(allocator, io, repo_root, worktree_path);

    // A branch that does not exist is the normal case — git says so and
    // exits non-zero, which is not a failure here.
    const dropped = runGit(allocator, io, repo_root, &.{ "branch", "-D", branch }) catch {
        return error.WorktreeCreateFailed;
    };
    defer freeGitResult(allocator, dropped);

    const added = try runGit(allocator, io, repo_root, &.{ "worktree", "add", "-b", branch, worktree_path });
    defer freeGitResult(allocator, added);
    if (!added.ok()) {
        out.printErr("git worktree add failed: {s}\n", .{if (added.stderr.len > 0) added.stderr else added.stdout});
        return error.WorktreeCreateFailed;
    }

    const base = try runGit(allocator, io, repo_root, &.{"rev-parse", "HEAD"});
    defer freeGitResult(allocator, base);

    return Worktree{
        .repo_root = try allocator.dupe(u8, repo_root),
        .path = try allocator.dupe(u8, worktree_path),
        .branch = try allocator.dupe(u8, branch),
        .base_commit = try allocator.dupe(u8, base.stdout),
    };
}

/// Why a task could not get a working directory, in words the user can act on.
///
/// The daemon reports the task failure with this text, and the user reads it
/// where the failure is shown: it has to name the mistake that was made —
/// the directory is not there, it is not a repository, it has no commits —
/// because each of them is fixed in a different place (the agent's binding,
/// the repository itself, the daemon's setup).
///
/// The generic fallback is only for errors that carry no meaning of their
/// own; a specific cause must never be flattened into it.
pub fn worktreeFailureReason(err: anyerror) []const u8 {
    return switch (err) {
        error.PathNotAbsolute => "the directory the agent is bound to must be an absolute path",
        error.DirectoryNotFound => "the directory the agent is bound to does not exist on this machine",
        error.NotAGitRepository => "the directory the agent is bound to is not a git repository",
        error.NoCommit => "the repository the agent is bound to has no commits yet, so there is nothing to branch from",
        error.NoWorkRoot => "the daemon has no working directory to put the agent's checkout in",
        error.WorktreeCreateFailed => "the daemon could not create a worktree in the repository the agent is bound to",
        else => "the daemon could not prepare a working directory for the agent",
    };
}

/// Whether the worktree has changes that are not committed.
pub fn isDirty(allocator: std.mem.Allocator, io: std.Io, worktree_path: []const u8) bool {
    const result = runGit(allocator, io, worktree_path, &.{"status", "--porcelain"}) catch return false;
    defer freeGitResult(allocator, result);
    return result.ok() and result.stdout.len > 0;
}

/// The number of files the worktree changed, counted by git itself.
pub fn changedFileCount(allocator: std.mem.Allocator, io: std.Io, worktree_path: []const u8) usize {
    const result = runGit(allocator, io, worktree_path, &.{ "diff", "HEAD", "--name-only" }) catch return 0;
    defer freeGitResult(allocator, result);
    return countLines(result);
}

/// The number of files a commit carries.
///
/// This is what the delivery reports: once the work is committed, the
/// working tree no longer differs from HEAD, so the count has to come
/// from the commit itself.
pub fn committedFileCount(allocator: std.mem.Allocator, io: std.Io, worktree_path: []const u8, commit: []const u8) usize {
    const result = runGit(allocator, io, worktree_path, &.{ "show", "--name-only", "--pretty=format:", commit }) catch return 0;
    defer freeGitResult(allocator, result);
    return countLines(result);
}

/// Count the non-empty lines of a git listing.
fn countLines(result: GitResult) usize {
    if (!result.ok() or result.stdout.len == 0) return 0;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) count += 1;
    }
    return count;
}

/// Commit whatever the agent left behind and report what was delivered.
///
/// The commit is the delivery contract: the agent's changes are no longer
/// loose files in a directory that will be reclaimed, they are a commit on
/// a branch the user can inspect and merge.
///
/// The caller owns the returned delivery.
pub fn deliverWork(
    allocator: std.mem.Allocator,
    io: std.Io,
    worktree: Worktree,
    message: []const u8,
) !Delivery {
    var delivery = Delivery{
        .branch = try allocator.dupe(u8, worktree.branch),
        .commit = null,
        .files_changed = changedFileCount(allocator, io, worktree.path),
    };
    errdefer {
        allocator.free(delivery.branch);
        if (delivery.commit) |c| allocator.free(c);
    }

    if (!isDirty(allocator, io, worktree.path)) {
        // The agent changed nothing. There is nothing to commit, and an
        // empty commit would only put noise on the user's branch list.
        return delivery;
    }

    const added = try runGit(allocator, io, worktree.path, &.{"add", "-A"});
    defer freeGitResult(allocator, added);
    if (!added.ok()) return error.DeliveryFailed;

    // The commit hooks of the user's repository are deliberately not run:
    // they belong to the user's own workflow, may sign commits with a key
    // the daemon does not have, and may fail on a tree the user never
    // pushed. The delivery must not depend on them.
    const committed = try runGit(allocator, io, worktree.path, &.{
        "commit",   "--no-verify", "-m", message,
    });
    defer freeGitResult(allocator, committed);
    if (!committed.ok()) {
        out.printErr("git commit failed: {s}\n", .{if (committed.stderr.len > 0) committed.stderr else committed.stdout});
        return error.DeliveryFailed;
    }

    const head = try runGit(allocator, io, worktree.path, &.{"rev-parse", "HEAD"});
    defer freeGitResult(allocator, head);
    delivery.commit = try allocator.dupe(u8, head.stdout);
    // The count comes from the commit, not from the working tree: once
    // the work is committed, the tree no longer differs from HEAD and a
    // diff would report nothing at all.
    delivery.files_changed = committedFileCount(allocator, io, worktree.path, head.stdout);
    return delivery;
}

/// Remove the worktree, leaving the branch behind.
///
/// The branch is the deliverable and it stays in the user's repository; the
/// worktree is a scratch directory and goes away with it.
pub fn removeWorktree(allocator: std.mem.Allocator, io: std.Io, repo_root: []const u8, worktree_path: []const u8) void {
    const removed = runGit(allocator, io, repo_root, &.{ "worktree", "remove", "--force", worktree_path }) catch return;
    defer freeGitResult(allocator, removed);
    if (!removed.ok()) {
        // The worktree is already gone (a crashed daemon, a manual cleanup);
        // pruning drops the stale registration.
        const pruned = runGit(allocator, io, repo_root, &.{"worktree", "prune"}) catch return;
        freeGitResult(allocator, pruned);
    }
}

// ──────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "branch name carries the agent and the task" {
    const name = try branchName(testing.allocator, "三源智能体", "abc12345");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("1p/三源智能体/abc12345", name);
}

test "branch name keeps safe characters readable" {
    const name = try branchName(testing.allocator, "dev-agent", "0f3a1b2c-4d5e");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("1p/dev-agent/0f3a1b2c-4d5e", name);
}

test "branch name cannot escape its namespace with a path separator" {
    // An agent named "../../etc" must not be able to name a ref outside
    // the "1p/" namespace.
    const name = try branchName(testing.allocator, "../../etc", "task");
    defer testing.allocator.free(name);
    try testing.expect(std.mem.indexOf(u8, name, "..") == null);
    try testing.expect(std.mem.startsWith(u8, name, "1p/"));
}

test "branch name cannot escape its namespace with a dot" {
    // ".." is a path component of its own to git: a name that kept the
    // dot could point the branch outside "1p/".
    const name = try branchName(testing.allocator, "..", "task");
    defer testing.allocator.free(name);
    try testing.expect(std.mem.indexOf(u8, name, "..") == null);
    try testing.expect(std.mem.startsWith(u8, name, "1p/"));
}

test "branch name survives a name that sanitizes away entirely" {
    // An empty component is not a valid ref.
    const name = try branchName(testing.allocator, "", "task");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("1p/agent/task", name);
}

test "branch name keeps a name that sanitizes into dashes" {
    // "///" is not empty — it is three separators, which the sanitizer
    // turns into three dashes. That is still a valid ref component.
    const name = try branchName(testing.allocator, "///", "task");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("1p/---/task", name);
}

test "branch name rejects characters a git ref cannot carry" {
    const name = try branchName(testing.allocator, "a b~c^d:e?f*g[h", "task");
    defer testing.allocator.free(name);
    for (name) |c| {
        try testing.expect(c == '/' or c == '-' or
            (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'));
    }
}

/// A throwaway git repository with one commit.
fn testRepo(allocator: std.mem.Allocator) !struct { tmp: std.testing.TmpDir, path: []const u8 } {
    const io = zfinal.io_instance.io;
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();

    var path_buf: [4096]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    // The path is copied out of the stack buffer: returning a slice of
    // a local would hand the caller a pointer to a dead frame.
    const path = try allocator.dupe(u8, path_buf[0..path_len]);
    errdefer allocator.free(path);

    const init = try runGit(testing.allocator, io, path, &.{"init", "--quiet"});
    defer freeGitResult(testing.allocator, init);
    try testing.expect(init.ok());

    // A repository needs a commit before it has a HEAD to report, and
    // the commit needs an identity — the machine running the test may
    // not have a global one.
    for ([_][2][]const u8{
        .{ "user.email", "test@local.test" },
        .{ "user.name", "1p test" },
    }) |pair| {
        const config = try runGit(testing.allocator, io, path, &.{ "config", pair[0], pair[1] });
        defer freeGitResult(testing.allocator, config);
        try testing.expect(config.ok());
    }

    const commit = try runGit(testing.allocator, io, path, &.{ "commit", "--quiet", "--allow-empty", "-m", "init" });
    defer freeGitResult(testing.allocator, commit);
    try testing.expect(commit.ok());

    return .{ .tmp = tmp, .path = path };
}

test "resolveRepoRoot hands back a path the caller owns" {
    // Regression: the function used to hand out the git output buffer
    // and release it on the way out. The caller received freed memory,
    // and its own `free` of that pointer was a double free that took
    // the daemon down in the middle of a task.
    const allocator = testing.allocator;

    var repo = try testRepo(allocator);
    defer repo.tmp.cleanup();
    defer allocator.free(repo.path);

    const root = try resolveRepoRoot(allocator, zfinal.io_instance.io, repo.path);
    defer allocator.free(root);

    try testing.expect(root.len > 0);
    try testing.expect(std.fs.path.isAbsolute(root));
}

test "a directory that is not there is told apart from one that is not a repository" {
    // Regression: both mistakes used to come back as `NotAGitRepository`,
    // so the user was told to look for a repository where the path they
    // bound simply does not exist. Git reports both the same way, so the
    // directory has to be checked before git is asked.
    const allocator = testing.allocator;
    const io = zfinal.io_instance.io;

    var repo = try testRepo(allocator);
    defer repo.tmp.cleanup();
    defer allocator.free(repo.path);

    // A path under the repository that was never created.
    const missing = try std.fs.path.join(allocator, &.{ repo.path, "not-here" });
    defer allocator.free(missing);
    try testing.expectError(error.DirectoryNotFound, resolveRepoRoot(allocator, io, missing));

    // A directory that exists but is not a repository. The `.git` entry is
    // deliberately broken: git stops at it instead of walking up to the
    // repository the temporary directory itself lives in.
    var plain = testing.tmpDir(.{});
    defer plain.cleanup();
    var plain_buf: [4096]u8 = undefined;
    const plain_len = try plain.dir.realPath(io, &plain_buf);
    const plain_path = try allocator.dupe(u8, plain_buf[0..plain_len]);
    defer allocator.free(plain_path);
    const broken_git = try std.fs.path.join(allocator, &.{ plain_path, ".git" });
    defer allocator.free(broken_git);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = broken_git, .data = "gitdir: /nonexistent/nowhere\n" });
    try testing.expect(!isGitWorkTree(allocator, io, plain_path));
    try testing.expectError(error.NotAGitRepository, resolveRepoRoot(allocator, io, plain_path));
}

test "a repository without a commit has nothing to branch from" {
    const allocator = testing.allocator;
    const io = zfinal.io_instance.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [4096]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const path = try allocator.dupe(u8, path_buf[0..path_len]);
    defer allocator.free(path);

    const init = try runGit(allocator, io, path, &.{"init", "--quiet"});
    defer freeGitResult(allocator, init);
    try testing.expect(init.ok());

    const worktree_path = try std.fs.path.join(allocator, &.{ path, "wt" });
    defer allocator.free(worktree_path);
    const branch = try branchName(allocator, "agent", "task");
    defer allocator.free(branch);

    try testing.expectError(error.NoCommit, createWorktree(allocator, io, path, worktree_path, branch));
}

test "each way of failing names the mistake the user has to fix" {
    // The daemon reports the task failure with this text and the user reads
    // it. One generic sentence for every cause leaves the user with nothing
    // to act on — the whole point of the binding is that they can fix it.
    const missing = worktreeFailureReason(error.DirectoryNotFound);
    const not_repo = worktreeFailureReason(error.NotAGitRepository);
    const no_commit = worktreeFailureReason(error.NoCommit);
    const not_absolute = worktreeFailureReason(error.PathNotAbsolute);
    const create_failed = worktreeFailureReason(error.WorktreeCreateFailed);
    const unknown = worktreeFailureReason(error.SomethingElseEntirely);

    // Each cause says something different.
    try testing.expect(!std.mem.eql(u8, missing, not_repo));
    try testing.expect(!std.mem.eql(u8, not_repo, no_commit));
    try testing.expect(!std.mem.eql(u8, no_commit, not_absolute));
    try testing.expect(!std.mem.eql(u8, not_absolute, create_failed));

    // And each says what to do about it.
    try testing.expect(std.mem.indexOf(u8, missing, "does not exist") != null);
    try testing.expect(std.mem.indexOf(u8, not_repo, "not a git repository") != null);
    try testing.expect(std.mem.indexOf(u8, no_commit, "no commits") != null);
    try testing.expect(std.mem.indexOf(u8, not_absolute, "absolute path") != null);

    // An unknown error keeps the generic sentence — but a known one must
    // never fall back to it.
    try testing.expect(std.mem.indexOf(u8, unknown, "could not prepare") != null);
    for ([_][]const u8{ missing, not_repo, no_commit, not_absolute, create_failed }) |reason| {
        try testing.expect(std.mem.indexOf(u8, reason, "could not prepare") == null);
    }
}

test "a bound directory path has to be absolute" {
    // A relative path is resolved against the daemon's own working
    // directory: the agent would work in a repository the user never named,
    // and nothing would say so.
    try testing.expectError(error.PathNotAbsolute, validateLocalPath("relative/path"));
    try testing.expectError(error.PathNotAbsolute, validateLocalPath("./repo"));
    try testing.expectError(error.PathNotAbsolute, validateLocalPath("repo"));
    try validateLocalPath("/Users/me/lab");
}

test "the delivery reports how many files the commit carries" {
    // Regression: the count was taken from a diff against HEAD after the
    // work was committed — and a committed tree no longer differs from
    // HEAD, so every delivery reported "0 files changed" while carrying
    // a commit with the agent's work in it.
    const allocator = testing.allocator;
    const io = zfinal.io_instance.io;

    var repo = try testRepo(allocator);
    defer repo.tmp.cleanup();
    defer allocator.free(repo.path);

    const worktree_path = try std.fs.path.join(allocator, &.{ repo.path, "wt" });
    defer allocator.free(worktree_path);
    const branch = try branchName(allocator, "agent", "task");
    defer allocator.free(branch);

    const wt = try createWorktree(allocator, io, repo.path, worktree_path, branch);
    defer wt.deinit(allocator);

    // The agent leaves a new file behind.
    const file_path = try std.fs.path.join(allocator, &.{ wt.path, "invoice.py" });
    defer allocator.free(file_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "total = 0\n" });

    const message = try allocator.dupe(u8, "chore(1p): test");
    defer allocator.free(message);
    const delivery = try deliverWork(allocator, io, wt, message);
    defer delivery.deinit(allocator);

    try testing.expect(delivery.commit != null);
    try testing.expectEqual(@as(usize, 1), delivery.files_changed);
}

test "a task that is retried gets its worktree back" {
    // Regression: the worktree of an earlier run still held the branch,
    // and git refuses to delete a branch that is checked out somewhere —
    // so the retried task could not get its worktree back and the task
    // failed before the agent ever ran.
    const allocator = testing.allocator;
    const io = zfinal.io_instance.io;

    var repo = try testRepo(allocator);
    defer repo.tmp.cleanup();
    defer allocator.free(repo.path);

    const worktree_path = try std.fs.path.join(allocator, &.{ repo.path, "wt" });
    defer allocator.free(worktree_path);
    const branch = try branchName(allocator, "agent", "task");
    defer allocator.free(branch);

    const first = try createWorktree(allocator, io, repo.path, worktree_path, branch);
    defer first.deinit(allocator);
    try testing.expectEqualStrings(branch, first.branch);

    // The same task, run again.
    const second = try createWorktree(allocator, io, repo.path, worktree_path, branch);
    defer second.deinit(allocator);
    try testing.expectEqualStrings(branch, second.branch);
}

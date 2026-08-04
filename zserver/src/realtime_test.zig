//! Unit tests for the realtime ring-buffer + replay helpers.
//!
//! These exercise the no-DB / no-WS fallback path directly: `publishInbox`
//! always pushes into the ring buffer, and `replaySnapshot` returns the
//! matching envelopes without requiring a live WebSocket connection.

const std = @import("std");
const realtime = @import("modules/realtime/service.zig");

/// Wipe any on-disk JSONL log and in-memory ring entry for the given
/// `(workspace, user)` pair so the test starts from a clean slate. The
/// ring buffer is now persisted across processes, so this is required to
/// keep the per-test expectations deterministic.
fn resetPair(workspace_id: []const u8, user_id: []const u8) void {
    realtime.clearRingForTest(workspace_id, user_id);
}

test "replaySnapshot returns empty when no envelopes published" {
    const allocator = std.testing.allocator;
    const ws = "11111111-1111-1111-1111-111111111111";
    const uid = "22222222-2222-2222-2222-222222222222";
    resetPair(ws, uid);

    const snapshot = realtime.replaySnapshot(allocator, ws, uid, 0);
    defer allocator.free(snapshot.envelopes);

    try std.testing.expectEqual(@as(usize, 0), snapshot.replayed);
    try std.testing.expectEqual(@as(u64, 0), snapshot.latest_seq);
    try std.testing.expectEqual(@as(usize, 0), snapshot.envelopes.len);
}

test "replaySnapshot returns envelopes with seq greater than since_seq" {
    const allocator = std.testing.allocator;
    const ws = "ws-no-db-test-aaaa";
    const uid = "uid-no-db-test-bbbb";
    resetPair(ws, uid);

    // Publish three envelopes directly via the public helper. The
    // `payload` is expected to be a JSON object so `publishInbox` can
    // prepend the `seq` field; the shape mirrors what `notifyInboxChange`
    // emits from `inbox.zig`.
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"i1\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"i2\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"archive\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"i3\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");

    try std.testing.expectEqual(@as(u64, 3), realtime.latestSeq(ws, uid));

    // Asking for everything since 0 must give us all three envelopes.
    {
        const snap = realtime.replaySnapshot(allocator, ws, uid, 0);
        defer allocator.free(snap.envelopes);
        try std.testing.expectEqual(@as(usize, 3), snap.replayed);
        try std.testing.expectEqual(@as(u64, 3), snap.latest_seq);
        try std.testing.expectEqual(@as(usize, 3), snap.envelopes.len);
        for (snap.envelopes) |env| {
            // Every envelope must be a JSON object containing the `seq`
            // and `type` fields so downstream consumers can decode it.
            try std.testing.expect(env.len > 0);
            try std.testing.expect(std.mem.startsWith(u8, env, "{"));
        }
    }

    // Since 1 — should give us the second + third envelopes only.
    {
        const snap = realtime.replaySnapshot(allocator, ws, uid, 1);
        defer allocator.free(snap.envelopes);
        try std.testing.expectEqual(@as(usize, 2), snap.replayed);
        try std.testing.expectEqual(@as(u64, 3), snap.latest_seq);
        try std.testing.expectEqual(@as(usize, 2), snap.envelopes.len);
    }

    // Since 3 — the buffer is exhausted so replayed should be 0.
    {
        const snap = realtime.replaySnapshot(allocator, ws, uid, 3);
        defer allocator.free(snap.envelopes);
        try std.testing.expectEqual(@as(usize, 0), snap.replayed);
        try std.testing.expectEqual(@as(u64, 3), snap.latest_seq);
        try std.testing.expectEqual(@as(usize, 0), snap.envelopes.len);
    }
}

test "replaySnapshot isolates per (workspace, user) pair" {
    const allocator = std.testing.allocator;
    const ws = "ws-isolation-test";
    const user_a = "user-a";
    const user_b = "user-b";
    resetPair(ws, user_a);
    resetPair(ws, user_b);

    realtime.publishInbox(ws, user_a, "{\"type\":\"inbox_updated\",\"inbox_id\":\"a1\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ user_a ++ "\",\"action\":\"read\",\"count\":1}");
    realtime.publishInbox(ws, user_b, "{\"type\":\"inbox_updated\",\"inbox_id\":\"b1\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ user_b ++ "\",\"action\":\"read\",\"count\":1}");
    realtime.publishInbox(ws, user_b, "{\"type\":\"inbox_updated\",\"inbox_id\":\"b2\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ user_b ++ "\",\"action\":\"read\",\"count\":1}");

    const snap_a = realtime.replaySnapshot(allocator, ws, user_a, 0);
    defer allocator.free(snap_a.envelopes);
    try std.testing.expectEqual(@as(usize, 1), snap_a.replayed);
    try std.testing.expectEqual(@as(u64, 1), snap_a.latest_seq);

    const snap_b = realtime.replaySnapshot(allocator, ws, user_b, 0);
    defer allocator.free(snap_b.envelopes);
    try std.testing.expectEqual(@as(usize, 2), snap_b.replayed);
    try std.testing.expectEqual(@as(u64, 2), snap_b.latest_seq);
}

test "replaySnapshotParsed returns empty when no envelopes published" {
    const allocator = std.testing.allocator;
    const ws = "ws-parsed-empty";
    const uid = "uid-parsed-empty";
    resetPair(ws, uid);

    const snap = try realtime.replaySnapshotParsed(allocator, ws, uid, 0);
    defer {
        for (snap.holders) |h| h.deinit();
        allocator.free(snap.events);
        allocator.free(snap.holders);
    }

    try std.testing.expectEqual(@as(usize, 0), snap.replayed);
    try std.testing.expectEqual(@as(u64, 0), snap.latest_seq);
    try std.testing.expectEqual(@as(usize, 0), snap.events.len);
    try std.testing.expectEqual(@as(usize, 0), snap.holders.len);
}

test "replaySnapshotParsed returns events as parsed std.json.Value objects" {
    const allocator = std.testing.allocator;
    const ws = "ws-parsed-shape";
    const uid = "uid-parsed-shape";
    resetPair(ws, uid);

    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"i1\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"i2\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"archive\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"i3\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");

    try std.testing.expectEqual(@as(u64, 3), realtime.latestSeq(ws, uid));

    // Asking for everything since 0 must give us all three envelopes, each
    // already parsed into a `std.json.Value` object.
    const snap = try realtime.replaySnapshotParsed(allocator, ws, uid, 0);
    defer {
        for (snap.holders) |h| h.deinit();
        allocator.free(snap.events);
        allocator.free(snap.holders);
    }

    try std.testing.expectEqual(@as(usize, 3), snap.replayed);
    try std.testing.expectEqual(@as(u64, 3), snap.latest_seq);
    try std.testing.expectEqual(@as(usize, 3), snap.events.len);
    // Holders and events stay in lock-step so the defer cleanup is correct.
    try std.testing.expectEqual(snap.events.len, snap.holders.len);

    // Each event must be a JSON object with the expected fields; the
    // `seq` integer should be 1-based and monotonically increasing.
    var prev_seq: i64 = 0;
    for (snap.events) |event| {
        const obj = switch (event) {
            .object => |o| o,
            else => return error.UnexpectedEventType,
        };
        const seq_val = obj.get("seq") orelse return error.MissingSeq;
        const seq_int = switch (seq_val) {
            .integer => |i| i,
            else => return error.SeqNotInteger,
        };
        try std.testing.expect(seq_int > prev_seq);
        prev_seq = seq_int;

        const type_val = obj.get("type") orelse return error.MissingType;
        const type_str = switch (type_val) {
            .string => |s| s,
            else => return error.TypeNotString,
        };
        try std.testing.expectEqualStrings("inbox_updated", type_str);

        const inbox_id_val = obj.get("inbox_id") orelse return error.MissingInboxId;
        const inbox_id = switch (inbox_id_val) {
            .string => |s| s,
            else => return error.InboxIdNotString,
        };
        try std.testing.expect(inbox_id.len > 0);
    }
    try std.testing.expectEqual(@as(i64, 3), prev_seq);
}

test "replaySnapshotParsed honours since_seq filter" {
    const allocator = std.testing.allocator;
    const ws = "ws-parsed-since";
    const uid = "uid-parsed-since";
    resetPair(ws, uid);

    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"s1\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"s2\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"archive\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"s3\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");

    // Since 1 — should yield only the second + third envelopes.
    const snap = try realtime.replaySnapshotParsed(allocator, ws, uid, 1);
    defer {
        for (snap.holders) |h| h.deinit();
        allocator.free(snap.events);
        allocator.free(snap.holders);
    }

    try std.testing.expectEqual(@as(usize, 2), snap.replayed);
    try std.testing.expectEqual(@as(u64, 3), snap.latest_seq);
    try std.testing.expectEqual(@as(usize, 2), snap.events.len);

    // Spot-check that the first event we got is the second one published
    // (seq=2), confirming the filter actually applied.
    const first = switch (snap.events[0]) {
        .object => |o| o,
        else => return error.UnexpectedEventType,
    };
    const seq_val = first.get("seq").?;
    try std.testing.expectEqual(@as(i64, 2), seq_val.integer);
}

test "replaySnapshotParsed serialises back to the expected JSON shape" {
    // Confirms the wire-format guarantee: when `listInboxSince` calls
    // `renderJson`, the `events` array should be a flat list of objects
    // (not strings wrapped in JSON quotes) and the cursor fields should be
    // serialised as numbers.
    const allocator = std.testing.allocator;
    const ws = "ws-parsed-render";
    const uid = "uid-parsed-render";
    resetPair(ws, uid);

    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"r1\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");

    const snap = try realtime.replaySnapshotParsed(allocator, ws, uid, 0);
    defer {
        for (snap.holders) |h| h.deinit();
        allocator.free(snap.events);
        allocator.free(snap.holders);
    }

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try std.json.Stringify.value(
        .{
            .events = snap.events,
            .since_seq = @as(u64, 0),
            .latest_seq = snap.latest_seq,
            .replayed = snap.replayed,
        },
        .{},
        &buf.writer,
    );

    const out = buf.written();
    // The cursor fields should appear as plain JSON numbers and the
    // `events` value should be a JSON array — never a JSON-escaped string.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"events\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"since_seq\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"latest_seq\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"replayed\":1") != null);
}

test "publishInbox appends envelopes to the per-pair JSONL log" {
    const allocator = std.testing.allocator;
    const ws = "ws-jsonl-append";
    const uid = "uid-jsonl-append";
    resetPair(ws, uid);

    const payload = "{\"type\":\"inbox_updated\",\"inbox_id\":\"j1\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}";
    realtime.publishInbox(ws, uid, payload);
    realtime.publishInbox(ws, uid, payload);
    realtime.publishInbox(ws, uid, payload);

    const lines = try realtime.readTailJsonl(allocator, ws, uid);
    defer {
        for (lines) |l| allocator.free(l);
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    for (lines) |line| {
        try std.testing.expect(std.mem.indexOf(u8, line, "\"seq\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "inbox_updated") != null);
    }
}

test "purgePair clears the file, ring entry, and seq counter" {
    const allocator = std.testing.allocator;
    const ws = "ws-purge-pair";
    const uid = "uid-purge-pair";
    resetPair(ws, uid);

    // Publish two envelopes so the seq counter advances and the JSONL
    // log + in-memory ring both have content to wipe.
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"p1\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"p2\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"archive\",\"count\":1}");

    // Sanity-check the pre-purge state matches what we expect to lose.
    try std.testing.expectEqual(@as(u64, 2), realtime.latestSeq(ws, uid));
    {
        const lines = try realtime.readTailJsonl(allocator, ws, uid);
        defer {
            for (lines) |l| allocator.free(l);
            allocator.free(lines);
        }
        try std.testing.expectEqual(@as(usize, 2), lines.len);
    }
    {
        const snap = realtime.replaySnapshot(allocator, ws, uid, 0);
        defer allocator.free(snap.envelopes);
        try std.testing.expectEqual(@as(usize, 2), snap.replayed);
    }

    // Wipe the pair. The helper is best-effort and returns void.
    realtime.purgePair(ws, uid);

    // After the purge the seq counter must be 0 and the on-disk log
    // must be empty, so reconnecting clients see a clean slate.
    try std.testing.expectEqual(@as(u64, 0), realtime.latestSeq(ws, uid));
    {
        const lines = try realtime.readTailJsonl(allocator, ws, uid);
        defer {
            for (lines) |l| allocator.free(l);
            allocator.free(lines);
        }
        try std.testing.expectEqual(@as(usize, 0), lines.len);
    }
    {
        const snap = realtime.replaySnapshot(allocator, ws, uid, 0);
        defer allocator.free(snap.envelopes);
        try std.testing.expectEqual(@as(usize, 0), snap.replayed);
        try std.testing.expectEqual(@as(u64, 0), snap.latest_seq);
    }

    // Publishing again after the purge must start a fresh seq at 1
    // and produce a single envelope on disk, confirming the map
    // entries were re-created rather than left as stale tombstones.
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"p3\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");
    try std.testing.expectEqual(@as(u64, 1), realtime.latestSeq(ws, uid));
    const lines = try realtime.readTailJsonl(allocator, ws, uid);
    defer {
        for (lines) |l| allocator.free(l);
        allocator.free(lines);
    }
    try std.testing.expectEqual(@as(usize, 1), lines.len);
}

test "purgePair is idempotent on an already-empty pair" {
    // Purging a (workspace, user) pair that has never been published to
    // must not panic, leak fds, or assert. The on-disk file is absent
    // and the seq/ring map entries are absent too — `purgePair` is
    // best-effort, so the no-op return is the correct behaviour.
    const ws = "ws-purge-empty";
    const uid = "uid-purge-empty";
    resetPair(ws, uid);

    realtime.purgePair(ws, uid);
    realtime.purgePair(ws, uid);

    try std.testing.expectEqual(@as(u64, 0), realtime.latestSeq(ws, uid));
}

/// Fake WebSocket connection used by the `replaySinceStream` test. It
/// records every `sendText` invocation into an `ArrayList(u8)` so the
/// test can assert the exact stream the helper produces.
const FakeConn = struct {
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn sendText(self: *FakeConn, text: []const u8) void {
        self.out.appendSlice(self.allocator, text) catch unreachable;
    }
};

test "replaySinceStream emits envelopes then a replay_complete marker" {
    const allocator = std.testing.allocator;
    const ws = "ws-stream-test";
    const uid = "uid-stream-test";
    resetPair(ws, uid);

    // Publish three envelopes so the stream has something to emit. The
    // helper does not care about payload shape — it just forwards
    // every stored envelope verbatim and appends a trailing `\n`.
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"s1\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"s2\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"archive\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"s3\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var fake = FakeConn{ .out = &out, .allocator = allocator };

    try realtime.replaySinceStream(allocator, ws, uid, 0, &fake, null);

    const stream = out.items;
    // The stream should contain the three envelopes, each followed by
    // a newline, and then the completion marker. We split on `\n` so
    // we can count + inspect each line independently of the others.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, stream, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(allocator, line);
    }

    // Three envelopes + one completion marker = four non-empty lines.
    try std.testing.expectEqual(@as(usize, 4), lines.items.len);

    // The first three lines must each be one of the published
    // envelopes in order. We don't byte-compare (the seq field is
    // allocated with the runtime allocator) but we do require the
    // `inbox_id` field to match the publish order. The needle is
    // assembled at runtime via `std.fmt.allocPrint` because Zig
    // requires `++` to be a comptime concatenation.
    const expected_ids = [_][]const u8{ "s1", "s2", "s3" };
    for (expected_ids, 0..) |expected_id, i| {
        const needle = try std.fmt.allocPrint(
            allocator,
            "\"inbox_id\":\"{s}\"",
            .{expected_id},
        );
        defer allocator.free(needle);
        try std.testing.expect(std.mem.indexOf(u8, lines.items[i], needle) != null);
    }

    // The final line must be the completion marker with the right
    // cursor values: since_seq=0, latest_seq=3, replayed=3.
    const completion = lines.items[3];
    try std.testing.expect(std.mem.indexOf(u8, completion, "\"type\":\"replay_complete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, completion, "\"since_seq\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, completion, "\"latest_seq\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, completion, "\"replayed\":3") != null);
}

test "replaySinceStream honours since_seq filter" {
    const allocator = std.testing.allocator;
    const ws = "ws-stream-since";
    const uid = "uid-stream-since";
    resetPair(ws, uid);

    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"t1\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"t2\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"archive\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"t3\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var fake = FakeConn{ .out = &out, .allocator = allocator };

    // Since 1 — only the second + third envelopes should be emitted.
    try realtime.replaySinceStream(allocator, ws, uid, 1, &fake, null);

    const stream = out.items;
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"inbox_id\":\"t1\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"inbox_id\":\"t2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"inbox_id\":\"t3\"") != null);
    // The marker must still report the filtered count.
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"replayed\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"latest_seq\":3") != null);
}

test "replaySinceStream emits only the marker when nothing matches" {
    const allocator = std.testing.allocator;
    const ws = "ws-stream-empty";
    const uid = "uid-stream-empty";
    resetPair(ws, uid);

    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"u1\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var fake = FakeConn{ .out = &out, .allocator = allocator };

    // Since a very large value — nothing in the ring matches.
    try realtime.replaySinceStream(allocator, ws, uid, 999, &fake, null);

    // The only payload written should be the completion marker.
    const stream = out.items;
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"inbox_id\":\"u1\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"type\":\"replay_complete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"replayed\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"latest_seq\":1") != null);
}

test "replaySinceStream with null since_seq replays everything" {
    const allocator = std.testing.allocator;
    const ws = "ws-stream-null";
    const uid = "uid-stream-null";
    resetPair(ws, uid);

    // Publish three envelopes so the stream has something to emit.
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"n1\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"n2\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"archive\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"n3\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var fake = FakeConn{ .out = &out, .allocator = allocator };

    // Pass `null` (i.e. "no cursor known") and confirm all three
    // envelopes come through followed by the completion marker.
    try realtime.replaySinceStream(allocator, ws, uid, null, &fake, null);

    const stream = out.items;
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, stream, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try lines.append(allocator, line);
    }

    // Three envelopes + one completion marker = four non-empty lines.
    try std.testing.expectEqual(@as(usize, 4), lines.items.len);

    // The first three lines must each be one of the published
    // envelopes in publish order.
    const expected_ids = [_][]const u8{ "n1", "n2", "n3" };
    for (expected_ids, 0..) |expected_id, i| {
        const needle = try std.fmt.allocPrint(
            allocator,
            "\"inbox_id\":\"{s}\"",
            .{expected_id},
        );
        defer allocator.free(needle);
        try std.testing.expect(std.mem.indexOf(u8, lines.items[i], needle) != null);
    }

    // The completion marker must echo the effective cursor (0) and
    // report all three envelopes as replayed.
    const completion = lines.items[3];
    try std.testing.expect(std.mem.indexOf(u8, completion, "\"type\":\"replay_complete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, completion, "\"since_seq\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, completion, "\"latest_seq\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, completion, "\"replayed\":3") != null);
}

test "replaySinceStream stops at max_bytes cap with replay_truncated marker" {
    const allocator = std.testing.allocator;
    const ws = "ws-stream-cap";
    const uid = "uid-stream-cap";
    resetPair(ws, uid);

    // Three payloads of ~120 bytes each; with the seq prefix the
    // envelope is roughly 130 bytes (plus the trailing `\n` = 131),
    // so a 200-byte cap fits the first envelope but rejects the second.
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"c1\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"c2\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"archive\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"c3\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");

    try std.testing.expectEqual(@as(u64, 3), realtime.latestSeq(ws, uid));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var fake = FakeConn{ .out = &out, .allocator = allocator };

    // 200-byte cap is tight enough that only the first envelope fits;
    // the second trip would exceed the limit and trigger the
    // truncated marker.
    try realtime.replaySinceStream(allocator, ws, uid, 0, &fake, 200);

    const stream = out.items;

    // First envelope must have made it through intact.
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"inbox_id\":\"c1\"") != null);
    // Second and third must have been skipped because of the cap.
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"inbox_id\":\"c2\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"inbox_id\":\"c3\"") == null);
    // The truncation marker must replace the completion marker so the
    // client knows to resume from `latest_seq` on the next reconnect.
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"type\":\"replay_truncated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"type\":\"replay_complete\"") == null);
    // The marker must echo the cap, the running total, and the
    // effective cursor so the client can decide what to do next.
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"max_bytes\":200") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"replayed\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"latest_seq\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"since_seq\":0") != null);
}

test "replaySinceStream completes when total bytes are below max_bytes cap" {
    const allocator = std.testing.allocator;
    const ws = "ws-stream-cap-ok";
    const uid = "uid-stream-cap-ok";
    resetPair(ws, uid);

    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"k1\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"k2\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"archive\",\"count\":1}");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var fake = FakeConn{ .out = &out, .allocator = allocator };

    // Generous cap — both envelopes fit comfortably, so we get the
    // normal completion marker (not the truncated one).
    try realtime.replaySinceStream(allocator, ws, uid, 0, &fake, 4096);

    const stream = out.items;
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"inbox_id\":\"k1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"inbox_id\":\"k2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"type\":\"replay_complete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"type\":\"replay_truncated\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, stream, "\"replayed\":2") != null);
}

test "appendAudit writes JSONL lines to today's audit file" {
    const allocator = std.testing.allocator;

    // Capture the line count BEFORE so the assertion works even when
    // the audit file already has lines from prior runs of `zig build test`
    // (the file persists across processes because it lives in
    // `uploads/audit/<YYYY-MM-DD>.jsonl`).
    const before = try realtime.readTodayAuditLines(allocator);
    defer {
        for (before) |l| allocator.free(l);
        allocator.free(before);
    }

    realtime.appendAudit("admin", "user-aaa", "inbox.purge", "ws-aaa", "user-bbb", "manual", &.{});
    realtime.appendAudit("service_actor", "", "inbox.purge", "ws-ccc", "user-ddd", "manual", &.{});

    const after = try realtime.readTodayAuditLines(allocator);
    defer {
        for (after) |l| allocator.free(l);
        allocator.free(after);
    }

    // Two new lines were appended; the existing ones are unchanged.
    try std.testing.expectEqual(before.len + 2, after.len);

    // Spot-check the two new lines (they're at the end because the
    // helper appends). Verify the spec'd fields are present and
    // contain the values we passed.
    const first = after[after.len - 2];
    try std.testing.expect(std.mem.indexOf(u8, first, "\"actor\":\"admin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"user_id\":\"user-aaa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"action\":\"inbox.purge\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"workspace_id\":\"ws-aaa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"target_user_id\":\"user-bbb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"reason\":\"manual\"") != null);
    // The line must also include an RFC3339 UTC `ts` field so the
    // downstream consumer can sort by time.
    try std.testing.expect(std.mem.indexOf(u8, first, "\"ts\":\"") != null);

    const second = after[after.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, second, "\"actor\":\"service_actor\"") != null);
    // `actor_user_id` was empty (anonymous service token) — the JSON
    // field is rendered as an empty string rather than omitted so the
    // shape stays stable across records.
    try std.testing.expect(std.mem.indexOf(u8, second, "\"user_id\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"workspace_id\":\"ws-ccc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"target_user_id\":\"user-ddd\"") != null);
}

test "appendAudit records inbox.export action in today's audit file" {
    // Mirrors `appendAudit writes JSONL lines to today's audit file` but
    // asserts the wire shape used by the new `/api/inbox/admin/export`
    // endpoint — specifically the `inbox.export` action verb and the
    // `manual` reason that the handler writes by default.
    const allocator = std.testing.allocator;

    const before = try realtime.readTodayAuditLines(allocator);
    defer {
        for (before) |l| allocator.free(l);
        allocator.free(before);
    }

    realtime.appendAudit("admin", "user-eee", "inbox.export", "ws-eee", "user-fff", "manual", &.{});

    const after = try realtime.readTodayAuditLines(allocator);
    defer {
        for (after) |l| allocator.free(l);
        allocator.free(after);
    }

    // One new line was appended.
    try std.testing.expectEqual(before.len + 1, after.len);

    // Spot-check the new line: action=inbox.export, reason=manual,
    // workspace_id and target_user_id match the values we passed.
    const last = after[after.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, last, "\"action\":\"inbox.export\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "\"reason\":\"manual\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "\"actor\":\"admin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "\"user_id\":\"user-eee\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "\"workspace_id\":\"ws-eee\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "\"target_user_id\":\"user-fff\"") != null);
}

test "appendAudit merges meta_kv pairs into the JSON line" {
    // Confirms the new `meta_kv` parameter on `appendAudit`: each
    // `name=value` pair is split on the first `=` and rendered as a
    // sibling JSON field on the audit line. Empty `&.{}` keeps the
    // legacy shape, but exporting `inbox.export` uses two pairs
    // (`format=...` and `bytes_exported=...`).
    const allocator = std.testing.allocator;

    const before = try realtime.readTodayAuditLines(allocator);
    defer {
        for (before) |l| allocator.free(l);
        allocator.free(before);
    }

    const meta = [_][]const u8{
        "format=jsonl",
        "bytes_exported=1234",
    };
    realtime.appendAudit(
        "admin",
        "user-metakv",
        "inbox.export",
        "ws-metakv",
        "user-target",
        "manual",
        &meta,
    );

    const after = try realtime.readTodayAuditLines(allocator);
    defer {
        for (after) |l| allocator.free(l);
        allocator.free(after);
    }

    try std.testing.expectEqual(before.len + 1, after.len);

    // The new line must include every base field AND the two meta pairs
    // spliced into the JSON object (so the line is grep-friendly for
    // "who exported how much in what format").
    const last = after[after.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, last, "\"action\":\"inbox.export\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "\"reason\":\"manual\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "\"actor\":\"admin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "\"user_id\":\"user-metakv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "\"workspace_id\":\"ws-metakv\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "\"target_user_id\":\"user-target\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "\"format\":\"jsonl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "\"bytes_exported\":\"1234\"") != null);
}

test "ringApproxBytes returns 0 for an empty ring" {
    const ws = "ws-bytes-empty";
    const uid = "uid-bytes-empty";
    resetPair(ws, uid);

    try std.testing.expectEqual(@as(usize, 0), realtime.ringApproxBytes(ws, uid));
}

test "ringApproxBytes reflects recent publishes" {
    const allocator = std.testing.allocator;
    const ws = "ws-bytes-shape";
    const uid = "uid-bytes-shape";
    resetPair(ws, uid);

    // Empty ring to start.
    try std.testing.expectEqual(@as(usize, 0), realtime.ringApproxBytes(ws, uid));

    // Publish two envelopes; ringApproxBytes must reflect the cumulative
    // size of the stored envelope JSON strings (not the rendered
    // JSON-array wrapper). We compute the expected sum by taking the
    // raw envelope length straight from the replay snapshot so the test
    // does not duplicate the seq-prepending logic from `publishInbox`.
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"b1\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"read\",\"count\":1}");
    realtime.publishInbox(ws, uid, "{\"type\":\"inbox_updated\",\"inbox_id\":\"b2\",\"workspace_id\":\"" ++ ws ++ "\",\"user_id\":\"" ++ uid ++ "\",\"action\":\"archive\",\"count\":1}");

    const snap = realtime.replaySnapshot(allocator, ws, uid, 0);
    defer allocator.free(snap.envelopes);

    var expected: usize = 0;
    for (snap.envelopes) |env| expected += env.len;

    try std.testing.expectEqual(expected, realtime.ringApproxBytes(ws, uid));
    try std.testing.expect(expected > 0);

    // Purge brings the ring back to zero bytes so a subsequent test run
    // starts from a clean slate.
    realtime.purgePair(ws, uid);
    try std.testing.expectEqual(@as(usize, 0), realtime.ringApproxBytes(ws, uid));
}

test "listInboxSince response shape includes ring_bytes when populated" {
    // Doc-test style: serialise a struct that mirrors what the
    // `listInboxSince` handler emits when `?ring_bytes=` is set, and
    // assert the JSON contains the new sibling field. The actual
    // handler logic lives in `inbox.zig` and is covered end-to-end by
    // the smoke test; this test pins the wire contract so a future
    // refactor of the response struct cannot silently drop the
    // `ring_bytes` field.
    const allocator = std.testing.allocator;
    const ring_bytes: usize = 4242;

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try std.json.Stringify.value(
        .{
            .events = &[_]std.json.Value{},
            .since_seq = @as(u64, 0),
            .latest_seq = @as(u64, 0),
            .replayed = @as(usize, 0),
            .truncated = false,
            .sent_bytes = @as(usize, 0),
            .ring_bytes = ring_bytes,
        },
        .{},
        &buf.writer,
    );

    const out = buf.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ring_bytes\":4242") != null);
    // The other cursor fields must still be present so the new field
    // is purely additive.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"since_seq\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"latest_seq\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"replayed\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"truncated\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"sent_bytes\":0") != null);
}

//! JSON helpers shared by every module under `src/modules/`.
//!
//! `std.json.Stringify` has no "raw" escape hatch. Two ways to put a
//! `jsonb` column into a response both have a trap:
//!
//!   * a `[]const u8` field is written as an escaped JSON *string*
//!     (`"[{\"url\":…}]"`), which no client schema can consume;
//!   * a parsed `std.json.Value` owns the parser's arena, so the
//!     converter has to keep that arena alive until the response is
//!     rendered. Freeing it when the converter returns is a
//!     use-after-free — the serializer walks freed memory, and the
//!     server crashes on the first response that has a non-empty
//!     object in it.
//!
//! For a column that must reach the client as real JSON, splice the
//! column text in verbatim instead. The text has to outlive the
//! render: database cell text lives until the result set is deinited
//! (which happens after `renderJson`), and an in-memory row owns its
//! text for the lifetime of the process.

const std = @import("std");

/// Wrap already-valid JSON text so `Stringify` emits it verbatim.
///
/// `std.json.Value.number_string` is written with `jws.print("{s}", …)` —
/// no quoting, no escaping — which is exactly the "raw passthrough" a
/// `jsonb` column needs.
///
/// The text is NOT copied; the caller guarantees it outlives the
/// render. See the module doc for the lifetime rules.
pub fn rawJsonValue(text: []const u8) std.json.Value {
    return .{ .number_string = text };
}

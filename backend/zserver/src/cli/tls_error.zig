//! Transport-error translation for the 1p CLI (port of multica upstream
//! commit MUL-7466 #8761).
//!
//! Without this helper, a misconfigured CA bundle or an expired remote cert
//! bubbles up from `zfinal.HttpClient.requestWith` as one of:
//!
//!   error.CertificateExpired
//!   error.CertificateIssuerMismatch
//!   error.TlsAlert{desc = "unknown CA"}   ← lose the most common cause
//!   error.TlsHandshakeFailed
//!   error.ConnectionRefused
//!
//! which is useless for a sysadmin trying to figure out whether they
//! forgot to mount `/etc/ssl/certs`, run behind an NGINX terminating TLS
//! without a cert, or hit an out-of-date system clock. The transcriber
//! classifies the raw error into a stable enum the caller can `try` on,
//! and `describeTransportError` produces the one-line hint we surface in
//! `cli/api.zig::getRaw` (called from `cli/update.zig` and the daemon
//! CLI's release-fetch path).

const std = @import("std");

/// Classified error set for any TLS / transport fault the CLI hits while
/// talking to an *external* service. Routing these through the union
/// lets callers `switch (e)` for telemetry + a per-class hint, instead
/// of matching ten near-identical std error names.
pub const TransportError = error{
    /// Server presented a certificate signed by an unknown / private
    /// CA, or one whose signature / public key we couldn't validate.
    /// Most self-host fixes live here.
    TlsCertificateUntrusted,
    /// Cert chain reached a trusted root but the leaf is outside its
    /// validity window (NotYetValid / Expired). Almost always a system
    /// clock issue or a forgotten cert rotation.
    TlsCertificateExpired,
    /// Cert is otherwise valid but the hostname doesn't match
    /// (CN / SAN). Typical fix: ensure the URL you're calling matches
    /// the cert's `Subject Alternative Name`, not just an alias or
    /// `:port`.
    TlsCertificateHostMismatch,
    /// TLS handshake itself failed for a protocol-level reason
    /// (unexpected message, bad MAC, decode error). Usually a server
    /// bug or a proxy mangling TLS. Try the same call against an
    /// external network to isolate.
    TlsHandshakeFailed,
    /// Plain TCP-level failure (refused / unreachable / timeout). The
    /// remote wasn't even able to speak TLS — DNS or routing problem.
    TransportUnreachable,
    /// Catch-all bucket. The original error name is preserved in logs
    /// via `describeTransportError`.
    TransportUnknown,
};

/// Map a raw error from `std.http.Client`, `std.Io.net.Stream`, or
/// `std.crypto.tls.Client` onto a stable `TransportError` variant.
/// Doesn't throw — purely a classifier.
pub fn transcribeTransportError(err: anyerror) TransportError {
    return switch (err) {
        // === Trust / chain issues ===
        error.CertificateExpired,
        error.CertificateNotYetValid => TransportError.TlsCertificateExpired,
        error.CertificateIssuerMismatch,
        error.TlsCertificateNotVerified,
        error.CertificateSignatureInvalid,
        error.CertificateSignatureInvalidLength,
        error.CertificateSignatureAlgorithmUnsupported,
        error.CertificateSignatureAlgorithmMismatch,
        error.CertificateSignatureNamedCurveUnsupported,
        error.CertificateSignatureUnsupportedBitCount,
        error.CertificatePublicKeyInvalid,
        error.TlsAlert,
        => TransportError.TlsCertificateUntrusted,
        error.CertificateHostMismatch => TransportError.TlsCertificateHostMismatch,

        // === TLS wire-protocol / handshake ===
        error.TlsHandshakeFailed,
        error.TlsInitializationFailed,
        error.TlsDecryptFailure,
        error.TlsUnexpectedMessage,
        error.TlsIllegalParameter,
        error.TlsBadRecordMac,
        error.TlsBadLength,
        error.TlsBadSignatureScheme,
        error.TlsBadRsaSignatureBitCount,
        error.TlsDecodeError,
        error.TlsRecordOverflow,
        error.TlsConnectionTruncated,
        error.TlsSequenceOverflow,
        => TransportError.TlsHandshakeFailed,

        // === Plain TCP ===
        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.ConnectionResetByPeer,
        error.NetworkDown,
        error.ConnectionTimedOut,
        error.TimedOut,
        => TransportError.TransportUnreachable,

        // === Anything else — keep the original error name in logs. ===
        else => TransportError.TransportUnknown,
    };
}

/// Compose the user-facing description for `raw_err` against `host`.
/// Writes into the caller-provided `out` buffer; the formatted slice is
/// returned. The string is English on purpose (CLI diagnostics),
/// mirrors the host inline so it's grep-friendly, and hands the sysadmin
/// the exact fix (mount CA bundle / rotate cert / check clock / etc).
pub fn describeTransportError(
    raw_err: anyerror,
    host: []const u8,
    out: []u8,
) []u8 {
    const kind = transcribeTransportError(raw_err);
    const err_name: []const u8 = @errorName(raw_err);

    // Each branch is its own comptime-known format string with the
    // host (and runtime error name) interpolated as runtime args.
    // zig's `std.fmt.bufPrint` requires a comptime format string, so
    // each variant gets a dedicated call instead of a switch. The
    // `catch fallback(...)` ensures we always return *some* useful
    // text even when the buffer is too small.
    const result = switch (kind) {
        TransportError.TlsCertificateExpired => std.fmt.bufPrint(
            out,
            "TLS handshake to {s} failed: server certificate is expired or not yet valid — " ++
                "check the system clock on the host running 1p, then ask the {s} admin to rotate the certificate",
            .{ host, host },
        ) catch fallback(out, host, err_name),
        TransportError.TlsCertificateUntrusted => std.fmt.bufPrint(
            out,
            "TLS handshake to {s} failed: server certificate isn't trusted by the system CA bundle — " ++
                "if {s} uses a private CA, mount its root certificate into the 1p host (e.g. " ++
                "`SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`) or set `SSL_CERT_DIR` to a directory " ++
                "containing the private-CA PEM",
            .{ host, host },
        ) catch fallback(out, host, err_name),
        TransportError.TlsCertificateHostMismatch => std.fmt.bufPrint(
            out,
            "TLS handshake to {s} failed: certificate is valid but doesn't match this hostname — " ++
                "the cert's `Subject Alternative Name` doesn't include {s}; check the URL you're using and any DNS / proxy rewrites",
            .{ host, host },
        ) catch fallback(out, host, err_name),
        TransportError.TlsHandshakeFailed => std.fmt.bufPrint(
            out,
            "TLS handshake to {s} aborted at the protocol layer — " ++
                "this is usually a server bug or a TLS-interception proxy tampering with the stream. " ++
                "Try `openssl s_client -connect {s}:443 -servername {s}` from the 1p host to reproduce",
            .{ host, host, host },
        ) catch fallback(out, host, err_name),
        TransportError.TransportUnreachable => std.fmt.bufPrint(
            out,
            "could not reach {s}: {s} — verify DNS resolves, the destination port is open, and no egress proxy / firewall is blocking it",
            .{ host, err_name },
        ) catch fallback(out, host, err_name),
        TransportError.TransportUnknown => std.fmt.bufPrint(
            out,
            "transport error talking to {s}: {s} — capture a packet trace or `curl -v` and file an issue if it persists",
            .{ host, err_name },
        ) catch fallback(out, host, err_name),
    };

    return result;
}

/// Last-ditch line used when the variant message doesn't fit in `out`
/// or one of the runtime `{s}` substitutions fails to write. Keeps the
/// call sites terse without compromising on the always-available
/// diagnostic information (which host, which std error name).
fn fallback(out: []u8, host: []const u8, err_name: []const u8) []u8 {
    return std.fmt.bufPrint(out, "transport error talking to {s}: {s}", .{ host, err_name }) catch
        out[0..0];
}

test "transcribe: each error family lands in the right bucket" {
    try std.testing.expectEqual(TransportError.TlsCertificateExpired, transcribeTransportError(error.CertificateExpired));
    try std.testing.expectEqual(TransportError.TlsCertificateExpired, transcribeTransportError(error.CertificateNotYetValid));
    try std.testing.expectEqual(TransportError.TlsCertificateUntrusted, transcribeTransportError(error.CertificateIssuerMismatch));
    try std.testing.expectEqual(TransportError.TlsCertificateUntrusted, transcribeTransportError(error.TlsAlert));
    try std.testing.expectEqual(TransportError.TlsCertificateHostMismatch, transcribeTransportError(error.CertificateHostMismatch));
    try std.testing.expectEqual(TransportError.TlsHandshakeFailed, transcribeTransportError(error.TlsHandshakeFailed));
    try std.testing.expectEqual(TransportError.TlsHandshakeFailed, transcribeTransportError(error.TlsDecryptFailure));
    try std.testing.expectEqual(TransportError.TransportUnreachable, transcribeTransportError(error.ConnectionRefused));
    try std.testing.expectEqual(TransportError.TransportUnreachable, transcribeTransportError(error.TimedOut));
}

test "describe: each variant produces a host-tagged English line under 512 chars" {
    var buf: [512]u8 = undefined;
    const cases = [_]anyerror{
        error.CertificateExpired,
        error.CertificateIssuerMismatch,
        error.CertificateHostMismatch,
        error.TlsHandshakeFailed,
        error.ConnectionRefused,
        error.RandomMadeUpOuterErr,
    };
    for (cases) |err| {
        const s = describeTransportError(err, "api.example.com", &buf);
        try std.testing.expect(s.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, s, "api.example.com") != null);
        try std.testing.expect(s.len < 512);
    }
}

test "describe: explains the most common self-host fix (private CA -> mount cert)" {
    var buf: [512]u8 = undefined;
    const s = describeTransportError(error.TlsAlert, "github.example.local", &buf);
    try std.testing.expect(std.mem.indexOf(u8, s, "private CA") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "SSL_CERT_FILE") != null);
}

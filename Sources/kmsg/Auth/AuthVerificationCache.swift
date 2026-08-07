import Foundation

/// TTL cache for "the KakaoTalk session was verified logged-in recently".
///
/// Why: the full auth check (window reopen probe, post-login dialog sweep,
/// chat-list/login-window classification) costs 3-4s of AX round-trips on a
/// busy machine, and the bridge runs dozens of commands a minute — 25% of its
/// wall-clock went to re-verifying a state that changes about once a month
/// (measured 2026-08-07: p50 auth 2.7-3.9s across 48 commands / 10 min).
///
/// Contract:
/// - `markVerified()` after any full check that concluded logged-in.
/// - `isFresh` gates skipping the full check; callers must still hold a cheap
///   usable-window handle before trusting it.
/// - `invalidate()` whenever a command run FAILS for any reason — a stale
///   "logged in" verdict must not outlive evidence to the contrary, so the
///   next command pays for a full check (and can auto-login).
/// - TTL via KMSG_AUTH_CACHE_TTL_SECONDS; 0 disables the cache (kill switch).
enum AuthVerificationCache {
    static let fileURL = AuthPaths.configDirectoryURL
        .appendingPathComponent("auth-verified")

    static var ttlSeconds: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["KMSG_AUTH_CACHE_TTL_SECONDS"],
           let value = TimeInterval(raw) {
            return max(0, value)
        }
        return 600
    }

    static var isFresh: Bool {
        let ttl = ttlSeconds
        guard ttl > 0 else {
            return false
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modified = attrs[.modificationDate] as? Date else {
            return false
        }
        // A future mtime means clock skew or a corrupt file — treat as stale.
        let age = Date().timeIntervalSince(modified)
        return age >= 0 && age < ttl
    }

    static func markVerified() {
        guard ttlSeconds > 0 else {
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(
            at: AuthPaths.configDirectoryURL,
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        } else {
            fm.createFile(atPath: fileURL.path, contents: Data())
        }
    }

    static func invalidate() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

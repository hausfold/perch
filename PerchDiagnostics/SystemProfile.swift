import Foundation

/// The Mac underneath: which macOS, which model.
///
/// Two lines, shared for one reason — they are quoted in two places that must
/// agree. The app writes them into the bug form's diagnostics block, and
/// `perch doctor` prints them on a machine where the app may never have run.
/// A maintainer reading an issue and a maintainer reading a pasted `doctor`
/// should be reading the same strings, spelled the same way.
///
/// Nothing here is identifying: an OS build and a hardware model, both of which
/// a reporter would be asked for anyway. No serial, no host name, no user.
enum SystemProfile {
    /// `26.0.1 (25A354)` — the pair Apple's own bug reports ask for, because a
    /// build number distinguishes two OSes that answer the same to a user.
    static var operatingSystem: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let short = "\(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        guard let build = sysctl("kern.osversion") else { return short }
        return "\(short) (\(build))"
    }

    /// `Mac16,10`. The marketing name would read better and is not available
    /// without a network round trip to Apple, so this is the identifier — which
    /// is what a maintainer would look up anyway.
    static var model: String { sysctl("hw.model") ?? "unknown Mac" }

    /// `sysctlbyname`, not a `sysctl` subprocess: the app is sandboxed and the
    /// two keys read here are both allowed to a sandboxed process, while
    /// spawning `/usr/sbin/sysctl` is not.
    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // sysctl reports the length *including* the NUL, which `String(decoding:)`
        // would keep as a U+0000 on the end of the model identifier.
        let value = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        return value.isEmpty ? nil : value
    }
}

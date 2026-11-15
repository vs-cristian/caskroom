import Foundation

/// Whether sudo authenticates with Touch ID. sudo skips `pam_tid` in askpass mode,
/// so when it's enabled brew runs without `SUDO_ASKPASS` and sudo shows the Touch
/// ID sheet itself. Cancelling that sheet fails the command: with no terminal,
/// sudo can't fall back to a password.
public enum SudoTouchID {
    /// `sudo_local` is where macOS's template puts it, and survives OS updates.
    public static let defaultPAMFiles = ["/etc/pam.d/sudo_local", "/etc/pam.d/sudo"]
        .map { URL(fileURLWithPath: $0) }

    /// True when any of `pamFiles` has an uncommented `auth sufficient pam_tid.so` line
    /// (the module may be named by path, or with its version: `pam_tid.so.2`).
    public static func isEnabled(pamFiles: [URL] = defaultPAMFiles) -> Bool {
        pamFiles.contains { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.split(whereSeparator: \.isNewline).contains { line in
                let fields = line.prefix { $0 != "#" }.split(whereSeparator: \.isWhitespace)
                return fields.count >= 3
                    && fields[0] == "auth"
                    && fields[1] == "sufficient"
                    && fields[2].split(separator: "/").last?.hasPrefix("pam_tid.so") == true
            }
        }
    }
}

import Foundation

/// The installer packages behind an app, from macOS's receipts (`pkgutil`).
public enum InstallerReceipts {
    /// Packages that installed the app's bundle, or whose ID starts with the app's.
    public static func packages(for app: AppIdentity) async -> [String] {
        var ids: [String] = []
        let info = await run("/usr/sbin/pkgutil", ["--file-info", app.path])
        for line in info.split(separator: "\n") where line.hasPrefix("pkgid: ") {
            ids.append(String(line.dropFirst(7)))
        }
        if let bundleID = app.bundleID?.lowercased(), LeftoverFinder.Matcher.isSpecific(bundleID) {
            let all = await run("/usr/sbin/pkgutil", ["--pkgs"])
            for id in all.split(separator: "\n").map(String.init)
            where id.lowercased() == bundleID || id.lowercased().hasPrefix(bundleID + ".") {
                ids.append(id)
            }
        }
        return Array(Set(ids)).sorted()
    }

    /// Absolute paths of everything `package` installed.
    public static func files(of package: String) async -> [String] {
        let info = await run("/usr/sbin/pkgutil", ["--pkg-info", package])
        var volume = "/", location = ""
        for line in info.split(separator: "\n") {
            if line.hasPrefix("volume: ") { volume = String(line.dropFirst(8)) }
            if line.hasPrefix("location: ") { location = String(line.dropFirst(10)) }
        }
        let base = URL(fileURLWithPath: volume).appending(path: location)
        return await run("/usr/sbin/pkgutil", ["--files", package])
            .split(separator: "\n")
            .map { base.appending(path: String($0)).standardizedFileURL.path }
    }
}

/// What removing an app did.
public struct RemovalOutcome: Sendable, Equatable {
    public struct Failure: Sendable, Hashable {
        public let path: String
        public let reason: String
    }

    /// Paths now in the Trash.
    public var moved: [String] = []
    public var failed: [Failure] = []
    /// Installer receipts macOS no longer keeps.
    public var forgotten: [String] = []
    /// Nothing that needed an administrator was done: the password or Touch ID
    /// was cancelled.
    public var administratorDeclined = false

    public init() {}
}

/// Moves an app and its leftovers to the Trash, after stopping its launch
/// agents and daemons, and forgets its installer receipts. What only root may
/// move goes in one sudo call, so there's one password prompt at most.
public struct AppRemover: Sendable {
    public let runner: BrewRunner?
    public let home: URL

    public init(runner: BrewRunner?, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.runner = runner
        self.home = home
    }

    /// Moves `items` to the Trash, unloading launchd plists among them first.
    /// `receipts` are forgotten once `appPath` is gone, and only when an
    /// administrator is asked anyway: a receipt alone isn't worth a password.
    public func remove(_ items: [Leftover], forgetting receipts: [String] = [], onceGone appPath: String, appName: String) async -> RemovalOutcome {
        var outcome = RemovalOutcome()
        var privileged: [Leftover] = []
        let uid = getuid()
        for item in items {
            guard FileManager.default.fileExists(atPath: item.path) || isSymlink(item.path) else { continue }
            if item.needsAdministrator {
                privileged.append(item)
                continue
            }
            if item.isLaunchItem {
                _ = await run("/bin/launchctl", ["bootout", "gui/\(uid)", item.path])
            }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                outcome.moved.append(item.path)
            } catch {
                if Self.isPermissionError(error), !item.path.hasPrefix(home.path + "/") {
                    privileged.append(item)
                } else {
                    outcome.failed.append(.init(path: item.path, reason: Self.reason(for: error, path: item.path)))
                }
            }
        }
        guard !privileged.isEmpty else { return outcome }
        guard let runner else {
            outcome.failed += privileged.map { .init(path: $0.path, reason: "Removing this needs an administrator.") }
            return outcome
        }
        let script = Self.script(moving: privileged.map(\.path), toTrash: home.appending(path: ".Trash").path,
                                 forgetting: receipts, onceGone: appPath, uid: uid)
        var reported: Set<String> = []
        do {
            let reason = "Caskroom needs an administrator password to move \(appName)'s system files to the Trash."
            for try await line in runner.privileged(script, reason: reason) where line.stream == .stdout {
                let fields = line.text.split(separator: "\t", maxSplits: 2).map(String.init)
                guard fields.count >= 2 else { continue }
                reported.insert(fields[1])
                switch fields[0] {
                case "moved": outcome.moved.append(fields[1])
                case "forgot": outcome.forgotten.append(fields[1])
                case "failed": outcome.failed.append(.init(path: fields[1], reason: fields.count > 2 ? Self.reason(forShell: fields[2]) : "It couldn't be moved."))
                default: break
                }
            }
        } catch {
            // sudo itself failed: no password, or Touch ID cancelled.
            outcome.administratorDeclined = reported.isEmpty
        }
        for item in privileged where !reported.contains(item.path) {
            outcome.failed.append(.init(path: item.path, reason: "This needs an administrator, and none was given."))
        }
        return outcome
    }

    /// The root half: unload launchd plists, move each path into the user's
    /// Trash under a free name (Finder's "name 2"), forget receipts. Every
    /// result is a tab-separated line, so one failure doesn't hide the rest.
    static func script(moving paths: [String], toTrash trash: String, forgetting receipts: [String], onceGone appPath: String, uid: uid_t) -> String {
        var lines = [
            "T=\(quote(trash))",
            #"trash() { n=$(basename "$1"); d="$T/$n"; i=2; while [ -e "$d" ] || [ -L "$d" ]; do d="$T/$n $i"; i=$((i+1)); done; if err=$(mv -- "$1" "$d" 2>&1); then printf 'moved\t%s\n' "$1"; else printf 'failed\t%s\t%s\n' "$1" "$err"; fi; }"#,
        ]
        for path in paths where path.hasSuffix(".plist") {
            if path.hasPrefix("/Library/LaunchDaemons/") {
                lines.append("launchctl bootout system \(quote(path)) >/dev/null 2>&1")
            } else if path.hasPrefix("/Library/LaunchAgents/") {
                lines.append("launchctl bootout gui/\(uid) \(quote(path)) >/dev/null 2>&1")
            }
        }
        lines += paths.map { "trash \(quote($0))" }
        lines += receipts.map {
            "if [ ! -e \(quote(appPath)) ]; then pkgutil --forget \(quote($0)) >/dev/null 2>&1 && printf 'forgot\\t%s\\n' \(quote($0)); fi"
        }
        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteNoPermissionError { return true }
        let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
        return underlying.domain == NSPOSIXErrorDomain && (underlying.code == Int(EACCES) || underlying.code == Int(EPERM))
    }

    /// Mostly macOS's privacy protection: another app's container, or a folder
    /// that needs Full Disk Access.
    static func reason(for error: Error, path: String) -> String {
        if isPermissionError(error) {
            return path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/")
                ? "macOS protects other apps' data. Allow Caskroom to access it when asked, or under System Settings ▸ Privacy & Security ▸ Full Disk Access."
                : "macOS didn't allow it. Allow Caskroom under System Settings ▸ Privacy & Security ▸ Full Disk Access, then try again."
        }
        return (error as NSError).localizedDescription
    }

    static func reason(forShell message: String) -> String {
        message.contains("Operation not permitted")
            ? "macOS didn't allow it, even for an administrator. Allow Caskroom under System Settings ▸ Privacy & Security ▸ Full Disk Access, or App Management for an app, then try again."
            : message
    }
}

/// Runs a system tool to completion and returns its stdout; empty on failure.
func run(_ executable: String, _ args: [String]) async -> String {
    await withCheckedContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let output = OutputBuffer()
        let group = DispatchGroup()
        group.enter()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        do {
            try process.run()
        } catch {
            continuation.resume(returning: "")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            continuation.resume(returning: String(decoding: output.data, as: UTF8.self))
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    var data = Data()
}

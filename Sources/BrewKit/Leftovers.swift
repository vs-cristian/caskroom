import Foundation

/// A file or folder an app left outside its bundle.
public struct Leftover: Identifiable, Hashable, Sendable {
    /// Why it's thought to belong to the app, most certain first.
    public enum Evidence: Int, Comparable, Sendable {
        /// Listed in the cask's `zap` stanza, which Homebrew's maintainers keep.
        case homebrew
        /// Put there by the app's installer package, by its receipt.
        case installer
        /// Named by one of the app's bundle IDs, or a bundle with one.
        case bundleID
        /// A launch agent or daemon that runs something inside the app or its helper.
        case launchItem
        /// A crash report of the app's executable.
        case crashReport
        /// A group container of the app's developer, and no other app of theirs is installed.
        case developer
        /// A Library folder named like the app (`Application Support/Example`),
        /// and like no other app installed.
        case name
        /// A group container of the app's developer, which their other apps may share.
        case sharedWithDeveloper
        /// A dotfile in the home folder named like the app (`~/.example`). Command-line
        /// tools use these too, often one of the same name, so it's never ticked by default.
        case dotfile

        public static func < (a: Evidence, b: Evidence) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String { path }
    public let path: String
    public let evidence: Evidence
    /// Owned by root, or in a folder only root can change: removing it needs an
    /// administrator.
    public let needsAdministrator: Bool

    public init(path: String, evidence: Evidence, needsAdministrator: Bool = false) {
        self.path = path
        self.evidence = evidence
        self.needsAdministrator = needsAdministrator
    }

    /// Whether it's ticked to be removed unless you untick it.
    public var isCertain: Bool { evidence < .sharedWithDeveloper }

    /// A launch agent or daemon's plist, which should be unloaded before it goes.
    public var isLaunchItem: Bool {
        path.hasSuffix(".plist") && (path.contains("/Library/LaunchAgents/") || path.contains("/Library/LaunchDaemons/"))
    }
}

/// Another installed app, to keep its files when they look like the one being removed.
public struct InstalledApp: Hashable, Sendable {
    public let bundleID: String
    public let teamID: String?
    public let name: String

    public init(bundleID: String, teamID: String? = nil, name: String) {
        self.bundleID = bundleID
        self.teamID = teamID
        self.name = name
    }
}

/// Finds what an app left in the places macOS apps keep things: by bundle ID,
/// developer and name in the Library folders, the user's and the system's,
/// plus the cask's `zap` list and the installer's receipt when there are any.
public struct LeftoverFinder: Sendable {
    public var home: URL
    /// `/`, or a stand-in in tests.
    public var root: URL
    /// The user's cache and temporary folders under /private/var/folders
    /// (`DARWIN_USER_CACHE_DIR`, `DARWIN_USER_TEMP_DIR`).
    public var temporaryFolders: [URL]
    /// Every other app installed, whose files look like this one's.
    public var otherApps: [InstalledApp]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        root: URL = URL(fileURLWithPath: "/"),
        temporaryFolders: [URL] = LeftoverFinder.userTemporaryFolders,
        otherApps: [InstalledApp] = []
    ) {
        self.home = home.standardizedFileURL
        self.root = root.standardizedFileURL
        self.temporaryFolders = temporaryFolders
        self.otherApps = otherApps
    }

    public static var userTemporaryFolders: [URL] {
        [_CS_DARWIN_USER_CACHE_DIR, _CS_DARWIN_USER_TEMP_DIR].compactMap { name in
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard confstr(name, &buffer, buffer.count) > 0 else { return nil }
            return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL
        }
    }

    /// How a folder's entries are matched against the app.
    struct Rule: OptionSet {
        let rawValue: Int
        /// The entry's name is a bundle ID of the app (`com.example.app.plist`,
        /// `com.example.app.helper`, `TEAMID.com.example.app`).
        static let bundleID = Rule(rawValue: 1)
        /// The entry is named like the app (`Application Support/Example`).
        static let name = Rule(rawValue: 2)
        /// A group container: `TEAMID.anything`.
        static let developer = Rule(rawValue: 4)
        /// The entry is a bundle (a plug-in, a Quick Look extension) whose ID is the app's.
        static let bundle = Rule(rawValue: 8)
        /// A launchd plist whose program is inside the app, or is one of its helpers.
        static let launchPlist = Rule(rawValue: 16)
        /// The entry is a privileged helper of the app, by name.
        static let helper = Rule(rawValue: 32)
        /// A crash report: the executable's name, then `-` or `_`.
        static let crashReport = Rule(rawValue: 64)
        /// A dotfile or `.config` folder named like the app, lowercased (`~/.example`).
        static let dotName = Rule(rawValue: 128)
    }

    /// The folders searched in the home folder, with how.
    static let userLocations: [(String, Rule)] = [
        ("Library/Application Support", [.bundleID, .name]),
        ("Library/Application Support/CrashReporter", [.crashReport]),
        ("Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments", [.bundleID]),
        ("Library/Application Scripts", [.bundleID]),
        ("Library/Caches", [.bundleID, .name]),
        ("Library/Containers", [.bundleID]),
        ("Library/Group Containers", [.bundleID, .developer]),
        ("Library/Preferences", [.bundleID]),
        ("Library/Preferences/ByHost", [.bundleID]),
        ("Library/Saved Application State", [.bundleID]),
        ("Library/HTTPStorages", [.bundleID]),
        ("Library/WebKit", [.bundleID]),
        ("Library/Cookies", [.bundleID]),
        ("Library/Logs", [.bundleID, .name]),
        ("Library/Logs/DiagnosticReports", [.crashReport]),
        ("Library/LaunchAgents", [.bundleID, .launchPlist]),
        ("Library/Internet Plug-Ins", [.bundle]),
        ("Library/QuickLook", [.bundle]),
        ("Library/PreferencePanes", [.bundle]),
        ("Library/Services", [.bundle]),
        ("Library/Screen Savers", [.bundle]),
        ("Library/Spotlight", [.bundle]),
        ("", [.dotName]),
        (".config", [.dotName]),
    ]

    /// The same under `/`, where removing anything needs an administrator.
    static let systemLocations: [(String, Rule)] = [
        ("Library/Application Support", [.bundleID, .name]),
        ("Library/Caches", [.bundleID]),
        ("Library/Preferences", [.bundleID]),
        ("Library/Logs", [.bundleID, .name]),
        ("Library/Logs/DiagnosticReports", [.crashReport]),
        ("Library/LaunchAgents", [.bundleID, .launchPlist, .helper]),
        ("Library/LaunchDaemons", [.bundleID, .launchPlist, .helper]),
        ("Library/PrivilegedHelperTools", [.bundleID, .helper]),
        ("Library/Internet Plug-Ins", [.bundle]),
        ("Library/QuickLook", [.bundle]),
        ("Library/PreferencePanes", [.bundle]),
        ("Library/Screen Savers", [.bundle]),
        ("Library/Spotlight", [.bundle]),
        ("Library/Audio/Plug-Ins/HAL", [.bundle]),
        ("Library/Audio/Plug-Ins/Components", [.bundle]),
    ]

    /// Names too generic to say which app a folder belongs to.
    static let genericNames: Set<String> = [
        "app", "application", "applications", "helper", "helpers", "updater", "update", "launcher",
        "agent", "daemon", "service", "services", "electron", "chromium", "java", "python", "node",
        "library", "support", "data", "cache", "caches", "logs", "temp", "tmp", "config", "settings",
        "apple", "google", "microsoft", "adobe", "mozilla", "jetbrains", "github", "local", "share",
    ]

    /// Everything of `app`'s found outside it, most certain first, then by path.
    /// `zapPaths` are the cask's, as written; `receiptFiles` are absolute paths
    /// its installer packages list.
    public func find(for app: AppIdentity, zapPaths: [String] = [], receiptFiles: [String] = []) -> [Leftover] {
        // Another copy of the same app shares every one of these files.
        if let id = app.bundleID?.lowercased(), otherApps.contains(where: { $0.bundleID.lowercased() == id }) { return [] }
        var found: [String: Leftover.Evidence] = [:]
        func add(_ path: String, _ evidence: Leftover.Evidence) {
            let path = URL(fileURLWithPath: path).standardizedFileURL.path
            guard isRemovable(path, app: app) else { return }
            if let existing = found[path], existing <= evidence { return }
            found[path] = evidence
        }

        for path in expand(zapPaths) { add(path, .homebrew) }
        for path in ownedByReceipt(receiptFiles, app: app) { add(path, .installer) }

        let matcher = Matcher(app: app, others: otherApps)
        for (relative, rule) in Self.userLocations {
            let folder = relative.isEmpty ? home : home.appending(path: relative)
            for (path, evidence) in matches(in: folder, rule: rule, matcher: matcher) { add(path, evidence) }
        }
        for (relative, rule) in Self.systemLocations {
            for (path, evidence) in matches(in: root.appending(path: relative), rule: rule, matcher: matcher) { add(path, evidence) }
        }
        for folder in temporaryFolders {
            for (path, evidence) in matches(in: folder, rule: .bundleID, matcher: matcher) { add(path, evidence) }
        }

        // Inside something already listed: that goes with it.
        let paths = found.keys.sorted()
        let outermost = paths.filter { path in
            !paths.contains { other in other != path && path.hasPrefix(other + "/") }
        }
        return outermost
            .map { Leftover(path: $0, evidence: found[$0]!, needsAdministrator: Self.needsAdministrator($0)) }
            .sorted { ($0.evidence, $0.path) < ($1.evidence, $1.path) }
    }

    // MARK: Matching

    private func matches(in folder: URL, rule: Rule, matcher: Matcher) -> [(String, Leftover.Evidence)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var result: [(String, Leftover.Evidence)] = []
        for entry in entries {
            let path = folder.appending(path: entry).path
            if rule.contains(.dotName) {
                // Only dotfiles in home, and only folders in .config.
                let name = folder == home ? (entry.hasPrefix(".") ? String(entry.dropFirst()) : nil) : entry
                if let name, matcher.isNamedLikeApp(name, lowercasedOnly: true) { result.append((path, .dotfile)) }
                continue
            }
            if entry.hasPrefix(".") { continue }
            if rule.contains(.bundleID), matcher.ownsIdentifier(entry) {
                result.append((path, .bundleID)); continue
            }
            if rule.contains(.helper), matcher.isHelper(entry) {
                result.append((path, .bundleID)); continue
            }
            if rule.contains(.launchPlist), entry.hasSuffix(".plist"), matcher.isLaunchPlist(at: path) {
                result.append((path, .launchItem)); continue
            }
            if rule.contains(.bundle), let id = AppIdentity.infoDictionary(of: URL(fileURLWithPath: path))?["CFBundleIdentifier"] as? String,
               matcher.ownsIdentifier(id) {
                result.append((path, .bundleID)); continue
            }
            if rule.contains(.crashReport), matcher.isCrashReport(entry) {
                result.append((path, .crashReport)); continue
            }
            if rule.contains(.developer), let evidence = matcher.developerEvidence(entry) {
                result.append((path, evidence)); continue
            }
            if rule.contains(.name), matcher.isNamedLikeApp(entry, lowercasedOnly: false) {
                result.append((path, .name))
            }
        }
        return result
    }

    struct Matcher {
        let app: AppIdentity
        /// Lowercased: (ID, whether it's this app's). Longest first, so the most
        /// specific owner wins: `com.example.app.beta` belongs to the beta even
        /// while `com.example.app` is being removed.
        let identifiers: [(id: String, ours: Bool)]
        let otherNames: Set<String>
        let otherTeams: Set<String>
        let names: [String]
        let helpers: Set<String>

        init(app: AppIdentity, others: [InstalledApp]) {
            self.app = app
            let ours = app.bundleIDs.map { $0.lowercased() }.filter(Self.isSpecific)
            let theirs = others.map { $0.bundleID.lowercased() }.filter(Self.isSpecific)
            // A tie goes to the other app: two copies of one app share their files.
            identifiers = (ours.map { ($0, true) } + theirs.map { ($0, false) })
                .sorted { $0.0.count != $1.0.count ? $0.0.count > $1.0.count : !$0.1 && $1.1 }
            otherNames = Set(others.map { $0.name.lowercased() })
            otherTeams = Set(others.compactMap(\.teamID))
            names = app.names.filter { !LeftoverFinder.genericNames.contains($0.lowercased()) }
            helpers = Set(app.helperNames)
        }

        /// IDs like `app` or `com.x` say too little.
        static func isSpecific(_ id: String) -> Bool {
            id.count >= 6 && id.split(separator: ".").count >= 2
        }

        /// An entry named by one of the app's IDs: exactly, as a prefix before
        /// a dot (`com.example.app.plist`, `.helper`, ByHost's `.<UUID>.plist`),
        /// or after a team or group prefix (`TEAMID.com.example.app`).
        func ownsIdentifier(_ entry: String) -> Bool {
            let name = entry.lowercased()
            for (id, ours) in identifiers {
                if name == id || name.hasPrefix(id + ".") || name.hasSuffix("." + id) || name.contains("." + id + ".") {
                    return ours
                }
            }
            return false
        }

        func isHelper(_ entry: String) -> Bool {
            let name = entry.hasSuffix(".plist") ? String(entry.dropLast(6)) : entry
            return helpers.contains(name)
        }

        /// A launchd plist whose program is inside the app, or one of its
        /// privileged helpers, or that names the app as its owner.
        func isLaunchPlist(at path: String) -> Bool {
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
            let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
            if let program {
                if program.hasPrefix(app.path + "/") { return true }
                if program.hasPrefix("/Library/PrivilegedHelperTools/"), helpers.contains((program as NSString).lastPathComponent) { return true }
            }
            let associated = plist["AssociatedBundleIdentifiers"] as? [String] ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
            return associated.contains { ownsIdentifier($0) }
        }

        /// `Example-2026-01-02-030405.ips`, `Example_2026-01-02-030405_Mac.crash`.
        func isCrashReport(_ entry: String) -> Bool {
            names.contains { name in
                guard !otherNames.contains(name.lowercased()) else { return false }
                return entry.hasPrefix(name + "-") || entry.hasPrefix(name + "_")
            }
        }

        /// A group container named for the app's team: `TEAMID.group.anything`.
        func developerEvidence(_ entry: String) -> Leftover.Evidence? {
            guard let team = app.teamID, entry.hasPrefix(team + ".") else { return nil }
            return otherTeams.contains(team) ? .sharedWithDeveloper : .developer
        }

        func isNamedLikeApp(_ entry: String, lowercasedOnly: Bool) -> Bool {
            let entry = (entry as NSString).deletingPathExtension.isEmpty ? entry : (entry as NSString).deletingPathExtension
            return names.contains { name in
                guard !otherNames.contains(name.lowercased()) else { return false }
                return lowercasedOnly
                    ? entry == name.lowercased() || entry == name.lowercased().replacingOccurrences(of: " ", with: "-")
                    : entry.caseInsensitiveCompare(name) == .orderedSame
            }
        }
    }

    // MARK: Homebrew's list and receipts

    /// `zap` paths with `~` and globs expanded, those that exist.
    func expand(_ patterns: [String]) -> [String] {
        patterns.flatMap { pattern -> [String] in
            var path = pattern
            if path == "~" || path.hasPrefix("~/") {
                path = home.path + path.dropFirst()
            } else if path.hasPrefix("/") {
                path = root.path == "/" ? path : root.path + path
            } else {
                return []
            }
            return glob(path)
        }
    }

    /// Of an installer's files, the outermost of each that the installer put
    /// there entirely: a folder counts only when everything in it is the
    /// installer's, so a shared folder (`/Library/Application Support`) never does.
    func ownedByReceipt(_ files: [String], app: AppIdentity) -> [String] {
        let listed = Set(files.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var owned: [String: Bool] = [:]
        func ownsAll(_ folder: String) -> Bool {
            if let known = owned[folder] { return known }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return false }
            let result = !entries.isEmpty && entries.allSatisfy { entry in
                let path = folder + "/" + entry
                guard listed.contains(path) else { return false }
                return !isDirectory(URL(fileURLWithPath: path)) || ownsAll(path)
            }
            owned[folder] = result
            return result
        }
        var result: Set<String> = []
        for file in listed where FileManager.default.fileExists(atPath: file) || isSymlink(file) {
            guard !isDirectory(URL(fileURLWithPath: file)) || ownsAll(file) else { continue }
            var path = file
            while true {
                let parent = (path as NSString).deletingLastPathComponent
                guard listed.contains(parent), !isProtected(parent), ownsAll(parent) else { break }
                path = parent
            }
            result.insert(path)
        }
        return result.sorted()
    }

    // MARK: Safety

    /// Folders that are never removed, nor anything holding them: home, the
    /// Library folders searched, and the top of the disk.
    private func isProtected(_ path: String) -> Bool {
        var protected: Set<String> = [home.path, root.path]
        for (relative, _) in Self.userLocations {
            var url = relative.isEmpty ? home : home.appending(path: relative)
            while url.path.hasPrefix(home.path), url.path != home.path {
                protected.insert(url.path)
                url = url.deletingLastPathComponent()
            }
        }
        for (relative, _) in Self.systemLocations {
            var url = root.appending(path: relative)
            while url.path != root.path, url.path.count > root.path.count {
                protected.insert(url.path)
                url = url.deletingLastPathComponent()
            }
        }
        for name in ["Applications", "System", "Users", "usr", "usr/local", "usr/local/bin", "usr/local/lib", "usr/local/share",
                     "bin", "sbin", "etc", "var", "private", "private/etc", "private/var", "private/tmp", "opt", "Library"] {
            protected.insert(root.appending(path: name).path)
        }
        for name in ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications", ".Trash", ".config", ".local", ".local/share", ".local/state", ".cache"] {
            protected.insert(home.appending(path: name).path)
        }
        protected.formUnion(temporaryFolders.map(\.path))
        return protected.contains(path)
    }

    private func isRemovable(_ path: String, app: AppIdentity) -> Bool {
        guard !isProtected(path),
              path != app.path, !path.hasPrefix(app.path + "/"), !app.path.hasPrefix(path + "/"),
              !path.hasPrefix(root.appending(path: "System").path + "/"),
              FileManager.default.fileExists(atPath: path) || isSymlink(path) else { return false }
        return true
    }

    /// Whether removing `path` takes root: it, or the folder it's in, isn't
    /// writable (a folder moves only if it's writable itself, to update `..`).
    /// Read from owner, group and mode rather than `access()`: macOS's privacy
    /// and App Management protection make that fail for paths you own, and
    /// root is no help against those.
    public static func needsAdministrator(_ path: String) -> Bool {
        if !isWritable((path as NSString).deletingLastPathComponent) { return true }
        return isDirectory(URL(fileURLWithPath: path)) && !isSymlink(path) && !isWritable(path)
    }

    private static func isWritable(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        let uid = getuid()
        if uid == 0 { return true }
        if info.st_uid == uid { return info.st_mode & S_IWUSR != 0 }
        let count = getgroups(0, nil)
        var groups = [gid_t](repeating: 0, count: Int(max(count, 0)))
        getgroups(count, &groups)
        if info.st_gid == getgid() || groups.contains(info.st_gid) { return info.st_mode & S_IWGRP != 0 }
        return info.st_mode & S_IWOTH != 0
    }
}

func isSymlink(_ path: String) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
}

/// The paths matching a shell pattern (`*`, `?`, `[…]`), or the path itself
/// when it has no pattern and exists.
func glob(_ pattern: String) -> [String] {
    var result = glob_t()
    defer { globfree(&result) }
    guard Darwin.glob(pattern, 0, nil, &result) == 0 else { return [] }
    return (0..<Int(result.gl_pathc)).compactMap { index in
        result.gl_pathv[index].map { String(cString: $0) }
    }
}

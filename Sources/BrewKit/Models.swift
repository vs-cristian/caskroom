import Foundation

public enum PackageKind: String, Hashable, Sendable, CaseIterable {
    case formula, cask

    /// The flag that pins a brew command to this kind, so a name shared by a
    /// formula and a cask resolves to the one meant.
    public var flag: String { "--\(rawValue)" }
}

/// Identifies a formula or cask by kind and name (a cask's name is its token).
public struct PackageRef: Hashable, Sendable {
    public let kind: PackageKind
    public let name: String

    public init(_ kind: PackageKind, _ name: String) {
        self.kind = kind
        self.name = name
    }
}

public struct Package: Identifiable, Hashable, Sendable {
    public var id: PackageRef { ref }
    public let ref: PackageRef
    public let fullName: String
    /// A cask's human name ("Claude Code"); nil for formulae.
    public let displayName: String?
    public let desc: String?
    public let homepage: URL?
    public let tap: String?
    public let latestVersion: String?
    public let installedVersions: [String]
    /// False for a formula pulled in only as a dependency. Casks are always on request.
    public let installedOnRequest: Bool
    public let pinned: Bool
    public let outdated: Bool
    public let caveats: String?
    public let dependencies: [PackageRef]
    public let deprecated: Bool
    public let disabled: Bool
    /// Why and when Homebrew deprecated it; nil unless deprecated.
    public let deprecation: Deprecation?
    /// Why and when Homebrew disabled it, or will: a deprecated package often
    /// has a date set for that already. Nil when neither.
    public let disabling: Deprecation?
    public let license: String?
    /// When the newest installed version was installed.
    public let installedAt: Date?
    /// Where a cask put its app bundle, if it has one.
    public let appPath: String?
    /// A cask whose app updates itself; brew lists it as outdated only when the
    /// app on disk is older than the cask, unless asked to be greedy.
    public let autoUpdates: Bool
    /// A cask with a `zap` stanza: files outside the app that uninstalling can delete.
    public let hasZap: Bool
    /// A cask whose `uninstall` stanza quits its app. brew quits such an app
    /// before upgrading it and reopens it after; any other is replaced while it runs.
    public let quitsApp: Bool
    /// Where a formula's source or a cask's download comes from.
    public let downloadURL: URL?
    /// A formula's development repository (`head`).
    public let headURL: URL?
    /// A formula brew installs without linking into its prefix's bin, so its
    /// commands aren't on PATH (often a versioned one, or one macOS also ships).
    public let kegOnly: Bool
    /// Why, as brew's symbol (`versioned_formula`, `provided_by_macos`…) or a
    /// maintainer's explanation.
    public let kegOnlyReason: String?
    /// Whether a version is linked into the prefix, even a keg-only one forced with `brew link --force`.
    public let linked: Bool
    /// The same software at other versions: `mysql@8.0` for `mysql@8.4`.
    public let otherVersions: [PackageRef]
    /// Packages that can't be installed beside this one.
    public let conflicts: [PackageRef]
    /// The oldest macOS a cask runs on ("13"), when it says.
    public let minimumMacOS: String?
    /// Names it had before a rename.
    public let oldNames: [String]

    public var kind: PackageKind { ref.kind }
    public var name: String { ref.name }
    /// What to call it: a cask's human name, else its name.
    public var title: String { displayName ?? name }
    public var isInstalled: Bool { !installedVersions.isEmpty }

    public init(
        ref: PackageRef, fullName: String, displayName: String? = nil, desc: String? = nil,
        homepage: URL? = nil, tap: String? = nil, latestVersion: String? = nil,
        installedVersions: [String] = [], installedOnRequest: Bool = true, pinned: Bool = false,
        outdated: Bool = false, caveats: String? = nil, dependencies: [PackageRef] = [],
        deprecated: Bool = false, disabled: Bool = false, deprecation: Deprecation? = nil,
        disabling: Deprecation? = nil, license: String? = nil,
        installedAt: Date? = nil, appPath: String? = nil, autoUpdates: Bool = false, hasZap: Bool = false,
        quitsApp: Bool = false, downloadURL: URL? = nil, headURL: URL? = nil,
        kegOnly: Bool = false, kegOnlyReason: String? = nil, linked: Bool = false,
        otherVersions: [PackageRef] = [], conflicts: [PackageRef] = [], minimumMacOS: String? = nil,
        oldNames: [String] = []
    ) {
        self.ref = ref
        self.fullName = fullName
        self.displayName = displayName
        self.desc = desc
        self.homepage = homepage
        self.tap = tap
        self.latestVersion = latestVersion
        self.installedVersions = installedVersions
        self.installedOnRequest = installedOnRequest
        self.pinned = pinned
        self.outdated = outdated
        self.caveats = caveats
        self.dependencies = dependencies
        self.deprecated = deprecated
        self.disabled = disabled
        self.deprecation = deprecation
        self.disabling = disabling
        self.license = license
        self.installedAt = installedAt
        self.appPath = appPath
        self.autoUpdates = autoUpdates
        self.hasZap = hasZap
        self.quitsApp = quitsApp
        self.downloadURL = downloadURL
        self.headURL = headURL
        self.kegOnly = kegOnly
        self.kegOnlyReason = kegOnlyReason
        self.linked = linked
        self.otherVersions = otherVersions
        self.conflicts = conflicts
        self.minimumMacOS = minimumMacOS
        self.oldNames = oldNames
    }
}

/// One of a package's `deprecate!` or `disable!` stanzas.
public struct Deprecation: Hashable, Sendable {
    /// brew's reason: a known symbol ("repo_archived", "unmaintained"…) or a
    /// maintainer's phrase that follows "because it" ("needs end-of-life Qt 5").
    public let reason: String?
    /// The formula or cask Homebrew suggests instead.
    public let replacement: PackageRef?
    public let date: Date?

    public init(reason: String? = nil, replacement: PackageRef? = nil, date: Date? = nil) {
        self.reason = reason
        self.replacement = replacement
        self.date = date
    }
}

public struct OutdatedItem: Identifiable, Hashable, Sendable {
    public var id: PackageRef { ref }
    public let ref: PackageRef
    public let installedVersions: [String]
    public let currentVersion: String
    public let pinned: Bool

    public init(ref: PackageRef, installedVersions: [String], currentVersion: String, pinned: Bool) {
        self.ref = ref
        self.installedVersions = installedVersions
        self.currentVersion = currentVersion
        self.pinned = pinned
    }
}

/// What `brew cleanup` would do, from its dry run.
public struct CleanupSummary: Hashable, Sendable {
    /// "1.2GB", as brew reports it; nil when nothing takes up space.
    public let reclaimable: String?
    /// Dependencies no installed package needs any more.
    public let unneededFormulae: [String]

    public var isEmpty: Bool { reclaimable == nil && unneededFormulae.isEmpty }

    public init(reclaimable: String? = nil, unneededFormulae: [String] = []) {
        self.reclaimable = reclaimable
        self.unneededFormulae = unneededFormulae
    }
}

/// What `brew vulns` found: installed formulae with known vulnerabilities,
/// according to OSV.dev. Casks aren't checked.
public struct VulnerabilityReport: Hashable, Sendable {
    /// Only formulae with open vulnerabilities, worst first.
    public let findings: [VulnerableFormula]
    /// How many formulae OSV.dev was asked about.
    public let checked: Int
    /// Formulae that couldn't be checked: no usable source URL, an untrusted
    /// tap, or an install brew couldn't place.
    public let unchecked: [String]

    public init(findings: [VulnerableFormula] = [], checked: Int = 0, unchecked: [String] = []) {
        self.findings = findings
        self.checked = checked
        self.unchecked = unchecked
    }
}

public struct VulnerableFormula: Identifiable, Hashable, Sendable {
    public var id: String { name }
    /// As brew names it: tap-qualified for a formula outside homebrew/core.
    public let name: String
    /// The version that was checked.
    public let version: String
    public let vulnerabilities: [Vulnerability]

    /// The installed formula, which goes by its short name.
    public var ref: PackageRef { PackageRef(.formula, name.split(separator: "/").last.map(String.init) ?? name) }

    public var highestSeverity: Vulnerability.Severity? {
        vulnerabilities.compactMap(\.severity).max()
    }

    /// Whether `version` (an update) is past a fixed version of every
    /// vulnerability. Nil when OSV.dev's fixes can't be compared, as when
    /// they're commits rather than releases.
    public func isFixed(by version: String) -> Bool? {
        var unknown = false
        for vulnerability in vulnerabilities {
            let fixes = vulnerability.fixedVersions.filter(VersionOrder.isComparable)
            if fixes.isEmpty {
                unknown = true
            } else if !fixes.contains(where: { VersionOrder.compare($0, version) != .orderedDescending }) {
                return false
            }
        }
        return unknown ? nil : true
    }

    public init(name: String, version: String, vulnerabilities: [Vulnerability]) {
        self.name = name
        self.version = version
        self.vulnerabilities = vulnerabilities
    }
}

public struct Vulnerability: Identifiable, Hashable, Sendable {
    public enum Severity: Int, Comparable, Hashable, Sendable {
        case low, medium, high, critical

        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// OSV.dev's id: a GHSA, CVE or project advisory.
    public let id: String
    /// Nil when OSV.dev has no score for it.
    public let severity: Severity?
    public let summary: String?
    /// The same vulnerability's other ids (a GHSA's CVE, say).
    public let aliases: [String]
    /// Releases or commits that fix it, as OSV.dev lists them.
    public let fixedVersions: [String]

    public var url: URL { URL(string: "https://osv.dev/vulnerability/\(id)")! }

    public init(id: String, severity: Severity? = nil, summary: String? = nil, aliases: [String] = [], fixedVersions: [String] = []) {
        self.id = id
        self.severity = severity
        self.summary = summary
        self.aliases = aliases
        self.fixedVersions = fixedVersions
    }
}

/// Orders version strings by their numeric parts: "1.10" after "1.9".
public enum VersionOrder {
    /// Starts with a digit, after an optional "v": a release, not a commit hash.
    public static func isComparable(_ version: String) -> Bool {
        let trimmed = version.hasPrefix("v") ? version.dropFirst() : Substring(version)
        guard let first = trimmed.first, first.isNumber else { return false }
        // A hex string of 12 characters or more is a commit, full or abbreviated,
        // even one that starts with a digit; a date version ("20240101") is shorter.
        return !(trimmed.count >= 12 && trimmed.allSatisfy(\.isHexDigit))
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let (x, y) = (parts(a), parts(b))
        for index in 0..<max(x.count, y.count) {
            let (p, q) = (index < x.count ? x[index] : 0, index < y.count ? y[index] : 0)
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func parts(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}

/// One problem `brew doctor` found.
public struct DoctorWarning: Hashable, Sendable {
    /// Its first line: what's wrong.
    public let summary: String
    /// The rest, as brew wrapped it: why it matters and what to do.
    public let detail: String

    public init(summary: String, detail: String = "") {
        self.summary = summary
        self.detail = detail
    }
}

public enum ServiceStatus: String, Hashable, Sendable {
    case started, stopped, none, error, scheduled, other, unknown

    public var isRunning: Bool { self == .started || self == .scheduled }
}

/// One service from `brew services info --all`. Services always belong to formulae.
public struct ServiceEntry: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let status: ServiceStatus
    public let user: String?
    public let file: String?
    public let exitCode: Int?
    public let pid: Int?
    /// Starts at login: `brew services start` put its launch agent in
    /// ~/Library/LaunchAgents. One started with `run` is running but not registered.
    public let registered: Bool
    public let logPath: String?
    /// Often the same file as `logPath`.
    public let errorLogPath: String?

    public var ref: PackageRef { PackageRef(.formula, name) }

    public init(
        name: String, status: ServiceStatus, user: String? = nil, file: String? = nil, exitCode: Int? = nil,
        pid: Int? = nil, registered: Bool = false, logPath: String? = nil, errorLogPath: String? = nil
    ) {
        self.name = name
        self.status = status
        self.user = user
        self.file = file
        self.exitCode = exitCode
        self.pid = pid
        self.registered = registered
        self.logPath = logPath
        self.errorLogPath = errorLogPath
    }
}

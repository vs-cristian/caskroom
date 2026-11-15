import Foundation

/// Decoders for brew's JSON. Only the fields the app shows are declared, and most
/// are optional, so new or missing keys in a Homebrew release don't break decoding.
public enum BrewParser {
    /// `brew info --json=v2 …`
    public static func packages(from data: Data) throws -> [Package] {
        let response = try decoder.decode(InfoJSON.self, from: data)
        return response.formulae.map(\.package) + response.casks.map(\.package)
    }

    /// `brew outdated --json=v2`
    public static func outdated(from data: Data) throws -> [OutdatedItem] {
        let response = try decoder.decode(OutdatedJSON.self, from: data)
        return response.formulae.map { $0.item(.formula) } + response.casks.map { $0.item(.cask) }
    }

    /// `brew services info --all --json`, or `brew services list --json`, which
    /// has fewer fields.
    public static func services(from data: Data) throws -> [ServiceEntry] {
        try decoder.decode([ServiceJSON].self, from: data).map(\.entry)
    }

    /// `brew vulns --json`. Formulae with only patched findings are left out.
    public static func vulnerabilities(from data: Data) throws -> VulnerabilityReport {
        let response = try decoder.decode(VulnsJSON.self, from: data)
        let findings = (response.findings ?? [])
            .map { finding in
                VulnerableFormula(
                    name: finding.formula,
                    version: finding.version ?? "",
                    vulnerabilities: (finding.vulnerabilities ?? []).map(\.vulnerability)
                        .sorted { ($0.severity?.rawValue ?? -1) > ($1.severity?.rawValue ?? -1) }
                )
            }
            .filter { !$0.vulnerabilities.isEmpty }
            .sorted { a, b in
                let (x, y) = (a.highestSeverity?.rawValue ?? -1, b.highestSeverity?.rawValue ?? -1)
                return x != y ? x > y : a.name < b.name
            }
        let unchecked = (response.skippedFormulae ?? []) + (response.outdatedWithoutSbom ?? [])
            + (response.unscannedFormulae ?? [:]).keys.sorted()
        return VulnerabilityReport(
            findings: findings,
            checked: response.checked ?? 0,
            unchecked: Array(Set(unchecked)).sorted()
        )
    }

    /// `brew cleanup --dry-run`. Its summary is prose, not JSON:
    ///
    ///     ==> This operation would free approximately 1.2GB of disk space.
    ///     ==> Would autoremove 2 unneeded formulae:
    ///     libfoo
    ///     libbar
    public static func cleanup(from output: String) -> CleanupSummary {
        var reclaimable: String?
        var unneeded: [String] = []
        var inAutoremoveList = false
        for line in output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("==>") {
                inAutoremoveList = line.contains("Would autoremove")
                if let start = line.range(of: "would free approximately "),
                   let end = line.range(of: " of disk space", range: start.upperBound..<line.endIndex) {
                    reclaimable = String(line[start.upperBound..<end.lowerBound])
                }
            } else if inAutoremoveList, !line.isEmpty, !line.hasPrefix("Would ") {
                unneeded.append(line)
            } else {
                inAutoremoveList = false
            }
        }
        return CleanupSummary(reclaimable: reclaimable, unneededFormulae: unneeded)
    }

    /// `brew doctor`'s stderr. Each warning starts with `Warning:` and runs to
    /// the next, blank lines included (one warning can have several paragraphs);
    /// the preamble before the first is boilerplate.
    public static func doctor(from output: String) -> [DoctorWarning] {
        var warnings: [DoctorWarning] = []
        var current: [String]?
        func finish() {
            guard var lines = current else { return }
            let summary = lines.removeFirst()
            while lines.first?.allSatisfy(\.isWhitespace) == true { lines.removeFirst() }
            while lines.last?.allSatisfy(\.isWhitespace) == true { lines.removeLast() }
            warnings.append(DoctorWarning(summary: summary, detail: lines.joined(separator: "\n")))
        }
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("Warning: ") {
                finish()
                current = [String(line.dropFirst("Warning: ".count))]
            } else {
                current?.append(line)
            }
        }
        finish()
        return warnings
    }

    /// `brew info --sizes`: a section per kind, each a name and its size on
    /// disk ("316.4MB"), then a total. brew has no JSON for it.
    ///
    ///     ==> Formulae sizes:
    ///     mysql@8.4 316.4MB
    ///     Total     316.4MB
    public static func sizes(from output: String) -> [PackageRef: String] {
        var sizes: [PackageRef: String] = [:]
        var kind: PackageKind?
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("==>") {
                kind = line.contains("Formulae") ? .formula : line.contains("Casks") ? .cask : nil
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let kind, fields.count == 2, fields[0] != "Total" else { continue }
            sizes[PackageRef(kind, String(fields[0]))] = String(fields[1])
        }
        return sizes
    }

    /// `brew formulae` / `brew casks`: one name per line.
    public static func names(from output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

private struct InfoJSON: Decodable {
    var formulae: [FormulaJSON] = []
    var casks: [CaskJSON] = []

    enum CodingKeys: CodingKey { case formulae, casks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formulae = try container.decodeIfPresent([FormulaJSON].self, forKey: .formulae) ?? []
        casks = try container.decodeIfPresent([CaskJSON].self, forKey: .casks) ?? []
    }
}

private struct FormulaJSON: Decodable {
    struct Versions: Decodable { let stable: String? }
    struct URLs: Decodable {
        struct Spec: Decodable { let url: String? }
        let stable: Spec?
        let head: Spec?
    }
    struct Installed: Decodable {
        let version: String
        let installedOnRequest: Bool?
        let time: Double?
    }
    struct KegOnlyReason: Decodable {
        let reason: String?
        let explanation: String?
    }

    let name: String
    let fullName: String?
    let tap: String?
    let desc: String?
    let homepage: String?
    let versions: Versions?
    let installed: [Installed]?
    let pinned: Bool?
    let outdated: Bool?
    let caveats: String?
    let dependencies: [String]?
    let deprecated: Bool?
    let disabled: Bool?
    let deprecationReason: String?
    let deprecationReplacementFormula: String?
    let deprecationReplacementCask: String?
    let deprecationDate: String?
    let disableReason: String?
    let disableReplacementFormula: String?
    let disableReplacementCask: String?
    let disableDate: String?
    let license: String?
    let urls: URLs?
    let kegOnly: Bool?
    let kegOnlyReason: KegOnlyReason?
    let linkedKeg: String?
    let versionedFormulae: LenientStrings?
    let conflictsWith: LenientStrings?
    let oldnames: LenientStrings?

    var package: Package {
        let installed = installed ?? []
        return Package(
            ref: PackageRef(.formula, name),
            fullName: fullName ?? name,
            desc: desc,
            homepage: homepage.flatMap(URL.init(string:)),
            tap: tap,
            latestVersion: versions?.stable,
            installedVersions: installed.map(\.version),
            // A formula is on request if any installed keg was asked for directly.
            installedOnRequest: installed.isEmpty || installed.contains { $0.installedOnRequest ?? true },
            pinned: pinned ?? false,
            outdated: outdated ?? false,
            caveats: caveats.nonBlank,
            dependencies: (dependencies ?? []).map { PackageRef(.formula, $0) },
            deprecated: deprecated ?? false,
            disabled: disabled ?? false,
            deprecation: deprecated == true
                ? Deprecation(deprecationReason, deprecationReplacementFormula, deprecationReplacementCask, deprecationDate) : nil,
            disabling: disabled == true || disableDate != nil
                ? Deprecation(disableReason, disableReplacementFormula, disableReplacementCask, disableDate) : nil,
            license: license,
            installedAt: installed.compactMap(\.time).max().map(Date.init(timeIntervalSince1970:)),
            downloadURL: urls?.stable?.url.flatMap(URL.init(string:)),
            headURL: urls?.head?.url.flatMap(URL.init(string:)),
            kegOnly: kegOnly ?? false,
            // A maintainer's explanation says more than the symbol it comes with.
            kegOnlyReason: kegOnlyReason?.explanation.nonBlank
                ?? kegOnlyReason?.reason.nonBlank.map { $0.hasPrefix(":") ? String($0.dropFirst()) : $0 },
            linked: linkedKeg.nonBlank != nil,
            otherVersions: (versionedFormulae?.values ?? []).map { PackageRef(.formula, $0) },
            conflicts: (conflictsWith?.values ?? []).map { PackageRef(.formula, $0) },
            oldNames: oldnames?.values ?? []
        )
    }
}

private struct CaskJSON: Decodable {
    struct DependsOn: Decodable {
        let formula: LenientStrings?
        let cask: LenientStrings?
        /// `{">=": ["13"]}`; other comparisons ("==") pin exact releases and aren't a minimum.
        let macos: [String: LenientStrings]?

        enum CodingKeys: CodingKey { case formula, cask, macos }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            formula = try? container.decodeIfPresent(LenientStrings.self, forKey: .formula)
            cask = try? container.decodeIfPresent(LenientStrings.self, forKey: .cask)
            macos = try? container.decodeIfPresent([String: LenientStrings].self, forKey: .macos)
        }
    }
    struct Conflicts: Decodable {
        let formula: LenientStrings?
        let cask: LenientStrings?

        enum CodingKeys: CodingKey { case formula, cask }

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            formula = try? container?.decodeIfPresent(LenientStrings.self, forKey: .formula)
            cask = try? container?.decodeIfPresent(LenientStrings.self, forKey: .cask)
        }
    }

    let token: String
    let fullToken: String?
    let tap: String?
    let name: [String]?
    let desc: String?
    let homepage: String?
    let version: String?
    let installed: String?
    let pinned: Bool?
    let outdated: Bool?
    let caveats: String?
    let dependsOn: DependsOn?
    let deprecated: Bool?
    let disabled: Bool?
    let deprecationReason: String?
    let deprecationReplacementFormula: String?
    let deprecationReplacementCask: String?
    let deprecationDate: String?
    let disableReason: String?
    let disableReplacementFormula: String?
    let disableReplacementCask: String?
    let disableDate: String?
    let installedTime: Double?
    let autoUpdates: Bool?
    let artifacts: [Artifact]?
    let url: String?
    let conflictsWith: Conflicts?
    let oldTokens: LenientStrings?

    var package: Package {
        Package(
            ref: PackageRef(.cask, token),
            fullName: fullToken ?? token,
            displayName: name?.first,
            desc: desc,
            homepage: homepage.flatMap(URL.init(string:)),
            tap: tap,
            latestVersion: version,
            installedVersions: installed.map { [$0] } ?? [],
            installedOnRequest: true,
            pinned: pinned ?? false,
            outdated: outdated ?? false,
            caveats: caveats.nonBlank,
            dependencies: (dependsOn?.formula?.values ?? []).map { PackageRef(.formula, $0) }
                + (dependsOn?.cask?.values ?? []).map { PackageRef(.cask, $0) },
            deprecated: deprecated ?? false,
            disabled: disabled ?? false,
            deprecation: deprecated == true
                ? Deprecation(deprecationReason, deprecationReplacementFormula, deprecationReplacementCask, deprecationDate) : nil,
            disabling: disabled == true || disableDate != nil
                ? Deprecation(disableReason, disableReplacementFormula, disableReplacementCask, disableDate) : nil,
            installedAt: installedTime.map(Date.init(timeIntervalSince1970:)),
            appPath: appPath,
            autoUpdates: autoUpdates ?? false,
            hasZap: (artifacts ?? []).contains(where: \.isZap),
            quitsApp: (artifacts ?? []).contains(where: \.quitsApp),
            downloadURL: url.flatMap(URL.init(string:)),
            conflicts: (conflictsWith?.cask?.values ?? []).map { PackageRef(.cask, $0) }
                + (conflictsWith?.formula?.values ?? []).map { PackageRef(.formula, $0) },
            minimumMacOS: dependsOn?.macos?[">="]?.values.first,
            oldNames: oldTokens?.values ?? []
        )
    }

    /// The first `app` artifact's install location: its `target`, else /Applications.
    private var appPath: String? {
        for artifact in artifacts ?? [] {
            guard let app = artifact.app?.values.first else { continue }
            return artifact.target ?? "/Applications/\(app)"
        }
        return nil
    }
}

/// One entry of a cask's `artifacts`. Entries are objects of many shapes (app,
/// binary, zap…); only `app`, a string `target`, whether it's `zap` and whether
/// an `uninstall` directive quits an app are read, anything else is skipped.
private struct Artifact: Decodable {
    let app: LenientStrings?
    let target: String?
    let isZap: Bool
    let quitsApp: Bool

    enum CodingKeys: CodingKey { case app, target, zap, uninstall }

    /// One `uninstall` directive: `{"quit": "com.example.app"}`, `{"delete": […]}`…
    private struct Directive: Decodable {
        let quits: Bool

        enum CodingKeys: CodingKey { case quit }

        init(from decoder: Decoder) throws {
            quits = (try? decoder.container(keyedBy: CodingKeys.self))?.contains(.quit) ?? false
        }
    }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        app = try? container?.decodeIfPresent(LenientStrings.self, forKey: .app)
        target = try? container?.decodeIfPresent(String.self, forKey: .target)
        isZap = container?.contains(.zap) ?? false
        let directives = try? container?.decodeIfPresent([Directive].self, forKey: .uninstall)
        quitsApp = directives?.contains(where: \.quits) ?? false
    }
}

/// A list of strings that brew sometimes writes as a single bare string.
private struct LenientStrings: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([String].self) {
            values = list
        } else if let single = try? container.decode(String.self) {
            values = [single]
        } else {
            values = []
        }
    }
}

private struct OutdatedJSON: Decodable {
    struct Item: Decodable {
        let name: String
        let installedVersions: [String]?
        let currentVersion: String
        let pinned: Bool?

        func item(_ kind: PackageKind) -> OutdatedItem {
            OutdatedItem(
                ref: PackageRef(kind, name),
                installedVersions: installedVersions ?? [],
                currentVersion: currentVersion,
                pinned: pinned ?? false
            )
        }
    }

    var formulae: [Item] = []
    var casks: [Item] = []

    enum CodingKeys: CodingKey { case formulae, casks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formulae = try container.decodeIfPresent([Item].self, forKey: .formulae) ?? []
        casks = try container.decodeIfPresent([Item].self, forKey: .casks) ?? []
    }
}

private struct VulnsJSON: Decodable {
    struct Finding: Decodable {
        let formula: String
        let version: String?
        let vulnerabilities: [VulnerabilityJSON]?
    }

    struct VulnerabilityJSON: Decodable {
        let id: String
        let severity: String?
        let summary: String?
        let aliases: [String]?
        let fixedVersions: [String]?

        var vulnerability: Vulnerability {
            let severity: Vulnerability.Severity? = switch severity?.lowercased() {
            case "low": .low
            case "medium", "moderate": .medium
            case "high": .high
            case "critical": .critical
            default: nil
            }
            return Vulnerability(id: id, severity: severity, summary: summary.nonBlank,
                                 aliases: aliases ?? [], fixedVersions: fixedVersions ?? [])
        }
    }

    let findings: [Finding]?
    let checked: Int?
    let skippedFormulae: [String]?
    let outdatedWithoutSbom: [String]?
    /// Name to why: "untrusted_tap", "resolution_error".
    let unscannedFormulae: [String: String]?
}

private struct ServiceJSON: Decodable {
    let name: String
    let status: String?
    let user: String?
    let file: String?
    let exitCode: Int?
    let pid: Int?
    let registered: Bool?
    let logPath: String?
    let errorLogPath: String?

    var entry: ServiceEntry {
        ServiceEntry(
            name: name,
            status: status.flatMap(ServiceStatus.init(rawValue:)) ?? .unknown,
            user: user,
            file: file,
            exitCode: exitCode,
            pid: pid,
            registered: registered ?? false,
            logPath: logPath.nonBlank,
            errorLogPath: errorLogPath.nonBlank
        )
    }
}

private extension Deprecation {
    /// From a stanza's fields as brew's JSON spreads them out. The date is
    /// "2025-07-19", in no particular time zone; it's read as UTC.
    init(_ reason: String?, _ formula: String?, _ cask: String?, _ date: String?) {
        let replacement = formula.nonBlank.map { PackageRef(.formula, $0) } ?? cask.nonBlank.map { PackageRef(.cask, $0) }
        self.init(
            reason: reason.nonBlank,
            replacement: replacement,
            date: date.flatMap { try? Date($0, strategy: .iso8601.year().month().day()) }
        )
    }
}

private extension Optional where Wrapped == String {
    var nonBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

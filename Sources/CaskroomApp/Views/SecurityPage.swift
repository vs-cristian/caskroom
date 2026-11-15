import AppKit
import BrewKit
import SwiftUI

/// Installed formulae with known vulnerabilities, from `brew vulns` (OSV.dev),
/// and the update that fixes them. Off until turned on here or in Settings,
/// since checking sends formula names and versions to OSV.dev.
struct SecurityPage: View {
    @Environment(BrewStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch store.vulnerabilityCheck {
            case nil:
                OptIn()
            case .checking:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Checking with OSV.dev…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                ContentUnavailableView {
                    Label("Couldn't Check for Vulnerabilities", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await store.loadVulnerabilities() } }
                }
            case let .finished(report, _) where report.findings.isEmpty:
                VStack(spacing: 0) {
                    EmptyPage(
                        title: "No Known Vulnerabilities",
                        symbol: "checkmark.shield.fill",
                        message: "OSV.dev knows of no open vulnerabilities in the \(report.checked) formulae checked.",
                        tint: .green
                    )
                    Coverage(report: report).padding(20)
                }
            case let .finished(report, _):
                List {
                    Section {
                        ForEach(report.findings) { finding in
                            NavigationLink(value: finding.ref) {
                                FindingRow(finding: finding)
                            }
                            .contextMenu { PackageMenu(store: store, ref: finding.ref) }
                        }
                    } header: {
                        Summary(report: report)
                    } footer: {
                        Coverage(report: report).padding(.top, 8)
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                .environment(\.defaultMinListRowHeight, 56)
                .animation(Motion.list(reduceMotion: reduceMotion), value: report.findings.map(\.name))
            }
        }
        .navigationTitle("Security")
        .navigationSubtitle(subtitle)
        .toolbar {
            if store.checksVulnerabilities {
                ToolbarItem {
                    Button("Check Again", systemImage: "arrow.trianglehead.2.clockwise") {
                        Task { await store.loadVulnerabilities() }
                    }
                    .disabled(store.vulnerabilityCheck == .checking)
                    .help("Ask OSV.dev again (brew vulns)")
                }
                ToolbarItem {
                    Button("Fix") { store.enqueue(.upgradeVulnerable) }
                        .glassButton(prominent: true)
                        .disabled(store.fixableVulnerabilities.isEmpty || store.isPending(.upgradeVulnerable))
                        .help("Update the vulnerable formulae that have an update (\(BrewOperation.upgradeVulnerable.command)). The new version isn't guaranteed to fix every vulnerability.")
                }
            }
        }
    }

    private var subtitle: String {
        guard case let .finished(_, date) = store.vulnerabilityCheck else { return "" }
        return "Checked \(date.relative)"
    }
}

/// "3 tools have known vulnerabilities, 2 fixed by updating".
private struct Summary: View {
    @Environment(BrewStore.self) private var store
    let report: VulnerabilityReport

    var body: some View {
        let count = report.findings.count
        let fixes = report.findings.map(store.updateFixes)
        let fixed = fixes.filter { $0 == true }.count
        // An update that doesn't fix everything, or whose fixes OSV.dev lists
        // as commits rather than releases, so there's no telling.
        let unsure = report.findings.filter { store.outdatedItem($0.ref) != nil }.count - fixed
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count) \(count == 1 ? "tool has" : "tools have") known vulnerabilities")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text(detail(fixed: fixed, unsure: unsure, count: count))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .textCase(nil)
        .padding(.bottom, 6)
    }

    private func detail(fixed: Int, unsure: Int, count: Int) -> String {
        var parts: [String] = []
        if fixed > 0 { parts.append("\(fixed) fixed by updating") }
        if unsure > 0 {
            parts.append("\(unsure) \(fixed > 0 ? "more " : "")\(unsure == 1 ? "has an update" : "have updates") that may not fix every one")
        }
        if fixed + unsure < count { parts.append("\(count - fixed - unsure) with no update yet") }
        return parts.joined(separator: ", ")
    }
}

private struct FindingRow: View {
    @Environment(BrewStore.self) private var store
    let finding: VulnerableFormula

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PackageRow(
                ref: finding.ref,
                title: finding.ref.name,
                subtitle: "\(finding.version) · \(finding.vulnerabilities.count) \(finding.vulnerabilities.count == 1 ? "vulnerability" : "vulnerabilities")",
                iconSize: 44
            ) {
                VStack(alignment: .trailing, spacing: 3) {
                    if let severity = finding.highestSeverity { SeverityTag(severity: severity) }
                    switch store.updateFixes(finding) {
                    case true?: Tag("Fixed by update", color: .green)
                    case false?: Tag("Update doesn't fix all")
                    case nil where store.outdatedItem(finding.ref) != nil: Tag("Update available", color: .accentColor)
                    case nil: Tag("No fix yet")
                    }
                }
                PrimaryActionButton(ref: finding.ref)
                    .controlSize(.small)
                    .frame(minWidth: 80, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(finding.vulnerabilities.prefix(3)) { vulnerability in
                    VulnerabilityLine(vulnerability: vulnerability)
                }
                if finding.vulnerabilities.count > 3 {
                    Text("and \(finding.vulnerabilities.count - 3) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 56)
            .padding(.bottom, 4)
        }
    }
}

/// One vulnerability: its id (linked to OSV.dev), severity and summary.
struct VulnerabilityLine: View {
    let vulnerability: Vulnerability

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Link(vulnerability.id, destination: vulnerability.url)
                .font(.caption.monospaced())
                .help(vulnerability.aliases.isEmpty ? "Open on OSV.dev" : "Also \(vulnerability.aliases.formatted(.list(type: .and)))")
            if let summary = vulnerability.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct SeverityTag: View {
    let severity: Vulnerability.Severity

    var body: some View {
        switch severity {
        case .critical: Tag("Critical", color: .red)
        case .high: Tag("High", color: .orange)
        case .medium: Tag("Medium", color: .yellow)
        case .low: Tag("Low")
        }
    }
}

/// What the check covered, since a clean result is only as good as that.
private struct Coverage: View {
    let report: VulnerabilityReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Checked \(report.checked) formulae with OSV.dev. Apps (casks) aren't checked.")
            if !report.unchecked.isEmpty {
                let names = report.unchecked.count <= 4 ? report.unchecked.formatted(.list(type: .and)) : "\(report.unchecked.count) formulae"
                Text("\(names) couldn't be checked: Homebrew can't tell where \(report.unchecked.count == 1 ? "its" : "their") source came from.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Asks before anything leaves the Mac.
private struct OptIn: View {
    @Environment(BrewStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label("Check for Known Vulnerabilities", systemImage: "checkmark.shield")
        } description: {
            Text("Caskroom can ask OSV.dev, Google's open vulnerability database, about the formulae you have installed, and update the ones with a fix. This sends their names and versions to OSV.dev each time it checks. Apps (casks) aren't checked.")
        } actions: {
            Button("Turn On") { store.checksVulnerabilities = true }
                .glassButton(prominent: true)
                .help("Runs brew vulns now and after each change to your formulae")
        }
    }
}

/// Known vulnerabilities on a formula's page.
struct VulnerabilityCard: View {
    @Environment(BrewStore.self) private var store
    let finding: VulnerableFormula

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundStyle(.red.gradient)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(finding.vulnerabilities.count) Known \(finding.vulnerabilities.count == 1 ? "Vulnerability" : "Vulnerabilities")")
                        .font(.headline)
                    if let severity = finding.highestSeverity { SeverityTag(severity: severity) }
                }
                Text(explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(finding.vulnerabilities) { VulnerabilityLine(vulnerability: $0) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var explanation: String {
        let version = "OSV.dev lists these for \(finding.version)."
        guard let item = store.outdatedItem(finding.ref) else { return version + " There's no newer version yet." }
        return switch store.updateFixes(finding) {
        case true?: version + " Updating to \(item.currentVersion) fixes them."
        case false?: version + " Updating to \(item.currentVersion) doesn't fix all of them."
        case nil: version + " Updating to \(item.currentVersion) may fix them."
        }
    }
}

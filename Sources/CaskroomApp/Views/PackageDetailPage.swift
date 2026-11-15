import AppKit
import BrewKit
import SwiftUI

/// A package's page, laid out like an App Store product page.
struct PackageDetailPage: View {
    @Environment(BrewStore.self) private var store
    let ref: PackageRef

    var body: some View {
        Group {
            if let package = store.package(ref) {
                ScrollView {
                    PackageDetailContent(package: package)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 28)
                        .frame(maxWidth: 860)
                        .frame(maxWidth: .infinity)
                }
            } else if let error = store.infoErrors[ref] {
                EmptyPage(title: "Couldn't Load \(ref.name)", symbol: "exclamationmark.triangle", message: error)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await store.loadInfo(ref) }
            }
        }
        // Info fetched after the page opened fades in over the spinner. A
        // package already known is there on first draw, so this never runs for it.
        .animation(Motion.quick, value: store.package(ref) != nil)
        .animation(Motion.quick, value: store.infoErrors[ref] != nil)
        .navigationTitle(store.package(ref)?.title ?? ref.name)
        .focusedSceneValue(\.packageRef, ref)
    }
}

private struct PackageDetailContent: View {
    @Environment(BrewStore.self) private var store
    let package: Package

    var body: some View {
        let commands = package.kind == .formula ? primaryCommands(store.commandIndex.commands(of: package.name)) : []
        let dependents = store.dependents(of: package.ref)
        let conflicts = package.conflicts
        let otherVersions = store.otherVersions(of: package).filter { !conflicts.contains($0) }
        VStack(alignment: .leading, spacing: 28) {
            header(commands: commands)
            InfoStrip(package: package, update: store.outdatedItem(package.ref), facts: store.facts[package.ref])
            if package.latestVersion != nil {
                section("What's New") {
                    WhatsNewView(package: package, update: store.outdatedItem(package.ref), lineLimit: 3, noteLimit: 2)
                }
            }
            if package.kegOnly && !package.linked {
                PathCard(package: package, prefix: store.prefix)
            }
            if package.deprecated || package.disabled {
                DeprecationCard(package: package)
            }
            if let finding = store.vulnerabilities(of: package.ref) {
                VulnerabilityCard(finding: finding)
            }
            if let service = store.serviceEntry(package.ref) {
                ServiceCard(entry: service)
            }
            if let caveats = package.caveats {
                CaveatsCard(text: caveats)
            }
            // The header shows the first few once it's installed.
            if !commands.isEmpty && !(showsCommandsInHeader && commands.count <= Self.headerCommands) {
                section("Commands") { CommandChips(commands: commands) }
            }
            if !package.dependencies.isEmpty {
                // Before an install, which are already here.
                section("Dependencies") { packageLinks(package.dependencies, marksInstalled: !package.isInstalled) }
            }
            if !otherVersions.isEmpty {
                section("Other Versions") { packageLinks(otherVersions) }
            }
            if !conflicts.isEmpty {
                section("Conflicts With") { packageLinks(conflicts, marksInstalled: true) }
            }
            if !dependents.isEmpty {
                section("Used By") { packageLinks(dependents) }
            }
            information
            section("Terminal") { CommandList(operations: store.commands(for: package)) }
        }
        // Installing adds the ⋯ menu, a service card and more information;
        // they fade in while what's below them moves down, rather than jumping.
        .animation(Motion.standard, value: package.isInstalled)
        .animation(Motion.standard, value: store.serviceEntry(package.ref) != nil)
        .task(id: package.installedVersions) { await store.loadFacts(package) }
    }

    static let headerCommands = 3

    /// An installed formula with nothing to update has no action left; its
    /// commands take the button's place.
    private var showsCommandsInHeader: Bool {
        package.kind == .formula && package.isInstalled && store.outdatedItem(package.ref) == nil
    }

    /// Commands named like the formula first (`mysql` for mysql@8.4), then
    /// the shortest: what someone most likely types.
    private func primaryCommands(_ commands: [String]) -> [String] {
        let base = String(package.name.split(separator: "@").first ?? Substring(package.name))
        func score(_ command: String) -> Int {
            command == base ? 0 : base.hasPrefix(command) || command.hasPrefix(base) ? 1 : 2
        }
        return commands.sorted { a, b in
            let (x, y) = (score(a), score(b))
            if x != y { return x < y }
            return a.count != b.count ? a.count < b.count : a < b
        }
    }

    /// "Also installs 7 packages", before an install: dependencies of
    /// dependencies included, less what's already here.
    private var alsoInstalls: String? {
        guard !package.isInstalled, let names = store.facts[package.ref]?.allDependencies, !names.isEmpty else { return nil }
        let missing = names.filter { !store.isInstalled(named: $0) }.count
        switch missing {
        case 0: return names.count == 1 ? "Its dependency is already installed" : "All \(names.count) dependencies are already installed"
        case 1: return "Also installs 1 package"
        default: return "Also installs \(missing) packages" + (missing < names.count ? " (\(names.count - missing) already installed)" : "")
        }
    }

    private func header(commands: [String]) -> some View {
        HStack(alignment: .center, spacing: 22) {
            PackageIcon(ref: package.ref, size: 112)
            VStack(alignment: .leading, spacing: 6) {
                Text(package.title)
                    .font(.system(size: 28, weight: .bold))
                    .textSelection(.enabled)
                if let desc = package.desc {
                    Text(desc)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    PrimaryActionButton(ref: package.ref, prominent: true,
                                        commands: showsCommandsInHeader ? Array(commands.prefix(Self.headerCommands)) : [])
                        .controlSize(.large)
                    if package.isInstalled {
                        moreMenu
                    }
                    if package.pinned { Tag("Pinned", color: .orange) }
                    if package.deprecated && !package.disabled { Tag("Deprecated", color: .orange) }
                    if package.disabled { Tag("Disabled", color: .red) }
                }
                .padding(.top, 8)
                if let alsoInstalls {
                    Text(alsoInstalls)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var moreMenu: some View {
        Menu {
            PackageMenu(store: store, ref: package.ref)
        } label: {
            Label("More", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .glassButton()
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .fixedSize()
        .help("More")
    }

    private var information: some View {
        section("Information") {
            // The strip has the version and source; this is the rest.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 10) {
                if let homepage = package.homepage {
                    infoRow("Homepage") { Link(homepage.host() ?? homepage.absoluteString, destination: homepage) }
                }
                if package.fullName != package.name {
                    infoRow("Full name") { Text(package.fullName).textSelection(.enabled) }
                }
                if let host = package.downloadURL?.host() {
                    infoRow("Downloads from") { Text(host).textSelection(.enabled) }
                }
                if package.isInstalled {
                    if package.installedVersions.count > 1 {
                        infoRow("Versions installed") { Text(package.installedVersions.joined(separator: ", ")).monospacedDigit() }
                    }
                    if let date = package.installedAt {
                        infoRow("Installed on") { Text(date.formatted(date: .long, time: .shortened)) }
                    }
                    if !package.installedOnRequest {
                        infoRow("Reason") { Text("Installed as a dependency") }
                    }
                }
                if let path = package.appPath {
                    infoRow("App") {
                        Button(path) { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private func packageLinks(_ refs: [PackageRef], marksInstalled: Bool = false) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(refs, id: \.self) { ref in
                let installed = marksInstalled && store.installedPackage(ref) != nil
                NavigationLink(value: ref) {
                    HStack(spacing: 6) {
                        PackageIcon(ref: ref, size: 18)
                        Text(ref.name)
                        if installed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("Installed")
                        }
                    }
                }
                .glassButton()
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .help(installed ? "\(ref.name) is installed" : "")
            }
        }
    }

    private func infoRow<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            content()
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold))
            content()
        }
    }
}

/// The row of key facts under the header, App Store style. Only facts that
/// say something: a cask has no license or formula dependencies to show.
private struct InfoStrip: View {
    let package: Package
    let update: OutdatedItem?
    let facts: PackageFacts?

    private struct Stat: Identifiable {
        let title: String
        let value: String
        var footnote: String?
        var help: String?

        var id: String { title }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                if index > 0 { divider }
                cell(stat)
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        .animation(Motion.standard, value: stats.map(\.value))
    }

    private var stats: [Stat] {
        var stats = [version]
        // "…" while loading; dropped if Homebrew doesn't count it.
        switch facts?.monthlyInstalls {
        case let .some(.some(installs)):
            stats.append(Stat(title: "Installs", value: installs.formatted(.number.notation(.compactName)),
                              footnote: "this month", help: "\(installs.formatted()) installs in the last 30 days"))
        case .some(.none): break
        case .none: stats.append(Stat(title: "Installs", value: "…"))
        }
        if let installed = package.installedVersions.last {
            if let measured = facts?.size, measured.version == installed {
                if let size = measured.size { stats.append(Stat(title: "Size", value: Self.spaced(size), footnote: "on disk")) }
            } else {
                stats.append(Stat(title: "Size", value: "…"))
            }
        }
        switch package.kind {
        case .cask:
            if let macOS = package.minimumMacOS {
                stats.append(Stat(title: "Requires", value: "macOS \(macOS)+"))
            }
            stats.append(package.autoUpdates
                ? Stat(title: "Updates", value: "Itself", help: "The app updates itself; Homebrew lists an update only when the app falls behind.")
                : Stat(title: "Updates", value: "Homebrew", help: "Updates come through Homebrew."))
        case .formula:
            if let license = package.license {
                stats.append(Stat(title: "License", value: license.count > 14 ? String(license.prefix(12)) + "…" : license, help: license))
            }
            let count = package.dependencies.count
            stats.append(Stat(title: "Dependencies", value: count == 0 ? "None" : "\(count)", footnote: count == 0 ? nil : "direct"))
        }
        stats.append(Stat(title: "Source", value: sourceName, help: package.tap))
        return stats
    }

    /// One cell for the installed and current version: "8.4.12 → 8.4.13"
    /// only when there's an update. Homebrew's rebuild suffix ("8.4.13_1") is
    /// left off unless only the rebuild changed.
    private var version: Stat {
        let kind = package.kind
        let display = { (version: String) in
            kind == .cask ? String(version.split(separator: ",").first ?? Substring(version)) : kind.upstreamVersion(version)
        }
        let installed = package.installedVersions.last
        if let update {
            let (from, to) = (display(installed ?? ""), display(update.currentVersion))
            let value = from == to ? "\(installed ?? "") → \(update.currentVersion)" : "\(from) → \(to)"
            return Stat(title: "Version", value: value, footnote: "update available",
                        help: "\(installed ?? "") installed, \(update.currentVersion) available")
        }
        if let installed {
            return Stat(title: "Version", value: display(installed), footnote: "installed", help: installed)
        }
        return Stat(title: "Version", value: package.latestVersion.map(display) ?? "—", help: package.latestVersion)
    }

    private var sourceName: String {
        switch package.tap {
        case "homebrew/core": "Core"
        case "homebrew/cask": "Cask"
        case let tap?: tap
        case nil: "—"
        }
    }

    /// "316.4MB" → "316.4 MB"
    private static func spaced(_ size: String) -> String {
        guard let unit = size.firstIndex(where: \.isLetter), unit > size.startIndex else { return size }
        return size[..<unit] + " " + size[unit...]
    }

    private var divider: some View {
        Divider().frame(height: 40)
    }

    private func cell(_ stat: Stat) -> some View {
        VStack(spacing: 3) {
            Text(stat.title).font(.caption).foregroundStyle(.secondary)
            Text(stat.value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // After an update the installed version rolls to the new one.
                .contentTransition(.numericText())
            Text(stat.footnote ?? " ").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .help(stat.help ?? stat.value)
    }
}

/// A keg-only formula's commands aren't linked into the prefix, so the shell
/// doesn't find them. brew's caveats JSON leaves that note out.
private struct PathCard: View {
    let package: Package
    let prefix: String

    private var line: String { "export PATH=\"\(prefix)/opt/\(package.name)/bin:$PATH\"" }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "terminal.fill")
                .font(.title2)
                .foregroundStyle(Color.orange.gradient)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 8) {
                Text("Not on Your PATH").font(.headline)
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline) {
                    Text(line)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    CopyButton(text: line, help: "Copy the export line")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var explanation: String {
        let because: String = switch package.kegOnlyReason {
        case "versioned_formula"?: " because it's a versioned formula, which would clash with other versions"
        case "provided_by_macos"?: " because macOS already provides it"
        case "shadowed_by_macos"?: " because macOS ships a version of its own"
        case let reason?: " (\(reason.trimmingCharacters(in: .punctuationCharacters)))"
        case nil: ""
        }
        let when = package.isInstalled ? "so the shell doesn't find its commands" : "so after installing, the shell won't find its commands"
        return "Homebrew doesn't link \(package.name) into \(prefix)/bin\(because), \(when). Add this line to ~/.zshrc to use them:"
    }
}

/// Why Homebrew deprecated or disabled the package, and what it suggests instead.
private struct DeprecationCard: View {
    let package: Package

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(package.disabled ? Color.red.gradient : Color.orange.gradient)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(package.disabled ? "Disabled" : "Deprecated").font(.headline)
                Text(explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let replacement = package.replacement {
                    HStack(spacing: 8) {
                        Text("Homebrew suggests").foregroundStyle(.secondary)
                        NavigationLink(value: replacement) {
                            HStack(spacing: 6) {
                                PackageIcon(ref: replacement, size: 18)
                                Text(replacement.name)
                            }
                        }
                        .glassButton()
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var explanation: String {
        let name = package.title
        let stanza = package.disabled ? package.disabling : package.deprecation
        var sentence = "Homebrew \(package.disabled ? "disabled" : "deprecated") \(name)"
        if let date = stanza?.date { sentence += " on \(date.formatted(date: .long, time: .omitted))" }
        if let because = stanza?.because { sentence += " because it \(because)" }
        sentence += "."
        if package.disabled {
            sentence += " It can't be installed or updated any more."
        } else {
            sentence += " It still works, but may stop getting fixes."
            if let date = package.disabling?.date, date > .now {
                sentence += " Homebrew will disable it on \(date.formatted(date: .long, time: .omitted))."
            }
        }
        return sentence
    }
}

/// The package's background service, laid out like a System Settings group:
/// what it's doing now, with Run or Stop, then whether it starts at login.
private struct ServiceCard: View {
    @Environment(BrewStore.self) private var store
    let entry: ServiceEntry

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "gearshape.2.fill")
                    .font(.title2)
                    .foregroundStyle(entry.status.isRunning ? Color.green.gradient : Color.gray.gradient)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Background Service").font(.headline)
                    HStack(spacing: 5) {
                        StatusDot(status: entry.status)
                        Text(entry.detail)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if let run = store.operation(for: entry.ref) {
                    ProgressView().controlSize(.small)
                    Text(run.operation.progressVerb).foregroundStyle(.secondary)
                } else {
                    ServiceRunButton(entry: entry)
                }
                Menu {
                    ServiceMenu(store: store, entry: entry, includesControls: false)
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden)
                .glassButton()
                .buttonBorderShape(.circle)
                .fixedSize()
                .help("More")
            }
            .padding(16)
            // Run or Stop gives way to progress, and the status tints follow the service.
            .animation(Motion.standard, value: store.isBusy(entry.ref))
            .animation(Motion.standard, value: entry.status)
            Divider().padding(.leading, 66)
            HStack {
                Text("Start at Login")
                Spacer()
                ServiceLoginToggle(entry: entry).labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.leading, 50)
            .padding(.vertical, 10)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// What to type once a formula is installed, each command copied on click.
private struct CommandChips: View {
    let commands: [String]
    @State private var showsAll = false

    private static let shownAtFirst = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6) {
                ForEach(showsAll ? commands : Array(commands.prefix(Self.shownAtFirst)), id: \.self) { command in
                    Button(command) { copyToPasteboard(command) }
                        .font(.callout.monospaced())
                        .glassButton()
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .help("Copy “\(command)”")
                }
            }
            if commands.count > Self.shownAtFirst && !showsAll {
                Button("Show All \(commands.count)") { showsAll = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }
}

/// brew's notes after install, cut to a few lines: mysql's would fill a third of the window.
private struct CaveatsCard: View {
    let text: String
    @State private var expanded = false

    private static let lineLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Caveats", systemImage: "info.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.primary, .blue)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(text) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy caveats")
            }
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(expanded ? nil : Self.lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !expanded && text.mayRunPast(lines: Self.lineLimit) {
                Button("more") { expanded = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(Motion.standard, value: expanded)
    }
}

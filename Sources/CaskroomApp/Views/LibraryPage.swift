import BrewKit
import SwiftUI

struct LibraryPage: View {
    enum Sort: String, CaseIterable, Identifiable {
        case name = "Name", recent = "Recently Installed"
        var id: Self { self }
    }

    @Environment(BrewStore.self) private var store
    let filter: LibraryFilter
    @AppStorage("librarySort") private var sort = Sort.name
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Rows chosen with ⌘- or ⇧-click, for acting on several at once.
    @State private var selection: Set<PackageRef> = []

    var body: some View {
        Group {
            if store.lastRefreshed == nil {
                // The list appears whole once brew answers, rather than filling
                // in row by row (which also clips rows; see defaultMinListRowHeight).
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if packages.isEmpty {
                EmptyPage(title: emptyTitle, symbol: filter.symbol, message: emptyMessage)
            } else {
                List(selection: $selection) {
                    if filter == .all {
                        section("Apps", packages.filter { $0.kind == .cask })
                        section("Formulae", packages.filter { $0.kind == .formula })
                    } else {
                        rows(packages)
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                // Rows added to a list that was empty keep AppKit's default
                // height instead of their own; a minimum keeps them whole.
                .environment(\.defaultMinListRowHeight, 44)
                // Installs slide in, uninstalls slide out, a new sort reorders.
                .animation(Motion.list(reduceMotion: reduceMotion), value: packages.map(\.ref))
                // Another sidebar filter is another list, not this one rearranged.
                .id(filter)
                .packageSelection($selection)
            }
        }
        .onChange(of: filter) { selection = [] }
        .navigationTitle(filter.title)
        .navigationSubtitle(packages.count == 1 ? "1 package" : "\(packages.count) packages")
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    // Says which order the list is in, not just that it has one.
                    Label(sort.rawValue, systemImage: "arrow.up.arrow.down")
                }
                .labelStyle(.titleAndIcon)
                .help("Sort")
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ packages: [Package]) -> some View {
        if !packages.isEmpty {
            Section {
                rows(packages)
            } header: {
                Text("\(title) · \(packages.count)")
            }
        }
    }

    private func rows(_ packages: [Package]) -> some View {
        // Not links: a click opens the page, ⌘-click selects (see PackageSelection).
        ForEach(packages) { package in
            LibraryRow(
                package: package,
                update: store.outdatedItem(package.ref),
                showsReason: filter == .attention,
                dependencyUsage: filter == .dependencies ? usage(of: package) : nil
            )
        }
    }

    /// brew cleanup's word on what's unneeded wins; else the direct dependents.
    private func usage(of package: Package) -> DependencyUsage? {
        if store.cleanup?.unneededFormulae.contains(package.name) == true { return .unneeded }
        let names = store.dependents(of: package.ref).map { store.package($0)?.title ?? $0.name }
        return names.isEmpty ? nil : .usedBy(names)
    }

    private var packages: [Package] {
        let filtered = store.installed.filter(filter.includes)
        switch sort {
        case .name:
            return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recent:
            return filtered.sorted { ($0.installedAt ?? .distantPast) > ($1.installedAt ?? .distantPast) }
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .pinned: "Nothing Pinned"
        case .dependencies: "No Dependencies"
        case .attention: "Nothing Needs Attention"
        default: "Nothing Installed"
        }
    }

    private var emptyMessage: String? {
        filter == .attention ? "Packages Homebrew deprecates or disables appear here, with why and what to use instead." : nil
    }
}

private struct LibraryRow: View {
    let package: Package
    let update: OutdatedItem?
    /// Needs Attention says why in place of the description.
    var showsReason = false
    /// Dependencies says what needs each one.
    var dependencyUsage: DependencyUsage?

    var body: some View {
        PackageRow(
            ref: package.ref,
            title: package.title,
            subtitle: showsReason ? package.attentionSummary : package.desc
        ) {
            HStack(spacing: 6) {
                if package.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange).help("Pinned") }
                if package.disabled {
                    Tag("Disabled", color: .red)
                } else if package.deprecated {
                    Tag("Deprecated", color: .orange)
                }
                usage
                version
            }
        }
    }

    /// The installed version, or "1.2 → 1.3" in the accent color when there's
    /// an update. Long versions lose their middle, keeping both ends readable.
    private var version: some View {
        let installed = package.installedVersions.last ?? ""
        return Group {
            if let update {
                Text("\(installed) → \(update.currentVersion)")
                    .foregroundStyle(Color.accentColor)
                    .help("Update available")
            } else {
                Text(installed)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout.monospacedDigit())
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: update == nil ? 120 : 200, alignment: .trailing)
    }

    /// For a dependency: what needs it, or that nothing does any more.
    @ViewBuilder
    private var usage: some View {
        switch dependencyUsage {
        case .unneeded:
            Tag("Not Needed")
                .help("Nothing installed needs it any more. Clean Up removes it.")
        case let .usedBy(names):
            let more = names.count > 2 ? " +\(names.count - 2)" : ""
            Text("Used by \(names.prefix(2).joined(separator: ", "))\(more)")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help("Used by \(names.joined(separator: ", "))")
        case nil:
            EmptyView()
        }
    }
}

private enum DependencyUsage {
    case unneeded
    case usedBy([String])
}

/// Everything you can do to a package: its context menu everywhere, the `⋯`
/// menu on its page, and the menu bar's Package menu (which has no environment,
/// hence the explicit store).
struct PackageMenu: View {
    let store: BrewStore
    let ref: PackageRef

    var body: some View {
        let busy = store.isBusy(ref)
        let installed = store.installedPackage(ref)
        if let package = installed {
            if let item = store.availableUpdate(ref) {
                Button(ref == store.selfRef ? "Update to \(item.currentVersion) and Relaunch" : "Update to \(item.currentVersion)") {
                    store.enqueue(.upgrade(ref))
                }
                    .disabled(busy)
                if store.updatesOnQuit(ref) {
                    Button("Don't Update When I Quit") { store.updateOnQuit(ref, false) }
                } else if store.isOpenDuringUpdate(ref) {
                    Button("Update When I Quit") { store.updateOnQuit(ref) }
                        .disabled(busy)
                }
            }
            if let record = store.revertibleUpdate(ref) {
                Button("Revert to \(ref.kind.upstreamVersion(record.from))…") { Task { await store.requestRevert(record) } }
                    .disabled(busy)
            }
            if let path = package.appPath, FileManager.default.fileExists(atPath: path) {
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                Button("Show in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
            }
            Button(package.pinned ? "Unpin" : "Pin") {
                store.enqueue(package.pinned ? .unpin(ref) : .pin(ref))
            }
            .disabled(busy)
            // Mends a broken install, and catches brew up with an app that updated itself.
            Button(ref == store.selfRef ? "Reinstall and Relaunch" : "Reinstall") { store.enqueue(.reinstall(ref)) }
                .disabled(busy)
                .help(BrewOperation.reinstall(ref).command)
        } else if store.isAdoptable(ref) {
            Button("Adopt") { store.enqueue(.adopt(ref)) }
                .disabled(busy)
        } else {
            Button("Install") { store.enqueue(.install(ref)) }
                .disabled(busy)
        }
        if let homepage = store.package(ref)?.homepage {
            Button("Open Homepage") { NSWorkspace.shared.open(homepage) }
        }
        if let entry = store.serviceEntry(ref) {
            Divider()
            ServiceMenu(store: store, entry: entry)
        }
        if installed != nil {
            Divider()
            Button("Uninstall…", role: .destructive) { store.uninstallCandidate = ref }
                .disabled(busy)
        } else if store.isAdoptable(ref), let path = store.package(ref)?.appPath {
            // Installed by hand: no brew command, but the same sheet.
            Divider()
            Button("Uninstall App…", role: .destructive) { store.uninstallApp(at: URL(fileURLWithPath: path)) }
                .disabled(store.appRemoval != nil)
        }
    }
}

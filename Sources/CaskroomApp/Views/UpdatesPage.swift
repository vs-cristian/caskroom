import BrewKit
import SwiftUI

struct UpdatesPage: View {
    @Environment(BrewStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the page appeared: updates that finish after it just emptied the list.
    @State private var openedAt = Date.now

    var body: some View {
        Group {
            if store.outdated.isEmpty && store.lastRefreshed == nil {
                // Not "up to date" until brew has said so.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.outdated.isEmpty && recent.isEmpty {
                EmptyPage(
                    title: "You're Up to Date",
                    symbol: "checkmark.circle.fill",
                    message: "Check Now fetches the latest package index from Homebrew.",
                    tint: .green
                )
            } else {
                List {
                    if items.isEmpty {
                        // The checkmark draws in only when you watched the last update finish.
                        UpToDateRow(drawsIn: recent.first.map { $0.date > openedAt } ?? false)
                    } else {
                        Section {
                            ForEach(items) { item in
                                NavigationLink(value: item.ref) {
                                    UpdateRow(item: item, package: store.installedPackage(item.ref))
                                }
                                .contextMenu { PackageMenu(store: store, ref: item.ref) }
                            }
                        } header: {
                            if !recent.isEmpty { Text("Available") }
                        }
                    }
                    if !recent.isEmpty {
                        Section("Updated Recently") {
                            ForEach(recent) { record in
                                NavigationLink(value: record.ref) {
                                    RecentUpdateRow(record: record, package: store.installedPackage(record.ref))
                                }
                                .contextMenu { PackageMenu(store: store, ref: record.ref) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                // Rows added to a list that was empty keep AppKit's default
                // height instead of their own; a minimum keeps them whole.
                .environment(\.defaultMinListRowHeight, 56)
                // An updated package slides out of Available and into Updated Recently.
                .animation(Motion.list(reduceMotion: reduceMotion), value: items.map(\.ref) + recent.map(\.ref))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CleanupBanner()
        }
        .animation(Motion.standard, value: store.outdated.isEmpty)
        .navigationTitle("Updates")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button("Check Now", systemImage: "arrow.trianglehead.2.clockwise") { store.enqueue(.update) }
                    .disabled(store.isPending(.update))
                    .symbolEffect(.rotate, isActive: store.isPending(.update))
                    .help("Fetch the latest package index (brew update)")
            }
            ToolbarItem {
                Button("Update All") { store.enqueue(store.upgradeAll) }
                    .glassButton(prominent: true)
                    .disabled(!store.canUpgradeAll || store.isPending(store.upgradeAll))
                    .help(updateAllHelp)
            }
        }
    }

    private var recent: [UpdateRecord] { store.recentUpdates }

    private var items: [OutdatedItem] {
        store.outdated.sorted { $0.ref.name.localizedStandardCompare($1.ref.name) == .orderedAscending }
    }

    private var updateAllHelp: String {
        let held = store.heldBack.map { store.installedPackage($0)?.title ?? $0.name }
        guard !held.isEmpty else { return store.upgradeAll.command }
        return "Leaves \(held.formatted(.list(type: .and))) for later: \(held.count == 1 ? "it's" : "they're") open. \(store.upgradeAll.command)"
    }

    private var subtitle: String {
        let count = store.outdated.count
        let available = count == 0 ? "No updates" : count == 1 ? "1 available" : "\(count) available"
        guard let date = store.lastRefreshed else { return available }
        return "\(available) · checked \(date.relative)"
    }
}

private struct UpdateRow: View {
    @Environment(BrewStore.self) private var store
    let item: OutdatedItem
    let package: Package?

    var body: some View {
        PackageRow(
            ref: item.ref,
            title: package?.title ?? item.ref.name,
            subtitle: package?.desc,
            iconSize: 44
        ) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.installedVersions.last ?? "?").foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(item.currentVersion).fontWeight(.medium)
                }
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                HStack(spacing: 4) {
                    if let finding = store.vulnerabilities(of: item.ref) {
                        Tag("Vulnerable", color: .red)
                            .help("OSV.dev lists \(finding.vulnerabilities.count) known \(finding.vulnerabilities.count == 1 ? "vulnerability" : "vulnerabilities") in \(finding.version). See Security.")
                    }
                    if item.pinned {
                        Tag("Pinned", color: .orange)
                    } else if item.ref == store.selfRef {
                        Tag("This App", color: .orange)
                            .help("Updating Caskroom quits it, and it opens again once Homebrew is done, so Update All leaves it out.")
                    } else if store.isOpenDuringUpdate(item.ref) {
                        Tag("Open", color: .orange)
                            .help("\(package?.title ?? item.ref.name) is open, and Homebrew would replace it while it runs, so Update All leaves it for later. Update it now, or when you quit it.")
                    } else if package?.autoUpdates == true {
                        // Listed greedily, it goes by brew's records and may be current already.
                        Tag("Updates itself")
                            .help(store.greedyAutoUpdates
                                ? "This app keeps itself up to date. Homebrew lists it until it reinstalls it, even if the app is already current."
                                : "This app keeps itself up to date, and may get to this version before you update it here.")
                    }
                }
                if let package {
                    WhatsNewButton(package: package, update: item)
                }
            }
            PrimaryActionButton(ref: item.ref)
                .controlSize(.small)
                .frame(minWidth: 80, alignment: .trailing)
        }
    }
}

/// Stands in for the Available section when there's nothing to update, above
/// Updated Recently.
private struct UpToDateRow: View {
    var drawsIn = false

    var body: some View {
        HStack(spacing: 12) {
            DrawnSymbol(systemName: "checkmark.circle.fill", drawsIn: drawsIn)
                .font(.title)
                .foregroundStyle(.green.gradient)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're Up to Date").font(.body.weight(.medium))
                Text("Check Now fetches the latest package index from Homebrew.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct RecentUpdateRow: View {
    @Environment(BrewStore.self) private var store
    let record: UpdateRecord
    let package: Package?

    var body: some View {
        PackageRow(
            ref: record.ref,
            title: package?.displayName ?? record.title ?? record.name,
            subtitle: package?.desc,
            iconSize: 44
        ) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text(record.from).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(record.to).fontWeight(.medium)
                }
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                HStack(spacing: 6) {
                    if store.revertibleUpdate(record.ref) == record, !store.isBusy(record.ref) {
                        Button("Revert to \(record.ref.kind.upstreamVersion(record.from))") {
                            Task { await store.requestRevert(record) }
                        }
                        .buttonStyle(.link)
                        .help("Install \(record.from) again with brew version-install")
                    }
                    Text(record.date.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            PrimaryActionButton(ref: record.ref)
                .controlSize(.small)
                .frame(minWidth: 80, alignment: .trailing)
        }
    }
}

/// What `brew cleanup` would free, along the bottom of Updates, with a button
/// to do it. Hidden when there's nothing worth cleaning.
private struct CleanupBanner: View {
    @Environment(BrewStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            banner
        }
        .animation(Motion.standard, value: store.cleanup)
    }

    @ViewBuilder
    private var banner: some View {
        if let cleanup = store.cleanup, !cleanup.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.blue.gradient)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(cleanup)).font(.headline)
                    Text(detail(cleanup)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if store.isPending(.cleanup) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Clean Up") { store.enqueue(.cleanup) }
                        .glassButton()
                        .help(BrewOperation.cleanup.command)
                }
            }
            .padding(12)
            .animation(Motion.standard, value: store.isPending(.cleanup))
            // Content, not a control, so no glass.
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(12)
            .transition(.move(from: .bottom, reduceMotion: reduceMotion))
        }
    }

    private func title(_ cleanup: CleanupSummary) -> String {
        cleanup.reclaimable.map { "Free up \($0)" } ?? "Remove unused dependencies"
    }

    private func detail(_ cleanup: CleanupSummary) -> String {
        var parts: [String] = []
        if cleanup.reclaimable != nil { parts.append("Old versions and downloads Homebrew no longer needs") }
        let unneeded = cleanup.unneededFormulae
        if !unneeded.isEmpty {
            let names = unneeded.count <= 3 ? unneeded.formatted(.list(type: .and)) : "\(unneeded.count) packages"
            parts.append("\(names) \(unneeded.count == 1 ? "isn't" : "aren't") needed by anything installed")
        }
        return parts.joined(separator: ". ") + "."
    }
}

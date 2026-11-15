import AppKit
import BrewKit
import SwiftUI

struct RootView: View {
    @Environment(BrewStore.self) private var store
    @FocusState private var searchFocused: Bool

    var body: some View {
        if store.service == nil {
            EmptyPage(
                title: "Homebrew Not Found",
                symbol: "mug",
                message: "Caskroom looks for brew in /opt/homebrew and /usr/local. Install it from brew.sh, then reopen Caskroom."
            )
        } else {
            main
        }
    }

    private var main: some View {
        @Bindable var store = store
        return NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            NavigationStack(path: $store.path) {
                page
                    .navigationDestination(for: PackageRef.self) { ref in
                        PackageDetailPage(ref: ref)
                    }
                    .navigationDestination(for: DiscoverList.self) { list in
                        DiscoverListPage(list: list)
                    }
            }
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search Homebrew")
        .searchFocused($searchFocused)
        .toolbar {
            if #available(macOS 26, *) {
                ToolbarItem(placement: .principal) {
                    ActivityPill()
                }
                // The pill draws its own glass so it can morph.
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) {
                    ActivityPill()
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            LoadErrorBanner()
        }
        .confirmationDialog(
            uninstallTitle,
            isPresented: Binding(
                get: { store.uninstallCandidate != nil },
                set: { if !$0 { store.uninstallCandidate = nil } }
            ),
            presenting: store.uninstallCandidate
        ) { ref in
            if store.dependents(of: ref).isEmpty {
                Button("Uninstall", role: .destructive) { store.enqueue(store.uninstallOperation(ref)) }
                if store.package(ref)?.hasZap == true {
                    Button("Uninstall and Delete App Data", role: .destructive) { store.enqueue(store.uninstallOperation(ref, zap: true)) }
                }
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { ref in
            let dependents = store.dependents(of: ref)
            if !dependents.isEmpty {
                Text("\(dependents.map(\.name).formatted(.list(type: .and))) \(dependents.count == 1 ? "depends" : "depend") on it. Homebrew won't uninstall it until \(dependents.count == 1 ? "that's" : "they're") uninstalled.")
            } else if store.package(ref)?.hasZap == true {
                Text("The app is removed from your Applications folder. Deleting its data also removes its settings, caches and support files, including any it shares with other apps.")
            } else if ref.kind == .cask {
                Text("The app is removed from your Applications folder.")
            } else {
                Text("Nothing you have installed depends on it.")
            }
        }
        .confirmationDialog(
            revertTitle,
            isPresented: Binding(
                get: { store.revertRequest != nil },
                set: { if !$0 { store.revertRequest = nil } }
            ),
            presenting: store.revertRequest
        ) { request in
            Button("Revert") { store.enqueue(request.operation) }
        } message: { request in
            Text(revertMessage(request))
        }
        .confirmationDialog(
            bulkUninstallTitle,
            isPresented: Binding(
                get: { store.bulkUninstall != nil },
                set: { if !$0 { store.bulkUninstall = nil } }
            ),
            presenting: store.bulkUninstall
        ) { plan in
            if plan.order.isEmpty {
                Button("OK", role: .cancel) {}
            } else {
                Button(plan.order.count == 1 ? "Uninstall" : "Uninstall \(plan.order.count)", role: .destructive) { store.uninstall(plan) }
            }
        } message: { plan in
            Text(bulkUninstallMessage(plan))
        }
        .sheet(item: $store.brewfileImport) { preview in
            BrewfileImportSheet(preview: preview)
        }
        .sheet(isPresented: $store.addingTap) {
            AddTapSheet()
        }
        .sheet(isPresented: Binding(
            get: { store.doctor != nil },
            set: { if !$0 { store.doctor = nil } }
        )) {
            DoctorSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            searchFocused = true
        }
        // The Dock tile counts updates, as the sidebar does.
        .onChange(of: store.outdated.count, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        .task { await store.start() }
        .task { await store.checkPeriodically() }
        .task { await store.watchRunningApps() }
    }

    private var revertTitle: String {
        guard let request = store.revertRequest else { return "" }
        return "Revert \(request.ref.name) to \(request.version)?"
    }

    /// What `brew version-install` does that a plain downgrade wouldn't.
    private func revertMessage(_ request: RevertRequest) -> String {
        let name = request.ref.name
        let versioned = "\(name)@\(request.version)"
        var text = "Homebrew installs \(request.version) as \(versioned), from a personal tap it creates (yourname/versions), and will usually build it from source, which can take a while. \(name) \(request.current) stays installed but unlinked, so \(versioned) is the one you run. \(versioned) won't get updates or security fixes. To go back, uninstall \(versioned), then run brew link \(name)."
        if request.needsCoreTap {
            text += "\n\nFinding the old version needs Homebrew's full formula history first (brew tap --force homebrew/core), a download of a gigabyte or more."
        }
        return text
    }

    private var bulkUninstallTitle: String {
        guard let plan = store.bulkUninstall else { return "" }
        if plan.order.isEmpty { return "Can't Uninstall These Packages" }
        return plan.order.count == 1 ? "Uninstall \(title(plan.order[0]))?" : "Uninstall \(plan.order.count) Packages?"
    }

    /// What goes, and what stays because something else needs it.
    private func bulkUninstallMessage(_ plan: BulkUninstall) -> String {
        var parts: [String] = []
        if !plan.order.isEmpty {
            let sorted = plan.order.sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
            var text = "\(names(sorted)) will be uninstalled."
            if plan.order.contains(where: { $0.kind == .cask }) {
                text += " Apps are removed from your Applications folder, and their data stays."
            }
            parts.append(text)
        }
        for (ref, neededBy) in plan.kept {
            parts.append("\(title(ref)) stays: \(names(neededBy)) \(neededBy.count == 1 ? "depends" : "depend") on it.")
        }
        return parts.joined(separator: "\n\n")
    }

    private func title(_ ref: PackageRef) -> String {
        store.package(ref)?.title ?? ref.name
    }

    /// "a, b, c and 4 more"
    private func names(_ refs: [PackageRef]) -> String {
        let shown = refs.prefix(refs.count > 8 ? 6 : 8).map(title)
        let more = refs.count - shown.count
        return more > 0 ? shown.joined(separator: ", ") + " and \(more) more" : shown.formatted(.list(type: .and))
    }

    private var uninstallTitle: String {
        guard let ref = store.uninstallCandidate else { return "" }
        let name = store.package(ref)?.title ?? ref.name
        return store.dependents(of: ref).isEmpty ? "Uninstall \(name)?" : "Can't Uninstall \(name)"
    }

    @ViewBuilder
    private var page: some View {
        if !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchResultsPage(query: store.searchText)
        } else {
            switch store.sidebar {
            case .discover: DiscoverPage()
            case .updates: UpdatesPage()
            case .security: SecurityPage()
            case .services: ServicesPage()
            case .taps: TapsPage()
            case .adopt: AdoptPage()
            case let .library(filter): LibraryPage(filter: filter)
            }
        }
    }
}

/// Shown when a refresh failed, above every page.
struct LoadErrorBanner: View {
    @Environment(BrewStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            banner
        }
        .animation(Motion.standard, value: store.loadError)
    }

    /// Slides down from the toolbar, and back up when dismissed or resolved.
    @ViewBuilder
    private var banner: some View {
        if let error = store.loadError {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(error).font(.callout).lineLimit(3).textSelection(.enabled)
                Spacer()
                Button("Dismiss") { store.loadError = nil }.buttonStyle(.borderless)
            }
            .padding(10)
            // Content, not a control, so no glass.
            .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .transition(.move(from: .top, reduceMotion: reduceMotion))
        }
    }
}

extension Notification.Name {
    static let focusSearch = Notification.Name("CaskroomFocusSearch")
}

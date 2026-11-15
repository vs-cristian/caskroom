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

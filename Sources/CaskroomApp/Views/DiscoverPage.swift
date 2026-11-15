import BrewKit
import SwiftUI

/// App Store-style front page: what's relevant to this Mac first, then what
/// everyone installs, what's catching on and what's new, ranked by Homebrew's
/// analytics, and a few collections.
struct DiscoverPage: View {
    @Environment(BrewStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                DiscoverHero()
                if store.discover.isEmpty {
                    if let error = store.discoverError, !store.isLoadingDiscover {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Couldn't load what's popular: \(error)", systemImage: "wifi.exclamationmark")
                                .foregroundStyle(.secondary)
                            Button("Try Again") { Task { await reloadDiscover() } }
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                } else {
                    Shelf(list: .topApps)
                    if !store.discover.trending.isEmpty {
                        Shelf(list: .trending)
                    }
                    Shelf(list: .topTools)
                }
                if !store.newRefs.isEmpty {
                    Shelf(list: .new)
                }
                Collections()
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Discover")
        // The hero counts apps Homebrew could take over; the scan is the Adopt page's.
        .task { if store.adoption == nil { await store.scanAdoptableApps() } }
        // Coming back to a Discover that failed (or never finished) tries again.
        .task { if store.discover.isEmpty && store.discoverError != nil { await reloadDiscover() } }
    }

    private func reloadDiscover() async {
        if store.searchIndex.isEmpty { await store.loadSearchIndex() }
        await store.loadDiscover()
    }
}

/// The banner at the top: the one thing worth doing now (updates waiting,
/// apps to adopt), else what's trending, else a way into search.
private struct DiscoverHero: View {
    @Environment(BrewStore.self) private var store
    @Environment(\.colorSchemeContrast) private var contrast

    private enum Highlight {
        case updates([PackageRef])
        case adoptable(Int)
        case trending(PackageRef, HomebrewAnalytics.Climb)
        case search

        var isSearch: Bool { if case .search = self { true } else { false } }
    }

    private var highlight: Highlight {
        let updates = store.outdated.filter { !$0.pinned }.map(\.ref)
        if !updates.isEmpty { return .updates(updates) }
        let adoptable = store.adoptableApps.count
        if adoptable > 0 { return .adoptable(adoptable) }
        if let climb = store.discover.trending.first(where: { store.package($0.ref) != nil }) {
            return .trending(climb.ref, climb)
        }
        return .search
    }

    var body: some View {
        let highlight = highlight
        Button { open(highlight) } label: {
            ZStack(alignment: .leading) {
                // Deep enough that white body text clears 4.5:1 with the scrim,
                // even at the light corner.
                LinearGradient(
                    colors: [Color(red: 0.90, green: 0.42, blue: 0.12), Color(red: 0.74, green: 0.24, blue: 0.18), Color(red: 0.45, green: 0.13, blue: 0.32)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                LinearGradient(
                    colors: [.black.opacity(contrast == .increased ? 0.45 : 0.22), .clear],
                    startPoint: .bottom, endPoint: .top
                )
                HStack(spacing: 18) {
                    artwork(highlight)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(eyebrow(highlight))
                            .font(.callout.weight(.semibold))
                            .textCase(.uppercase)
                            .opacity(0.85)
                        Text(title(highlight))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Text(subtitle(highlight))
                            .font(.body)
                            .lineLimit(1)
                            .opacity(0.9)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: highlight.isSearch ? "magnifyingglass" : "chevron.right")
                        .font(.title2.weight(.semibold))
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
            }
            .frame(height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .accessibilityLabel("\(title(highlight)). \(subtitle(highlight))")
        .animation(Motion.standard, value: title(highlight))
    }

    @ViewBuilder
    private func artwork(_ highlight: Highlight) -> some View {
        switch highlight {
        case let .trending(ref, _):
            PackageIcon(ref: ref, size: 64)
        default:
            Image(systemName: symbol(highlight))
                .font(.system(size: 34, weight: .medium))
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
    }

    private func symbol(_ highlight: Highlight) -> String {
        switch highlight {
        case .updates: SidebarItem.updates.symbol
        case .adoptable: SidebarItem.adopt.symbol
        case .trending: "chart.line.uptrend.xyaxis"
        case .search: "mug.fill"
        }
    }

    private func eyebrow(_ highlight: Highlight) -> String {
        switch highlight {
        case .updates: "Updates"
        case .adoptable: "Adopt Apps"
        case .trending: "Trending"
        case .search: "Homebrew"
        }
    }

    private func title(_ highlight: Highlight) -> String {
        switch highlight {
        case let .updates(refs): refs.count == 1 ? "1 update ready" : "\(refs.count) updates ready"
        case let .adoptable(count): count == 1 ? "1 app on this Mac Homebrew can manage" : "\(count) apps on this Mac Homebrew can manage"
        case let .trending(ref, _): store.package(ref)?.title ?? ref.name
        case .search: "Search everything Homebrew has"
        }
    }

    private func subtitle(_ highlight: Highlight) -> String {
        switch highlight {
        case let .updates(refs):
            let names = refs.prefix(3).map { store.package($0)?.title ?? $0.name }
            let rest = refs.count - names.count
            return names.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
        case .adoptable:
            return "Installed by hand. Adopt them so Homebrew keeps them up to date."
        case let .trending(ref, climb):
            let desc = store.package(ref)?.desc.map { "\($0) · " } ?? ""
            return "\(desc)#\(climb.rank) this month, up from #\(climb.earlierRank)"
        case .search:
            let index = store.searchIndex
            guard !index.isEmpty else { return "Every formula and cask, one search away." }
            return "\(index.formulae.count.formatted()) formulae and \(index.casks.count.formatted()) casks, one search away."
        }
    }

    private func open(_ highlight: Highlight) {
        switch highlight {
        case .updates: store.sidebar = .updates
        case .adoptable: store.sidebar = .adopt
        case let .trending(ref, _): store.path.append(ref)
        case .search: NotificationCenter.default.post(name: .focusSearch, object: nil)
        }
    }
}

/// A list's first dozen in a grid, its title opening the whole list.
private struct Shelf: View {
    @Environment(BrewStore.self) private var store
    let list: DiscoverList

    var body: some View {
        let refs = store.refs(list)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                NavigationLink(value: list) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(list.title).font(.title2.weight(.bold))
                            Image(systemName: "chevron.right")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(list.subtitle).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if refs.count > BrewStore.shelfLength {
                    NavigationLink("See All", value: list)
                        .buttonStyle(.link)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 28, alignment: .top)], spacing: 0) {
                ForEach(Array(refs.prefix(BrewStore.shelfLength).enumerated()), id: \.element) { index, ref in
                    ShelfItem(ref: ref, rank: list.isRanked ? index + 1 : nil, note: note(for: ref))
                }
            }
        }
    }

    private func note(for ref: PackageRef) -> String? {
        guard list == .trending, let climb = store.discover.trending.first(where: { $0.ref == ref }) else { return nil }
        return "Up from #\(climb.earlierRank)"
    }
}

private struct ShelfItem: View {
    @Environment(BrewStore.self) private var store
    let ref: PackageRef
    let rank: Int?
    let note: String?

    var body: some View {
        let package = store.package(ref)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                NavigationLink(value: ref) {
                    HStack(spacing: 12) {
                        PackageIcon(ref: ref, size: 56)
                        if let rank {
                            Text("\(rank)")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 14)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(package?.title ?? ref.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                if let note {
                                    Tag(note, color: .green)
                                }
                            }
                            Text(package?.desc ?? " ")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                // Two lines, held even for a short one, so rows line up.
                                .lineLimit(2, reservesSpace: true)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { PackageMenu(store: store, ref: ref) }
                PrimaryActionButton(ref: ref)
                    .controlSize(.small)
            }
            .padding(.vertical, 10)
            Divider().padding(.leading, 68)
        }
        .task { store.requestInfo(ref) }
    }
}

/// Cards for each collection, each opening its list.
private struct Collections: View {
    @Environment(BrewStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Collections").font(.title2.weight(.bold))
                Text("Homebrew has no categories; these come from its data and a few short lists.")
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                ForEach(PackageCollection.allCases, id: \.self) { collection in
                    let count = store.refs(collection).count
                    NavigationLink(value: DiscoverList.collection(collection)) {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: collection.symbol)
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(collection.title).font(.headline)
                                Text(count == 0 ? "Loading…" : "\(count.formatted()) packages")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(count == 0)
                }
            }
        }
    }
}

/// A Discover list in full: a chart's top hundred, or every package in a
/// collection. Each row's info is fetched as it scrolls into view.
struct DiscoverListPage: View {
    @Environment(BrewStore.self) private var store
    let list: DiscoverList

    var body: some View {
        let refs = store.refs(list)
        Group {
            if refs.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    // What the list is, read once and scrolled away: a sticky
                    // section header looked like a heading over every row.
                    Text(list.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                    ForEach(Array(refs.enumerated()), id: \.element) { index, ref in
                        NavigationLink(value: ref) {
                            HStack(spacing: 10) {
                                if list.isRanked {
                                    Text("\(index + 1)")
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(minWidth: 24, alignment: .trailing)
                                }
                                PackageRow(ref: ref, title: store.package(ref)?.title ?? ref.name, subtitle: subtitle(ref)) {
                                    DiscoverListTrailing(ref: ref)
                                }
                            }
                        }
                        .contextMenu { PackageMenu(store: store, ref: ref) }
                        .onAppear { store.requestInfo(ref) }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
                // Rows added to a list that was empty keep AppKit's default
                // height instead of their own; a minimum keeps them whole.
                .environment(\.defaultMinListRowHeight, 44)
            }
        }
        .navigationTitle(list.title)
        .navigationSubtitle(refs.isEmpty ? "" : "\(refs.count.formatted()) packages")
    }

    private func subtitle(_ ref: PackageRef) -> String {
        var parts: [String] = []
        if list == .trending, let climb = store.discover.trending.first(where: { $0.ref == ref }) {
            parts.append("#\(climb.rank), up from #\(climb.earlierRank)")
        }
        if list == .new, let new = store.newPackages.first(where: { $0.ref == ref }) {
            parts.append("Added \(new.date.formatted(date: .abbreviated, time: .omitted))")
        }
        // Many casks (fonts especially) have no description; the token at least says which.
        if let package = store.package(ref) {
            parts.append(package.desc ?? ref.name)
        }
        return parts.joined(separator: " · ")
    }
}

/// A Discover list row's right side: installs this month, or an installed
/// service's state, then the package's action. An installed service with
/// nothing else to do offers Run or Stop where a dead "Installed" would be.
private struct DiscoverListTrailing: View {
    @Environment(BrewStore.self) private var store
    let ref: PackageRef

    var body: some View {
        HStack(spacing: 12) {
            if let entry = store.serviceEntry(ref) {
                HStack(spacing: 5) {
                    StatusDot(status: entry.status)
                    Text(entry.status.label)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else if let installs = store.discover.monthly[ref]?.installs {
                Text("\(installs.formatted(.number.notation(.compactName))) installs")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("\(installs.formatted()) installs in the last 30 days")
            }
            Group {
                if let entry = store.serviceEntry(ref), showsServiceControl {
                    ServiceRunButton(entry: entry)
                } else {
                    PrimaryActionButton(ref: ref)
                }
            }
            .controlSize(.small)
        }
        .animation(Motion.standard, value: store.serviceEntry(ref)?.status)
    }

    /// Nothing for PrimaryActionButton to say beyond "Installed": no update,
    /// no work in progress, no result still showing.
    private var showsServiceControl: Bool {
        guard store.installedPackage(ref) != nil, !store.isBusy(ref), store.settlingRun(for: ref) == nil else { return false }
        guard let item = store.outdatedItem(ref) else { return true }
        return item.pinned
    }
}

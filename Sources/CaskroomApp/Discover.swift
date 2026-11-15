import BrewKit
import Foundation

/// A list Discover shows a shelf of and, behind its title, a full page.
enum DiscoverList: Hashable {
    case topApps, topTools, trending, new
    case collection(PackageCollection)

    var title: String {
        switch self {
        case .topApps: "Top Apps"
        case .topTools: "Top Command-Line Tools"
        case .trending: "Trending"
        case .new: "New in Homebrew"
        case let .collection(collection): collection.title
        }
    }

    var subtitle: String {
        switch self {
        case .topApps: "Most installed apps this month"
        case .topTools: "Most installed formulae and command-line casks this month"
        case .trending: "Climbing fastest this month, against the last three"
        case .new: "Added since Caskroom last looked"
        case let .collection(collection): collection.subtitle
        }
    }

    /// Whether its order is a ranking worth numbering.
    var isRanked: Bool {
        switch self {
        case .topApps, .topTools: true
        default: false
        }
    }
}

/// Homebrew has no categories. Fonts and background services come from the
/// data; the others are short hand-written lists, checked against Homebrew's
/// names so a renamed cask just drops out.
enum PackageCollection: String, CaseIterable, Hashable {
    case browsers, terminals, editors, fonts, services

    var title: String {
        switch self {
        case .browsers: "Browsers"
        case .terminals: "Terminals"
        case .editors: "Editors"
        case .fonts: "Fonts"
        case .services: "Background Services"
        }
    }

    var subtitle: String {
        switch self {
        case .browsers: "Web browsers, most installed first"
        case .terminals: "Terminal apps, most installed first"
        case .editors: "Code and text editors, most installed first"
        case .fonts: "Every font cask, most installed first"
        case .services: "Formulae that run in the background with brew services: databases, servers, agents"
        }
    }

    var symbol: String {
        switch self {
        case .browsers: "safari"
        case .terminals: "apple.terminal"
        case .editors: "chevron.left.forwardslash.chevron.right"
        case .fonts: "textformat"
        case .services: "gearshape.2"
        }
    }

    /// The hand-written lists.
    var curated: [PackageRef] {
        switch self {
        case .browsers:
            Self.casks("google-chrome", "firefox", "arc", "brave-browser", "microsoft-edge", "vivaldi", "zen", "orion",
                       "opera", "librewolf", "tor-browser", "chromium", "duckduckgo", "waterfox", "floorp")
        case .terminals:
            Self.casks("iterm2", "ghostty", "warp", "wezterm", "alacritty", "kitty", "tabby", "hyper", "wave", "rio")
        case .editors:
            Self.casks("visual-studio-code", "cursor", "zed", "sublime-text", "bbedit", "coteditor", "nova", "vscodium",
                       "macvim-app", "textmate", "emacs-app", "intellij-idea-ce", "intellij-idea", "pycharm-ce", "pycharm",
                       "webstorm", "android-studio")
                + ["neovim", "vim", "helix", "micro", "emacs"].map { PackageRef(.formula, $0) }
        case .fonts, .services: []
        }
    }

    private static func casks(_ names: String...) -> [PackageRef] {
        names.map { PackageRef(.cask, $0) }
    }
}

/// A package Homebrew added, and when Caskroom first saw it.
struct NewPackage: Codable, Hashable {
    let kind: String
    let name: String
    let date: Date

    var ref: PackageRef { PackageRef(savedKind: kind, name: name) }

    init(_ ref: PackageRef, date: Date) {
        kind = ref.kind.rawValue
        name = ref.name
        self.date = date
    }
}

/// Every name Homebrew had last time, kept so the next look (after each
/// `brew update`) can tell what's new without asking anyone. Names that
/// disappeared at the same time are kept too: a new name whose package lists
/// one as an old name is a rename, not something new.
struct KnownPackages: Codable {
    var formulae: [String]
    var casks: [String]
    var added: [NewPackage] = []
    var removed: [NewPackage] = []

    /// How long a package counts as new.
    static let window: TimeInterval = 60 * 24 * 3600
    /// More changes than this in one look isn't Homebrew adding packages
    /// (it adds a few dozen a week) but a list that was incomplete, before or now.
    static let largestChange = 1000

    private static let file: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "club.iscout.caskroom/KnownPackages.json")
    }()

    static func load() -> KnownPackages? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(KnownPackages.self, from: data)
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
    }

    /// The names in `index`, with what changed since the last look added to
    /// the recent lists. The first look has nothing to compare with, so it
    /// finds nothing new.
    static func updated(_ known: KnownPackages?, with index: SearchIndex, at date: Date = .now) -> KnownPackages {
        var next = KnownPackages(formulae: index.formulae, casks: index.casks)
        guard let known else { return next }
        let earlier = SearchIndex(formulae: known.formulae, casks: known.casks)
        let cutoff = date.addingTimeInterval(-window)
        var added = index.added(since: earlier)
        var removed = index.removed(since: earlier)
        if added.count > largestChange || removed.count > largestChange { (added, removed) = ([], []) }
        next.added = added.map { NewPackage($0, date: date) }
            + wholesaleChangesDropped(known.added).filter { $0.date > cutoff && index.contains($0.ref) }
        next.removed = removed.map { NewPackage($0, date: date) }
            + wholesaleChangesDropped(known.removed).filter { $0.date > cutoff }
        return next
    }

    /// Without any one look's changes that were too many to be real, as an
    /// earlier version could save.
    private static func wholesaleChangesDropped(_ packages: [NewPackage]) -> [NewPackage] {
        let counts = Dictionary(grouping: packages, by: \.date).mapValues(\.count)
        return packages.filter { counts[$0.date, default: 0] <= largestChange }
    }
}

/// Downloads kept in ~/Library/Caches/club.iscout.caskroom while fresh. Offline,
/// a stale copy beats none.
enum DownloadCache {
    private static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: "club.iscout.caskroom", directoryHint: .isDirectory)
    }()

    static func data(_ name: String, maxAge: TimeInterval, fetch: () async throws -> Data) async throws -> Data {
        let file = directory.appending(path: name)
        let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let modified, Date.now.timeIntervalSince(modified) < maxAge, let data = try? Data(contentsOf: file) {
            return data
        }
        do {
            let data = try await fetch()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return data
        } catch {
            if let data = try? Data(contentsOf: file) { return data }
            throw error
        }
    }

    static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

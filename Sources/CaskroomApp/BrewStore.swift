import AppKit
import BrewKit
import Observation
import SwiftUI

enum LibraryFilter: String, Hashable, CaseIterable, Identifiable {
    case all, apps, formulae, pinned, dependencies, attention

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All Packages"
        case .apps: "Apps"
        case .formulae: "Formulae"
        case .pinned: "Pinned"
        case .dependencies: "Dependencies"
        case .attention: "Needs Attention"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .apps: "macwindow"
        case .formulae: "terminal"
        case .pinned: "pin"
        case .dependencies: "point.3.connected.trianglepath.dotted"
        case .attention: "exclamationmark.triangle"
        }
    }

    func includes(_ package: Package) -> Bool {
        switch self {
        case .all: package.installedOnRequest
        case .apps: package.kind == .cask
        case .formulae: package.kind == .formula && package.installedOnRequest
        case .pinned: package.pinned
        case .dependencies: !package.installedOnRequest
        // Dependencies too: a deprecated one still stops getting fixes.
        case .attention: package.deprecated || package.disabled
        }
    }
}

enum SidebarItem: Hashable {
    case discover, updates, security, services, adopt
    case library(LibraryFilter)

    var title: String {
        switch self {
        case .discover: "Discover"
        case .updates: "Updates"
        case .security: "Security"
        case .services: "Services"
        case .adopt: "Adopt Apps"
        case let .library(filter): filter.title
        }
    }

    var symbol: String {
        switch self {
        case .discover: "sparkles"
        case .updates: "arrow.down.circle"
        case .security: "checkmark.shield"
        case .services: "gearshape.2"
        case .adopt: "square.and.arrow.down.on.square"
        case let .library(filter): filter.symbol
        }
    }
}

/// `brew vulns`, as the Security page shows it.
enum VulnerabilityCheck: Equatable {
    case checking
    case finished(VulnerabilityReport, at: Date)
    case failed(String)
}

/// An app installed by hand that a cask installs, for the Adopt page.
struct AdoptableApp: Identifiable, Equatable {
    var id: PackageRef { package.ref }
    let package: Package
    /// The copy in Applications; brew adopts it only at the cask's version,
    /// unless the app updates itself.
    let appVersion: String?

    var versionMatches: Bool {
        guard let appVersion, let caskVersion = package.latestVersion else { return false }
        return caskVersion.split(separator: ",").first.map(String.init) == appVersion
    }
}

/// The Adopt page's scan, nil until it's opened.
enum AdoptionScan: Equatable {
    case scanning
    case finished([AdoptableApp])
    case failed(String)
}

/// A formula update to undo, waiting for confirmation.
struct RevertRequest: Equatable {
    let ref: PackageRef
    /// The version to go back to, without Homebrew's rebuild suffix.
    let version: String
    /// The version that stays installed, unlinked.
    let current: String
    /// Whether homebrew/core's history has to be fetched first.
    let needsCoreTap: Bool

    var operation: BrewOperation { .revert(ref, to: version, tapCore: needsCoreTap) }

    /// Back to the version before `record`'s update.
    init(_ record: UpdateRecord, needsCoreTap: Bool) {
        ref = record.ref
        version = record.ref.kind.upstreamVersion(record.from)
        current = record.to
        self.needsCoreTap = needsCoreTap
    }
}

/// What Discover ranks, from Homebrew's public analytics and its name lists.
struct DiscoverCatalog {
    /// Casks with an app bundle, by installs this month.
    var topApps: [PackageRef] = []
    /// Formulae and casks without an app (Codex, the Android SDK tools…), by
    /// installs this month.
    var topTools: [PackageRef] = []
    var trending: [HomebrewAnalytics.Climb] = []
    /// Installs over 30 days and rank within its kind, for every package Homebrew counted.
    var monthly: [PackageRef: HomebrewAnalytics.Entry] = [:]

    var isEmpty: Bool { topApps.isEmpty && topTools.isEmpty }
}

/// What a package page shows beyond `brew info`, fetched when it opens.
struct PackageFacts {
    /// Installs over the last 30 days; nil when Homebrew doesn't count it.
    var monthlyInstalls: Int??
    /// On disk, for the installed version it was measured at.
    var size: (version: String, size: String?)?
    /// Every formula installing it would bring along, by name.
    var allDependencies: [String]?
}

/// `brew doctor`, as its sheet shows it.
enum DoctorState: Equatable {
    case checking
    case finished([DoctorWarning])
    case failed(String)
}

/// One queued or finished brew command and its output.
@Observable @MainActor
final class OperationRun: Identifiable {
    enum State: Equatable {
        case queued, running, succeeded, cancelled
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .queued, .running: false
            default: true
            }
        }
    }

    static let logLimit = 5000

    let id = UUID()
    let operation: BrewOperation
    /// Queued by Caskroom itself (the scheduled update check), not by you, so a
    /// failure neither opens the log nor posts a notification.
    let automatic: Bool
    var state: State = .queued
    var log: [LogLine] = []
    var finishedAt: Date?

    init(_ operation: BrewOperation, automatic: Bool = false) {
        self.operation = operation
        self.automatic = automatic
    }

    func append(_ line: LogLine) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }

    /// macOS refused to let brew change an app's bundle (`chgrp: …/Foo.app/…:
    /// Operation not permitted`): changing a notarized app in place needs App
    /// Management permission, and brew runs as Caskroom.
    var blockedByAppManagement: Bool {
        log.contains { $0.text.contains(".app") && $0.text.contains("Operation not permitted") }
    }

    /// Privacy & Security ▸ App Management.
    static let appManagementSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
}

@Observable @MainActor
final class BrewStore {
    /// nil when Homebrew isn't installed; the window shows a notice instead.
    let service: BrewService?

    /// Choosing a sidebar item returns its page to the top of the stack.
    var sidebar: SidebarItem = .library(.all) {
        didSet { if sidebar != oldValue { path = NavigationPath() } }
    }
    /// Pushed pages over the sidebar item's page: packages (`PackageRef`) and
    /// Discover's lists (`DiscoverList`).
    var path = NavigationPath()
    /// While non-empty, the root page shows search results instead.
    var searchText = "" {
        didSet { if searchText != oldValue { path = NavigationPath() } }
    }

    var installed: [Package] = []
    var outdated: [OutdatedItem] = []
    /// Updates already on screen or announced, so a scheduled check notifies
    /// only about new ones.
    @ObservationIgnored private var announcedUpdates: Set<PackageRef> = []
    /// Set when a scheduled check finishes; the next load announces what it found.
    @ObservationIgnored private var announceAfter: Date?
    var services: [ServiceEntry] = []
    var searchIndex = SearchIndex()
    /// `brew info` results for packages that aren't installed, fetched on selection.
    var infoCache: [PackageRef: Package] = [:]
    var infoErrors: [PackageRef: String] = [:]

    var isRefreshing = false
    private var refreshAgain = false
    var loadError: String?
    var lastRefreshed: Date?
    var brewVersion: String?

    var discover = DiscoverCatalog()
    var discoverError: String?
    var isLoadingDiscover = false
    /// What Homebrew added recently, newest first.
    var newPackages: [NewPackage] = []
    /// Names that disappeared recently: a "new" package that used one is a rename.
    @ObservationIgnored private var removedNames: Set<PackageRef> = []
    /// Formulae with a background service, for that Discover collection.
    var serviceFormulae: [String] = []
    /// `brew info` for packages Discover and its lists show, kept across
    /// refreshes (unlike `infoCache`) but dropped for any whose installed state changed.
    var catalog: [PackageRef: Package] = [:]
    @ObservationIgnored private var requestedInfo: Set<PackageRef> = []
    @ObservationIgnored private var wantedInfo: Set<PackageRef> = []
    @ObservationIgnored private var infoBatch: Task<Void, Never>?

    var facts: [PackageRef: PackageFacts] = [:]

    /// What `brew cleanup` would free; nil until checked, or when the check failed.
    var cleanup: CleanupSummary?

    /// `brew doctor`'s sheet, nil while it's closed; RootView shows it.
    var doctor: DoctorState?

    /// Whether Caskroom asks OSV.dev about installed formulae (`brew vulns`).
    /// Off until turned on: it sends their names and versions there.
    var checksVulnerabilities = UserDefaults.standard.bool(forKey: "CheckVulnerabilities") {
        didSet {
            guard checksVulnerabilities != oldValue else { return }
            UserDefaults.standard.set(checksVulnerabilities, forKey: "CheckVulnerabilities")
            if checksVulnerabilities {
                Task { await loadVulnerabilities() }
            } else {
                vulnerabilityCheck = nil
            }
        }
    }
    /// The last check, nil while checks are off.
    var vulnerabilityCheck: VulnerabilityCheck?
    /// Set when something that changes installed formulae finishes; the
    /// check runs again once the queue drains.
    @ObservationIgnored private var vulnerabilitiesStale = false

    /// The commands each formula installs, for search and package pages.
    var commandIndex = CommandIndex()

    var adoption: AdoptionScan?

    /// Set to ask before reverting; RootView shows the dialog.
    var revertRequest: RevertRequest?
    /// Whether homebrew/core is tapped, as `brew tap` last said; nil until
    /// asked, or when it couldn't say. Reverting needs its history.
    private(set) var coreTapped: Bool?

    /// Paths of the app bundles running now, to hold back an update brew
    /// would make under a running app.
    /// Filled at once, so a saved update-on-quit never sees an open app as closed.
    private(set) var runningApps: Set<String> = BrewStore.currentlyRunningApps()
    /// Apps to update once they quit, kept across launches.
    private(set) var updatesOnQuit: Set<PackageRef> = BrewStore.loadUpdatesOnQuit() {
        didSet {
            UserDefaults.standard.set(updatesOnQuit.map(\.savedString), forKey: "UpdateOnQuit")
        }
    }

    /// Caskroom's own cask, when this copy is the one brew installed: brew
    /// replaces its bundle, so it can't update through the queue.
    private(set) var selfRef: PackageRef?
    /// Set by Update and Relaunch until Caskroom quits.
    var selfUpgrade: BrewOperation?

    /// Whether Updates also lists casks that updated themselves since brew
    /// installed them. Off: brew already lists one whose app is really behind,
    /// and the others only need its records to catch up.
    var greedyAutoUpdates = UserDefaults.standard.bool(forKey: "GreedyAutoUpdates") {
        didSet {
            guard greedyAutoUpdates != oldValue else { return }
            UserDefaults.standard.set(greedyAutoUpdates, forKey: "GreedyAutoUpdates")
            Task { await refresh() }
        }
    }

    /// Update All, as the setting above has it, leaving out apps that are open
    /// and that brew would replace while they run.
    var upgradeAll: BrewOperation {
        let held = Set(heldBack)
        guard !held.isEmpty else { return .upgradeAll(greedy: greedyAutoUpdates) }
        let casks = outdated.filter { $0.ref.kind == .cask && !$0.pinned && !held.contains($0.ref) }.map(\.ref.name)
        return .upgradeAll(greedy: greedyAutoUpdates, casks: casks)
    }

    /// Updates Update All leaves for later: apps that are open now.
    var heldBack: [PackageRef] {
        outdated.filter { !$0.pinned && isOpenDuringUpdate($0.ref) }.map(\.ref)
    }

    /// Whether Update All has anything to do.
    var canUpgradeAll: Bool {
        let held = Set(heldBack)
        return outdated.contains { !$0.pinned && !held.contains($0.ref) }
    }

    /// Whether Caskroom runs `brew update` every few hours while it's open, as the
    /// App Store checks for updates.
    var checksAutomatically = UserDefaults.standard.object(forKey: "CheckAutomatically") as? Bool ?? true {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: "CheckAutomatically") }
    }
    static let checkInterval: Duration = .seconds(4 * 3600)
    /// When `brew update` last succeeded here, scheduled or by hand.
    @ObservationIgnored private var lastUpdateCheck = UserDefaults.standard.object(forKey: "LastUpdateCheck") as? Date {
        didSet { UserDefaults.standard.set(lastUpdateCheck, forKey: "LastUpdateCheck") }
    }

    /// Packages Caskroom updated, newest first, kept across launches.
    var history = UpdateHistory.load()
    let launchedAt = Date.now
    /// Versions installed when an update began, until a load after it ends
    /// shows which ones changed.
    @ObservationIgnored private var unconfirmedUpdates: [(run: OperationRun, versions: [PackageRef: String])] = []

    var operations: [OperationRun] = []
    var showActivity = false
    /// The last operation brew finished, until a refresh has picked up what it
    /// changed. Without it, a package's button would show Install again between
    /// the install ending and the refresh landing.
    private(set) var settling: OperationRun?
    /// Set to ask for confirmation before uninstalling; RootView shows the dialog.
    var uninstallCandidate: PackageRef?
    private var currentTask: Task<Void, Never>?

    init(service: BrewService?) {
        self.service = service
    }

    // MARK: Loading

    func start() async {
        guard let service else { return }
        pickUpSelfUpgrade()
        async let refresh: Void = refresh()
        // Discover checks its names against the index: analytics can name
        // packages Homebrew has since removed, which would fail a whole `brew info`.
        async let discover: Void = { await self.loadSearchIndex(); await self.loadDiscover() }()
        async let cleanup: Void = loadCleanup()
        async let commands: Void = loadCommandIndex()
        async let vulnerabilities: Void = checksVulnerabilities ? loadVulnerabilities() : ()
        async let services: Void = loadServiceFormulae()
        brewVersion = try? await service.version()
        _ = await (refresh, discover, cleanup, commands, vulnerabilities, services)
    }

    /// Reloads installed packages, updates and services together. A call that
    /// arrives mid-refresh makes the running one go round again, so a change that
    /// finished during a load is never missed.
    func refresh() async {
        guard let service else { return }
        if isRefreshing {
            refreshAgain = true
            return
        }
        isRefreshing = true
        repeat {
            refreshAgain = false
            await load(from: service)
        } while refreshAgain
        isRefreshing = false
        // Whatever finished before this pass began is in the data now.
        settling = nil
    }

    /// Every few hours, `brew update` through the queue, so Updates, the sidebar
    /// and the Dock show what's new without asking. Polls rather than sleeping
    /// the whole interval, so a Mac that slept through it checks soon after waking.
    func checkPeriodically() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(300))
            guard checksAutomatically, service != nil, !isPending(.update) else { continue }
            if let last = lastUpdateCheck, Duration.seconds(Date.now.timeIntervalSince(last)) < Self.checkInterval { continue }
            enqueue(.update, automatic: true)
        }
    }

    private func load(from service: BrewService) async {
        let started = Date.now
        async let installed = capture { try await service.installed() }
        async let outdated = capture { [greedyAutoUpdates] in
            try await service.outdated(greedy: greedyAutoUpdates)
        }
        async let services = capture { try await service.services() }
        let results = await (installed, outdated, services)

        var errors: [String] = []
        switch results.0 {
        case let .success(value):
            self.installed = value
            selfRef = Self.ownCask(in: value)
            dropStaleCatalog()
        case let .failure(error): errors.append(error.localizedDescription)
        }
        switch results.1 {
        case let .success(value):
            self.outdated = value
            announceUpdates(finishedBefore: started)
        case let .failure(error): errors.append(error.localizedDescription)
        }
        switch results.2 {
        case let .success(value): self.services = value
        case let .failure(error): errors.append(error.localizedDescription)
        }
        recordUpdates(finishedBefore: started)
        loadError = errors.isEmpty ? nil : errors.joined(separator: "\n\n")
        lastRefreshed = .now
        updateQuitApps()
        // Installed state may have changed; cached info for those packages is stale.
        infoCache = [:]
        infoErrors = [:]
    }

    /// After a scheduled check, one notification for updates nobody has seen yet.
    /// Updates the first load finds are on screen, so they count as seen.
    private func announceUpdates(finishedBefore start: Date) {
        let available = outdated.filter { !$0.pinned }
        let new = available.filter { !announcedUpdates.contains($0.ref) }
        announcedUpdates = Set(available.map(\.ref))
        guard let due = announceAfter, due <= start else { return }
        announceAfter = nil
        if !new.isEmpty {
            Notifier.updatesAvailable(new.map { installedPackage($0.ref)?.title ?? $0.ref.name })
        }
    }

    /// Adds to the history each package whose version changed under an update
    /// that ended before this load began. Comparing versions, rather than
    /// trusting how the run ended, also catches an Update All that failed partway.
    private func recordUpdates(finishedBefore start: Date) {
        let ready = unconfirmedUpdates.filter { $0.run.finishedAt.map { $0 <= start } ?? false }
        guard !ready.isEmpty else { return }
        unconfirmedUpdates.removeAll { pending in ready.contains { $0.run === pending.run } }
        var records: [UpdateRecord] = []
        for (run, versions) in ready {
            for (ref, from) in versions {
                guard let package = installedPackage(ref), let to = package.installedVersions.last, to != from else { continue }
                records.append(UpdateRecord(ref: ref, title: package.displayName, from: from, to: to, date: run.finishedAt ?? .now))
            }
        }
        guard !records.isEmpty else { return }
        history = Array((records.sorted { $0.name < $1.name } + history).prefix(UpdateHistory.limit))
        UpdateHistory.save(history)
    }

    /// Homebrew's names. A list that comes back nearly empty (brew prints
    /// little or nothing while its package data is being refreshed, as during
    /// an update in Terminal) is retried a few times rather than believed:
    /// Discover would filter everything out by it, and New in Homebrew would
    /// count the whole catalog as removed, then as new.
    func loadSearchIndex() async {
        guard let service else { return }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
            guard !Task.isCancelled else { return }
            if let index = try? await service.searchIndex(), isPlausible(index) {
                searchIndex = index
                noteNewPackages(in: index)
                return
            }
        }
    }

    /// Both kinds there, and neither under half of what Homebrew had before.
    private func isPlausible(_ index: SearchIndex) -> Bool {
        guard !index.formulae.isEmpty, !index.casks.isEmpty else { return false }
        let earlier = searchIndex.isEmpty ? KnownPackages.load().map { SearchIndex(formulae: $0.formulae, casks: $0.casks) } : searchIndex
        guard let earlier else { return true }
        return index.formulae.count * 2 >= earlier.formulae.count && index.casks.count * 2 >= earlier.casks.count
    }

    /// Compares Homebrew's names with the last look's, on every index load
    /// (at launch and after each `brew update`), for New in Homebrew.
    private func noteNewPackages(in index: SearchIndex) {
        let known = KnownPackages.updated(KnownPackages.load(), with: index)
        known.save()
        removedNames = Set(known.removed.map(\.ref))
        // A newly added tap's formulae aren't new to Homebrew.
        newPackages = known.added.filter { !$0.name.contains("/") }.sorted { $0.date != $1.date ? $0.date > $1.date : $0.name < $1.name }
    }

    /// New in Homebrew, less renames, once their info says so.
    var newRefs: [PackageRef] {
        newPackages.map(\.ref).filter { ref in
            guard let package = package(ref) else { return true }
            return !package.oldNames.contains { removedNames.contains(PackageRef(ref.kind, $0)) }
        }
    }

    func loadCleanup() async {
        guard let service else { return }
        cleanup = try? await service.cleanupPreview()
    }

    /// Runs `brew vulns`, which asks OSV.dev about every installed formula.
    func loadVulnerabilities() async {
        guard let service, checksVulnerabilities, vulnerabilityCheck != .checking else { return }
        vulnerabilitiesStale = false
        let previous = vulnerabilityCheck
        vulnerabilityCheck = .checking
        let result: VulnerabilityCheck
        do {
            result = .finished(try await service.vulnerabilities(), at: .now)
        } catch {
            // A failed recheck keeps the last report; there's nothing better to show.
            if case .finished = previous {
                vulnerabilityCheck = previous
                return
            }
            result = .failed(error.localizedDescription)
        }
        // Turned off meanwhile.
        guard checksVulnerabilities else { return }
        vulnerabilityCheck = result
    }

    var vulnerabilityReport: VulnerabilityReport? {
        if case let .finished(report, _) = vulnerabilityCheck { report } else { nil }
    }

    /// Vulnerable formulae with an update: what Fix updates.
    var fixableVulnerabilities: [VulnerableFormula] {
        vulnerabilityReport?.findings.filter { outdatedItem($0.ref) != nil } ?? []
    }

    /// What OSV.dev knows about an installed formula, if it knows anything.
    func vulnerabilities(of ref: PackageRef) -> VulnerableFormula? {
        guard ref.kind == .formula else { return nil }
        return vulnerabilityReport?.findings.first { $0.ref == ref }
    }

    /// Whether the available update fixes every known vulnerability: true or
    /// false when OSV.dev's fixes say so, nil when they can't be compared or
    /// there's no update.
    func updateFixes(_ finding: VulnerableFormula) -> Bool? {
        guard let item = outdatedItem(finding.ref) else { return nil }
        return finding.isFixed(by: PackageKind.formula.upstreamVersion(item.currentVersion))
    }

    /// Formulae that declare a service, from Homebrew's formula list, kept a week.
    func loadServiceFormulae() async {
        let data = try? await DownloadCache.data("ServiceFormulae.json", maxAge: 7 * 24 * 3600) {
            try JSONEncoder().encode(try await ServiceIndex.fetch())
        }
        serviceFormulae = data.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    /// Homebrew's executables database, kept a day.
    func loadCommandIndex() async {
        let data = try? await DownloadCache.data("executables.txt", maxAge: 24 * 3600) {
            Data(try await CommandIndex.fetch().utf8)
        }
        if let data { commandIndex = CommandIndex(text: String(decoding: data, as: UTF8.self)) }
    }

    /// Finds apps in Applications that a cask installs but Homebrew doesn't
    /// manage. Mac App Store apps are left out: their updates come from there.
    func scanAdoptableApps() async {
        guard let service, adoption != .scanning else { return }
        adoption = .scanning
        do {
            let data = try await DownloadCache.data("cask.json", maxAge: 24 * 3600) {
                try await DownloadCache.download(AdoptionIndex.url)
            }
            let index = try AdoptionIndex.casksByApp(from: data)
            let managed = Set(installed.compactMap(\.appPath))
            let fileManager = FileManager.default
            var paths: [String: String] = [:]
            for folder in ["/Applications", fileManager.homeDirectoryForCurrentUser.appending(path: "Applications").path] {
                for name in (try? fileManager.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".app") {
                    let path = "\(folder)/\(name)"
                    guard !managed.contains(path), paths[name] == nil,
                          !fileManager.fileExists(atPath: "\(path)/Contents/_MASReceipt") else { continue }
                    paths[name] = path
                }
            }
            let installedCasks = Set(installed.filter { $0.kind == .cask }.map(\.name))
            let matches = AdoptionIndex.matches(apps: paths.keys.sorted(), in: index)
                .filter { !installedCasks.contains($0.token) }
            let packages = try await service.info(.cask, matches.map(\.token))
            let apps: [AdoptableApp] = matches.compactMap { match in
                guard let package = packages.first(where: { $0.name == match.token }), let path = paths[match.app] else { return nil }
                let info = Bundle(path: path)?.infoDictionary
                return AdoptableApp(package: package, appVersion: info?["CFBundleShortVersionString"] as? String)
            }
            adoption = .finished(apps.sorted {
                $0.package.title.localizedStandardCompare($1.package.title) == .orderedAscending
            })
        } catch {
            adoption = .failed(error.localizedDescription)
        }
    }

    // MARK: Open apps

    /// Follows apps launching and quitting, for as long as the window is open.
    func watchRunningApps() async {
        let workspace = NSWorkspace.shared
        runningApps = Self.currentlyRunningApps()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await note in workspace.notificationCenter.notifications(named: NSWorkspace.didLaunchApplicationNotification) {
                    if let path = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path {
                        self.runningApps.insert(path)
                    }
                }
            }
            group.addTask { @MainActor in
                for await note in workspace.notificationCenter.notifications(named: NSWorkspace.didTerminateApplicationNotification) {
                    if let path = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path {
                        self.runningApps.remove(path)
                        self.updateQuitApps()
                    }
                }
            }
        }
    }

    /// An installed app that's open now, whose cask doesn't quit it before
    /// upgrading: brew would replace it while it runs.
    func isOpenDuringUpdate(_ ref: PackageRef) -> Bool {
        if ref == selfRef { return true }
        guard let package = installedPackage(ref), package.kind == .cask, !package.quitsApp,
              let path = package.appPath else { return false }
        return runningApps.contains(path)
    }

    func updatesOnQuit(_ ref: PackageRef) -> Bool {
        updatesOnQuit.contains(ref)
    }

    /// Updates `ref` as soon as its app quits, or now if it isn't open.
    func updateOnQuit(_ ref: PackageRef, _ enabled: Bool = true) {
        if enabled { updatesOnQuit.insert(ref) } else { updatesOnQuit.remove(ref) }
        updateQuitApps()
    }

    /// Queues the update of each app waiting to quit that has; drops those
    /// with no update left (updated elsewhere, or uninstalled).
    private func updateQuitApps() {
        // A failed load has no updates to go by; don't drop anything over it.
        guard lastRefreshed != nil, loadError == nil else { return }
        for ref in updatesOnQuit {
            guard availableUpdate(ref) != nil else {
                updatesOnQuit.remove(ref)
                continue
            }
            if !isOpenDuringUpdate(ref) {
                updatesOnQuit.remove(ref)
                enqueue(.upgrade(ref))
            }
        }
    }

    private static func currentlyRunningApps() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
    }

    private static func loadUpdatesOnQuit() -> Set<PackageRef> {
        let saved = UserDefaults.standard.stringArray(forKey: "UpdateOnQuit") ?? []
        return Set(saved.compactMap(PackageRef.init(savedString:)))
    }

    // MARK: Updating Caskroom

    /// The installed cask whose app is this one.
    private static func ownCask(in installed: [Package]) -> PackageRef? {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return installed.first { package in
            package.kind == .cask && package.appPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == bundle
        }?.ref
    }

    /// Whether `operation` would have brew replace Caskroom's own bundle.
    private func replacesSelf(_ operation: BrewOperation) -> Bool {
        guard let ref = selfRef else { return false }
        return operation == .upgrade(ref) || operation == .reinstall(ref)
    }

    private static let selfUpgradeDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appending(path: "club.iscout.caskroom")
    }()

    /// As Caskroom quits: hands an update of itself, from Update and Relaunch
    /// or Update When I Quit, to a helper that runs once it's gone. Only Update
    /// and Relaunch opens it again.
    func handOffSelfUpgrade() {
        var operation = selfUpgrade
        let relaunch = operation != nil
        if operation == nil, let ref = selfRef, updatesOnQuit.contains(ref), availableUpdate(ref) != nil {
            operation = .upgrade(ref)
        }
        guard let operation, let ref = operation.ref, let service,
              let package = installedPackage(ref), let path = package.appPath else { return }
        UserDefaults.standard.set([
            "operation": operation == .reinstall(ref) ? "reinstall" : "upgrade",
            "ref": ref.savedString,
            "from": package.installedVersions.last ?? "",
        ], forKey: "SelfUpgrade")
        do {
            try SelfUpgrade(runner: service.runner, directory: Self.selfUpgradeDirectory)
                .start(operation.steps[0], waitingFor: getpid(), relaunch: relaunch ? path : nil)
        } catch {
            UserDefaults.standard.removeObject(forKey: "SelfUpgrade")
            NSLog("Couldn't start updating Caskroom: \(error)")
        }
    }

    /// At launch, how an update handed off at the last quit went, as a finished
    /// run in Activity (opened if it failed) and in the update history.
    private func pickUpSelfUpgrade() {
        guard let saved = UserDefaults.standard.dictionary(forKey: "SelfUpgrade") as? [String: String] else { return }
        UserDefaults.standard.removeObject(forKey: "SelfUpgrade")
        guard let service, let ref = saved["ref"].flatMap(PackageRef.init(savedString:)) else { return }
        let operation: BrewOperation = saved["operation"] == "reinstall" ? .reinstall(ref) : .upgrade(ref)
        let outcome = SelfUpgrade(runner: service.runner, directory: Self.selfUpgradeDirectory).pickUp()
        let run = OperationRun(operation)
        for line in outcome?.log ?? [] { run.append(LogLine(.stdout, line)) }
        run.finishedAt = outcome?.finishedAt ?? .now
        switch outcome?.exitStatus {
        case 0:
            run.state = .succeeded
        case let status?:
            let error = BrewError.commandFailed(command: operation.command, exitCode: status, stderr: "")
            run.state = .failed(failureMessage(error, run))
        case nil:
            run.state = .failed(outcome == nil
                ? "Caskroom quit to update, but Homebrew didn't run."
                : "Homebrew stopped before it finished updating Caskroom.")
        }
        operations.append(run)
        if case .failed = run.state { showActivity = true }
        if let from = saved["from"], !from.isEmpty { unconfirmedUpdates.append((run, [ref: from])) }
    }

    // MARK: Reverting

    /// The update Updated Recently can undo for `ref`: a formula's latest,
    /// while that version is still the one installed and the old one isn't
    /// installed beside it already.
    func revertibleUpdate(_ ref: PackageRef) -> UpdateRecord? {
        guard ref.kind == .formula, let record = recentUpdates.first(where: { $0.ref == ref }),
              let package = installedPackage(ref), package.installedVersions.last == record.to else { return nil }
        let version = ref.kind.upstreamVersion(record.from)
        guard installedPackage(PackageRef(.formula, "\(ref.name)@\(version)")) == nil else { return nil }
        return record
    }

    /// Asks before reverting (RootView shows the dialog), once it knows
    /// whether homebrew/core has to be fetched first.
    func requestRevert(_ record: UpdateRecord) async {
        guard service != nil else { return }
        await checkCoreTap()
        revertRequest = RevertRequest(record, needsCoreTap: needsCoreTap)
    }

    /// Asks `brew tap` whether homebrew/core is there.
    private func checkCoreTap() async {
        guard let service else { return }
        coreTapped = (try? await service.taps())?.contains("homebrew/core")
    }

    /// Whether a revert fetches homebrew/core first: unless it's known to be
    /// tapped, since tapping it again changes nothing.
    var needsCoreTap: Bool { coreTapped != true }

    // MARK: Discover

    /// Discover's charts, from Homebrew's public analytics (kept half a day).
    /// A cask without an app bundle (Codex, Azure CLI) is a command-line tool,
    /// so the top casks are looked up with `brew info` to sort them into apps
    /// and tools; tools are ranked with formulae by installs.
    func loadDiscover() async {
        guard let service, !isLoadingDiscover else { return }
        isLoadingDiscover = true
        defer { isLoadingDiscover = false }
        do {
            async let casks = ranking(.cask, days: 30)
            async let formulae = ranking(.formula, days: 30)
            async let earlierCasks = ranking(.cask, days: 90)
            async let earlierFormulae = ranking(.formula, days: 90)
            let (casksNow, formulaeNow) = try await (casks, formulae)
            let (casksBefore, formulaeBefore) = try await (earlierCasks, earlierFormulae)

            let topCasks = Array(casksNow.prefix(Self.chartLength * 2))
            let topFormulae = Array(formulaeNow.prefix(Self.chartLength))
            try await fetchCatalog(.cask, topCasks.map(\.ref.name), service)
            try await fetchCatalog(.formula, topFormulae.prefix(Self.shelfLength).map(\.ref.name), service)

            var catalog = DiscoverCatalog()
            let hasApp = { (entry: HomebrewAnalytics.Entry) in self.package(entry.ref)?.appPath != nil }
            catalog.topApps = topCasks.filter(hasApp).prefix(Self.chartLength).map(\.ref)
            catalog.topTools = (topFormulae + topCasks.filter { !hasApp($0) && self.package($0.ref) != nil })
                .sorted { $0.installs > $1.installs }
                .prefix(Self.chartLength)
                .map(\.ref)
            catalog.trending = (HomebrewAnalytics.climbing(now: casksNow, earlier: casksBefore)
                + HomebrewAnalytics.climbing(now: formulaeNow, earlier: formulaeBefore))
                .sorted { Double($0.earlierRank) / Double($0.rank) > Double($1.earlierRank) / Double($1.rank) }
                .prefix(Self.chartLength)
                .map { $0 }
            catalog.monthly = Dictionary((casksNow + formulaeNow).map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
            guard !catalog.isEmpty else {
                // Nothing to show is a failure too, not a reason to spin forever.
                discoverError = "Homebrew didn't describe any of the most installed packages."
                return
            }
            discover = catalog
            discoverError = nil
        } catch {
            discoverError = error.localizedDescription
        }
    }

    /// Shown on a shelf, and on a chart's page.
    static let shelfLength = 12
    static let chartLength = 100

    /// One analytics ranking, without packages Homebrew no longer has.
    private func ranking(_ kind: PackageKind, days: Int) async throws -> [HomebrewAnalytics.Entry] {
        let data = try await DownloadCache.data("analytics-\(kind.rawValue)-\(days)d.json", maxAge: 12 * 3600) {
            try await DownloadCache.download(HomebrewAnalytics.url(for: kind, days: days))
        }
        let ranking = try HomebrewAnalytics.ranking(from: data, kind: kind)
        let index = searchIndex
        return index.isEmpty ? ranking : ranking.filter { index.contains($0.ref) }
    }

    /// `brew info` for packages a Discover list shows, into `catalog`, in
    /// batches: one brew call for many names.
    private func fetchCatalog(_ kind: PackageKind, _ names: [String], _ service: BrewService) async throws {
        let missing = names.filter { package(PackageRef(kind, $0)) == nil }
        for start in stride(from: 0, to: missing.count, by: 100) {
            let batch = Array(missing[start..<min(start + 100, missing.count)])
            requestedInfo.formUnion(batch.map { PackageRef(kind, $0) })
            for package in try await service.info(kind, batch) {
                catalog[package.ref] = package
            }
        }
    }

    /// Asks for a package's info for a list row; rows that appear together
    /// share one `brew info` call. Each package is asked about once, even if it fails.
    func requestInfo(_ ref: PackageRef) {
        guard let service, package(ref) == nil, requestedInfo.insert(ref).inserted else { return }
        wantedInfo.insert(ref)
        guard infoBatch == nil else { return }
        infoBatch = Task {
            while !wantedInfo.isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
                let batch = wantedInfo
                wantedInfo = []
                for kind in PackageKind.allCases {
                    let names = batch.filter { $0.kind == kind }.map(\.name).sorted()
                    try? await fetchCatalog(kind, names, service)
                }
            }
            infoBatch = nil
        }
    }

    /// Catalog info from before an install or uninstall says the wrong thing
    /// about it; rows ask again.
    private func dropStaleCatalog() {
        let installedRefs = Set(installed.map(\.ref))
        let stale = catalog.filter { $0.value.isInstalled != installedRefs.contains($0.key) }.map(\.key)
        for ref in stale { catalog[ref] = nil }
        requestedInfo.subtract(stale)
    }

    /// A Discover list's packages, in its order.
    func refs(_ list: DiscoverList) -> [PackageRef] {
        switch list {
        case .topApps: discover.topApps
        case .topTools: discover.topTools
        case .trending: discover.trending.map(\.ref)
        case .new: newRefs
        case let .collection(collection): refs(collection)
        }
    }

    /// A collection's packages, most installed this month first.
    func refs(_ collection: PackageCollection) -> [PackageRef] {
        let refs: [PackageRef] = switch collection {
        case .fonts: searchIndex.casks.filter { $0.hasPrefix("font-") }.map { PackageRef(.cask, $0) }
        case .services: serviceFormulae.map { PackageRef(.formula, $0) }
        default: collection.curated
        }
        let index = searchIndex
        return refs
            .filter { index.isEmpty || index.contains($0) }
            .sorted { a, b in
                let (x, y) = (discover.monthly[a]?.installs ?? 0, discover.monthly[b]?.installs ?? 0)
                return x != y ? x > y : a.name < b.name
            }
    }

    // MARK: Package page facts

    /// Installs this month from the analytics Discover already has, else the
    /// package's own API page; its size if installed; and, before an install,
    /// everything it would bring along.
    func loadFacts(_ package: Package) async {
        guard let service else { return }
        let ref = package.ref
        if facts[ref]?.monthlyInstalls == nil {
            if let entry = discover.monthly[ref] {
                facts[ref, default: PackageFacts()].monthlyInstalls = .some(entry.installs)
            } else if package.tap == "homebrew/core" || package.tap == "homebrew/cask" {
                let installs = try? await HomebrewAnalytics.monthlyInstalls(of: ref)
                facts[ref, default: PackageFacts()].monthlyInstalls = .some(installs ?? nil)
            } else {
                facts[ref, default: PackageFacts()].monthlyInstalls = .some(nil)
            }
        }
        if let version = package.installedVersions.last, facts[ref]?.size?.version != version {
            let size = try? await service.size(of: ref)
            facts[ref, default: PackageFacts()].size = (version, size ?? nil)
        }
        // The Terminal section's revert line fetches homebrew/core first unless it's tapped.
        if revertibleUpdate(ref) != nil { await checkCoreTap() }
        if !package.isInstalled, facts[ref]?.allDependencies == nil, !package.dependencies.isEmpty {
            if let names = try? await service.allDependencies(of: ref) {
                facts[ref, default: PackageFacts()].allDependencies = names
            }
        }
    }

    /// Where Homebrew links commands: /opt/homebrew.
    var prefix: String { service?.runner.prefix ?? "/opt/homebrew" }

    /// The same software at other versions: brew's own list for a formula
    /// (which leaves out the unversioned one), Homebrew's names for a cask
    /// (`blender@lts` beside `blender`).
    func otherVersions(of package: Package) -> [PackageRef] {
        let kind = package.kind
        let base = String(package.name.split(separator: "@").first ?? Substring(package.name))
        var refs = package.otherVersions
        let names = kind == .formula ? [base] : searchIndex.casks.filter { $0 == base || $0.hasPrefix(base + "@") }
        for name in names where name != package.name {
            let ref = PackageRef(kind, name)
            if !refs.contains(ref), searchIndex.contains(ref) { refs.insert(ref, at: refs.startIndex) }
        }
        return refs
    }

    /// Whether anything installed goes by `name`, formula or cask.
    func isInstalled(named name: String) -> Bool {
        installed.contains { $0.name == name }
    }

    /// Runs `brew doctor` for its sheet. Not queued: it changes nothing, so it
    /// doesn't wait for Homebrew's lock.
    func runDoctor() async {
        guard let service else { return }
        doctor = .checking
        let result: DoctorState
        do {
            result = .finished(try await service.doctor())
        } catch {
            result = .failed(error.localizedDescription)
        }
        // Closing the sheet cancels the check; don't reopen it with the result.
        guard !Task.isCancelled else { return }
        doctor = result
    }

    // MARK: Lookups

    func installedPackage(_ ref: PackageRef) -> Package? {
        installed.first { $0.ref == ref }
    }

    /// The best known copy of a package: installed, else fetched info, else
    /// Discover's, else found on the Adopt page.
    func package(_ ref: PackageRef) -> Package? {
        installedPackage(ref) ?? infoCache[ref] ?? catalog[ref]
            ?? adoptableApps.first { $0.package.ref == ref }?.package
    }

    /// The Adopt page's apps, less any adopted since the scan.
    var adoptableApps: [AdoptableApp] {
        guard case let .finished(apps) = adoption else { return [] }
        return apps.filter { installedPackage($0.id) == nil }
    }

    func operation(for ref: PackageRef) -> OperationRun? {
        operations.first { run in
            guard !run.state.isFinished else { return false }
            switch run.operation {
            case let .upgradeAll(_, casks): return ref.kind == .formula || (casks?.contains(ref.name) ?? true)
            case .upgradeVulnerable: return vulnerabilities(of: ref) != nil
            default: return run.operation.ref == ref
            }
        }
    }

    func outdatedItem(_ ref: PackageRef) -> OutdatedItem? {
        outdated.first { $0.ref == ref }
    }

    /// Updated Recently: the last month's updates, newest first, one per package.
    var recentUpdates: [UpdateRecord] {
        let since = Date.now.addingTimeInterval(-30 * 24 * 3600)
        var seen: Set<PackageRef> = []
        return history.filter { $0.date > since && seen.insert($0.ref).inserted }
    }

    /// Installed packages Homebrew has deprecated or disabled.
    var needingAttention: [Package] {
        installed.filter(LibraryFilter.attention.includes)
    }

    /// Installed packages that depend on `ref`, which Homebrew won't uninstall
    /// while they're there. Casks count too: they can depend on formulae.
    func dependents(of ref: PackageRef) -> [PackageRef] {
        installed.filter { $0.dependencies.contains(ref) }.map(\.ref).sorted { $0.name < $1.name }
    }

    /// A cask that isn't installed but whose app is already where it would go:
    /// installed by hand, so brew would refuse to install over it. Adopting it
    /// hands it to Homebrew instead.
    func isAdoptable(_ ref: PackageRef) -> Bool {
        guard ref.kind == .cask, installedPackage(ref) == nil,
              let path = package(ref)?.appPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// The update to offer for `ref`: none while it's pinned.
    func availableUpdate(_ ref: PackageRef) -> OutdatedItem? {
        outdatedItem(ref).flatMap { $0.pinned ? nil : $0 }
    }

    /// What a package's actions run, as brew commands, for its page's Terminal section.
    func commands(for package: Package) -> [BrewOperation] {
        let ref = package.ref
        guard package.isInstalled else { return [isAdoptable(ref) ? .adopt(ref) : .install(ref)] }
        var commands: [BrewOperation] = []
        if availableUpdate(ref) != nil { commands.append(.upgrade(ref)) }
        if let record = revertibleUpdate(ref) {
            commands.append(RevertRequest(record, needsCoreTap: needsCoreTap).operation)
        }
        commands.append(.reinstall(ref))
        commands.append(package.pinned ? .unpin(ref) : .pin(ref))
        commands.append(.uninstall(ref))
        if package.hasZap { commands.append(.zap(ref)) }
        if let entry = serviceEntry(ref) { commands += serviceCommands(entry) }
        return commands
    }

    func serviceEntry(_ ref: PackageRef) -> ServiceEntry? {
        ref.kind == .formula ? services.first { $0.name == ref.name } : nil
    }

    /// Run or stop now; for a running service that starts at login, restart;
    /// then start at login or stop doing so.
    func serviceCommands(_ entry: ServiceEntry) -> [BrewOperation] {
        var commands = [runCommand(entry)]
        if entry.status.isRunning && entry.registered { commands.append(.service(.restart, name: entry.name)) }
        commands.append(loginCommand(entry))
        return commands
    }

    /// Starts or stops a service now. Stopping one that starts at login keeps it
    /// registered (`kill`; `stop` would unregister it too), and starting one runs
    /// it as registered (`start`; `run` would load a second copy of its plist).
    func runCommand(_ entry: ServiceEntry) -> BrewOperation {
        let action: ServiceAction = switch (entry.status.isRunning, entry.registered) {
        case (true, true): .kill
        case (true, false): .stop
        case (false, true): .start
        case (false, false): .run
        }
        return .service(action, name: entry.name)
    }

    /// Turns start-at-login on or off. brew has no command for only that:
    /// `start` also starts it now, `stop` also stops it.
    func loginCommand(_ entry: ServiceEntry) -> BrewOperation {
        .service(entry.registered ? .stop : .start, name: entry.name)
    }

    func loadInfo(_ ref: PackageRef) async {
        guard let service, package(ref) == nil else { return }
        do {
            if let package = try await service.info(ref) {
                infoCache[ref] = package
            } else {
                infoErrors[ref] = "No information for \(ref.name)."
            }
        } catch {
            infoErrors[ref] = error.localizedDescription
        }
    }

    // MARK: Operations

    var runningOperation: OperationRun? {
        operations.first { $0.state == .running }
    }

    var hasPendingOperations: Bool {
        operations.contains { !$0.state.isFinished }
    }

    /// True while `operation` is queued or running, so its button can't queue it twice.
    func isPending(_ operation: BrewOperation) -> Bool {
        operations.contains { $0.operation == operation && !$0.state.isFinished }
    }

    /// The just-finished operation on `ref` itself (not Update All), while it settles.
    func settlingRun(for ref: PackageRef) -> OperationRun? {
        settling.flatMap { $0.operation.ref == ref ? $0 : nil }
    }

    /// True while any queued or running operation touches `ref`.
    func isBusy(_ ref: PackageRef) -> Bool {
        operation(for: ref) != nil
    }

    func enqueue(_ operation: BrewOperation, automatic: Bool = false) {
        // brew would replace the running app: quit, and let the helper do it.
        if replacesSelf(operation) {
            selfUpgrade = operation
            NSApp.terminate(nil)
            return
        }
        guard !isPending(operation) else { return }
        operations.append(OperationRun(operation, automatic: automatic))
        if !automatic { Notifier.requestAuthorization() }
        pump()
    }

    func cancel(_ run: OperationRun) {
        switch run.state {
        case .queued:
            run.state = .cancelled
            run.finishedAt = .now
        case .running:
            currentTask?.cancel()
        default:
            break
        }
    }

    func clearFinished() {
        operations.removeAll { $0.state.isFinished }
    }

    /// Drops the queue and stops the running command, waiting up to five seconds
    /// for brew to exit. For quitting.
    func stopAll() async {
        for run in operations where run.state == .queued {
            cancel(run)
        }
        guard let run = runningOperation else { return }
        cancel(run)
        for _ in 0..<100 where !run.state.isFinished {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Homebrew holds a global lock during changes, so operations run one at a time.
    private func pump() {
        guard currentTask == nil, let service,
              let next = operations.first(where: { $0.state == .queued }) else { return }
        next.state = .running
        expectUpdates(from: next)
        currentTask = Task {
            await execute(next, with: service)
            currentTask = nil
            // The log opens by itself only when something you did needs reading.
            if case .failed = next.state, !next.automatic { showActivity = true }
            if !next.automatic { Notifier.finished(next) }
            settling = next
            if next.operation.changesFormulae { vulnerabilitiesStale = true }
            if next.operation == .update {
                if next.state == .succeeded {
                    lastUpdateCheck = .now
                    if next.automatic { announceAfter = next.finishedAt }
                }
                await loadSearchIndex()
            }
            await refresh()
            pump()
            // Off the queue: the next operation needn't wait for these.
            if !hasPendingOperations {
                Task { await loadCleanup() }
                if vulnerabilitiesStale && checksVulnerabilities { Task { await loadVulnerabilities() } }
            }
        }
    }

    /// Notes the installed versions an update or reinstall may change, before it
    /// starts (a refresh mid-run could already show some new ones).
    private func expectUpdates(from run: OperationRun) {
        let refs: [PackageRef] = switch run.operation {
        case let .upgrade(ref), let .reinstall(ref): [ref]
        case let .upgradeAll(_, casks):
            outdated.filter { !$0.pinned && ($0.ref.kind == .formula || casks?.contains($0.ref.name) ?? true) }.map(\.ref)
        case .upgradeVulnerable: outdated.filter { !$0.pinned && vulnerabilities(of: $0.ref) != nil }.map(\.ref)
        default: []
        }
        let versions = refs.reduce(into: [PackageRef: String]()) { versions, ref in
            versions[ref] = installedPackage(ref)?.installedVersions.last
        }
        if !versions.isEmpty { unconfirmedUpdates.append((run, versions)) }
    }

    private func execute(_ run: OperationRun, with service: BrewService) async {
        do {
            for try await line in service.perform(run.operation) {
                run.append(line)
            }
            run.state = Task.isCancelled ? .cancelled : .succeeded
        } catch {
            run.state = Task.isCancelled ? .cancelled : .failed(failureMessage(error, run))
        }
        run.finishedAt = .now
    }

    private func failureMessage(_ error: Error, _ run: OperationRun) -> String {
        // The Touch ID sheet was cancelled (sudo has no terminal to fall back to a
        // password), or there's no askpass helper (a `swift build` tree without it).
        if run.log.contains(where: { $0.text.contains("a terminal is required") }) {
            return "This needs administrator approval, and none was given. You can also run `\(run.operation.command)` in Terminal."
        }
        // An install found the app already there, put in place outside Homebrew.
        if run.log.contains(where: { $0.text.contains("It seems there is already an App at") }) {
            return "The app is already in your Applications folder, installed outside Homebrew. Open its page and choose Adopt to let Homebrew manage it."
        }
        if run.blockedByAppManagement {
            let name = run.operation.ref.flatMap { package($0)?.title ?? $0.name } ?? "the app"
            let unchanged = if case .adopt = run.operation { " The app is as it was." } else { "" }
            return "macOS didn't let Homebrew change \(name). Allow Caskroom under System Settings ▸ Privacy & Security ▸ App Management, then try again.\(unchanged)"
        }
        // Adopting needs the app in place to be the cask's own version.
        if run.log.contains(where: { $0.text.contains("is different from the one being installed") }) {
            return "The app in your Applications folder isn't the version Homebrew has, so it can't be adopted. Update the app first, or move it to the Trash and install it with Homebrew."
        }
        // The password prompt was cancelled, or the password was wrong three times.
        if run.log.contains(where: { $0.text.contains("sudo") && $0.text.contains("password") }) {
            return "This needs an administrator password, and none was given."
        }
        // `upgrade --vulnerable` stops when OSV.dev couldn't vouch for every candidate.
        if run.log.contains(where: { $0.text.contains("Incomplete vulnerability scan") }) {
            return "Some formulae couldn't be checked for vulnerabilities, so Homebrew didn't update any. Update them one by one from Security instead."
        }
        // Extracting an old version needs it in homebrew/core's history.
        if run.log.contains(where: { $0.text.contains("The formula or version may not have existed") }) {
            return "Homebrew couldn't find that version in its history. Your current version is still the one in use."
        }
        if case let BrewError.commandFailed(_, exitCode, _) = error {
            return "brew exited with status \(exitCode)."
        }
        return error.localizedDescription
    }
}

private func capture<T>(_ body: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

extension BrewOperation {
    /// Whether it can change which formulae, or versions, are installed, so
    /// a vulnerability check is out of date after it.
    var changesFormulae: Bool {
        switch self {
        case .install, .uninstall, .upgrade, .upgradeAll, .upgradeVulnerable, .reinstall, .revert: true
        default: false
        }
    }
}

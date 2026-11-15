import AppKit
import BrewKit

/// Uninstalling an app with everything it left outside its bundle, AppCleaner
/// style: the sheet lists what `LeftoverFinder` found, and the ticked ones go
/// to the Trash with the app. For an app a cask manages, brew uninstalls it
/// first (with `--zap` when the cask has one) and the rest follows.
@Observable @MainActor
final class AppRemoval: Identifiable {
    enum State: Equatable {
        case scanning
        case ready
        /// Removing it can't be done here, and why.
        case refused(String)
        case removing
        case finished(RemovalOutcome)
    }

    nonisolated var id: String { app.path }
    let app: AppIdentity
    /// The installed cask that manages it: brew removes the app and what its
    /// zap lists, and Caskroom the rest.
    let cask: PackageRef?
    var state: State = .scanning
    var leftovers: [Leftover] = []
    /// Installer packages whose receipts macOS forgets once the app is gone.
    var receipts: [String] = []
    var selected: Set<String> = []
    /// Another copy of the same app (same bundle ID), whose files these are too.
    var otherCopy: String?
    /// Bytes on disk, as they're measured; missing for what isn't measured
    /// (other apps' containers, which macOS asks permission to look in).
    var sizes: [String: Int64] = [:]

    init(app: AppIdentity, cask: PackageRef?) {
        self.app = app
        self.cask = cask
    }

    var selectedLeftovers: [Leftover] {
        leftovers.filter { selected.contains($0.path) }
    }

    /// The app and what's ticked, as far as measured.
    var selectedSize: Int64 {
        ([app.path] + selected).reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    var needsAdministrator: Bool {
        (cask == nil && LeftoverFinder.needsAdministrator(app.path)) || selectedLeftovers.contains(where: \.needsAdministrator)
    }
}

extension BrewStore {
    private var applicationFolders: [URL] {
        [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")]
    }

    /// Apps in Applications that Homebrew doesn't manage, for the Uninstall Apps
    /// page: not Apple's, nor Caskroom itself.
    func scanOtherApps() async {
        guard !scanningOtherApps else { return }
        scanningOtherApps = true
        defer { scanningOtherApps = false }
        let managed = Set(installed.compactMap(\.appPath))
        let own = Bundle.main.bundleURL.standardizedFileURL.path
        let folders = applicationFolders
        let apps = await Task.detached {
            AppIdentity.apps(in: folders)
                .compactMap { AppIdentity.read(at: $0, readsNestedBundles: false) }
                .filter { !$0.isApple && !managed.contains($0.path) && $0.path != own && $0.bundleID != Bundle.main.bundleIdentifier }
        }.value
        otherApps = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The installed cask whose app is at `path`.
    func cask(managing path: String) -> Package? {
        installed.first { $0.kind == .cask && $0.appPath == path }
    }

    /// Opens the uninstall sheet for the app at `url` and starts looking for its files.
    func uninstallApp(at url: URL) {
        let path = url.standardizedFileURL.path
        guard appRemoval == nil else { return }
        let cask = cask(managing: path)
        let quick = AppIdentity.read(at: url, readsNestedBundles: false)
            ?? AppIdentity(path: path, name: url.deletingPathExtension().lastPathComponent, bundleID: nil)
        let removal = AppRemoval(app: quick, cask: cask?.ref)
        appRemoval = removal
        if path == Bundle.main.bundleURL.standardizedFileURL.path || (cask != nil && cask?.ref == selfRef) {
            removal.state = .refused("Caskroom can't uninstall itself while it's open. Quit it and move it to the Trash in Finder, or run brew uninstall --zap --cask caskroom in Terminal.")
            return
        }
        if quick.isApple {
            removal.state = .refused("\(quick.name) is part of macOS.")
            return
        }
        Task { await findLeftovers(for: removal, zapPaths: cask?.zapPaths) }
    }

    /// Opens the uninstall sheet for an installed cask's app.
    func uninstallApp(cask ref: PackageRef) {
        guard let path = installedPackage(ref)?.appPath else { return }
        uninstallApp(at: URL(fileURLWithPath: path))
    }

    private func findLeftovers(for removal: AppRemoval, zapPaths knownZap: [String]?) async {
        let url = URL(fileURLWithPath: removal.app.path)
        let folders = applicationFolders
        let path = removal.app.path
        // Everything else installed, so their files stay.
        let (identity, others, otherCopy) = await Task.detached {
            let identity = AppIdentity.read(at: url)
            let others = AppIdentity.apps(in: folders)
                .filter { $0.standardizedFileURL.path != path }
                .compactMap { AppIdentity.read(at: $0, readsNestedBundles: false) }
                .compactMap { app in
                    app.bundleID.map { InstalledApp(bundleID: $0, teamID: AppIdentity.teamIdentifier(of: URL(fileURLWithPath: app.path)), name: app.name) }
                }
            let otherCopy = AppIdentity.apps(in: folders)
                .filter { $0.standardizedFileURL.path != path }
                .first { identity?.bundleID != nil && AppIdentity.read(at: $0, readsNestedBundles: false)?.bundleID == identity?.bundleID }?
                .path
            return (identity, others, otherCopy)
        }.value
        removal.otherCopy = otherCopy
        guard let identity else {
            removal.state = .refused("\(removal.app.name) isn't an app Caskroom can read.")
            return
        }
        let zapPaths = if let knownZap { knownZap } else { await zapPaths(forHandInstalled: identity) }
        let receipts = await InstallerReceipts.packages(for: identity)
        var receiptFiles: [String] = []
        for receipt in receipts { receiptFiles += await InstallerReceipts.files(of: receipt) }
        let leftovers = await Task.detached {
            LeftoverFinder(otherApps: others).find(for: identity, zapPaths: zapPaths, receiptFiles: receiptFiles)
        }.value
        removal.leftovers = leftovers
        removal.receipts = receipts
        removal.selected = Set(leftovers.filter(\.isCertain).map(\.path))
        removal.state = .ready
        // Sizes come in after the list: a large cache takes a moment to add up.
        let measured = await Task.detached {
            var sizes: [String: Int64] = [:]
            for path in [identity.path] + leftovers.map(\.path) where !Self.isPrivacyProtected(path) {
                if let size = Self.allocatedSize(of: path) { sizes[path] = size }
            }
            return sizes
        }.value
        removal.sizes = measured
    }

    /// A hand-installed app's cask zap list, when Homebrew has a cask for it.
    private func zapPaths(forHandInstalled app: AppIdentity) async -> [String] {
        guard let service else { return [] }
        if caskIndex == nil {
            let data = try? await DownloadCache.data("cask.json", maxAge: 24 * 3600) {
                try await DownloadCache.download(AdoptionIndex.url)
            }
            if let data { caskIndex = await Task.detached { try? AdoptionIndex.casksByApp(from: data) }.value }
        }
        let bundleName = URL(fileURLWithPath: app.path).lastPathComponent
        guard let token = caskIndex?[bundleName]?.first,
              let package = try? await service.info(.cask, [token]).first else { return [] }
        return package.zapPaths
    }

    /// The running apps whose bundle is the app's or inside it (a login item, a helper).
    func runningParts(of removal: AppRemoval) -> [NSRunningApplication] {
        let path = removal.app.path
        return NSWorkspace.shared.runningApplications.filter { app in
            guard let bundle = app.bundleURL?.standardizedFileURL.path else { return false }
            return bundle == path || bundle.hasPrefix(path + "/")
        }
    }

    func isRunning(_ removal: AppRemoval) -> Bool {
        let path = removal.app.path
        return runningApps.contains { $0 == path || $0.hasPrefix(path + "/") }
    }

    /// Moves the app and what's ticked to the Trash. A cask's app goes through
    /// brew; the rest follows once brew is done (`finishCaskRemoval`).
    func confirmRemoval(_ removal: AppRemoval) {
        if let ref = removal.cask {
            leftoverCleanups[ref] = removal
            enqueue(uninstallOperation(ref, zap: installedPackage(ref)?.hasZap == true))
            appRemoval = nil
            return
        }
        removal.state = .removing
        let app = Leftover(path: removal.app.path, evidence: .bundleID, needsAdministrator: LeftoverFinder.needsAdministrator(removal.app.path))
        let items = [app] + removal.selectedLeftovers
        let remover = AppRemover(runner: service?.runner)
        Task {
            let outcome = await remover.remove(items, forgetting: removal.receipts, onceGone: removal.app.path, appName: removal.app.name)
            removal.state = .finished(outcome)
            otherApps?.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
            if adoption != nil, outcome.moved.contains(removal.app.path) { await scanAdoptableApps() }
        }
    }

    /// After brew uninstalled a cask from the sheet: what brew left behind,
    /// logged with the operation's output.
    func finishCaskRemoval(_ run: OperationRun) async {
        guard let ref = run.operation.ref, let removal = leftoverCleanups.removeValue(forKey: ref),
              run.state == .succeeded else { return }
        let remaining = removal.selectedLeftovers.filter { FileManager.default.fileExists(atPath: $0.path) || isSymlinkPath($0.path) }
        guard !remaining.isEmpty || !removal.receipts.isEmpty else { return }
        run.append(LogLine(.stdout, "==> Moving \(remaining.count) of \(removal.app.name)'s leftover files to the Trash"))
        let outcome = await AppRemover(runner: service?.runner).remove(remaining, forgetting: removal.receipts, onceGone: removal.app.path, appName: removal.app.name)
        for path in outcome.moved { run.append(LogLine(.stdout, "Moved \(path)")) }
        for failure in outcome.failed { run.append(LogLine(.stderr, "Couldn't move \(failure.path): \(failure.reason)")) }
        for receipt in outcome.forgotten { run.append(LogLine(.stdout, "Forgot the installer receipt \(receipt)")) }
    }

    /// Other apps' containers: looking inside one makes macOS ask for permission.
    nonisolated static func isPrivacyProtected(_ path: String) -> Bool {
        path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/")
    }

    nonisolated static func allocatedSize(of path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if values.isSymbolicLink == true || values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return nil }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

private func isSymlinkPath(_ path: String) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
}

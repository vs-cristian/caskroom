import AppKit
import BrewKit
import SwiftUI

/// Screenshots of each page for design review, without Screen Recording
/// permission: the app draws its own window into a bitmap.
///
///     CASKROOM_SNAPSHOT_DIR=/tmp/shots CASKROOM_APPEARANCE=dark .build/debug/CaskroomApp
///
/// `CASKROOM_SNAPSHOT_SCREEN=1` captures the main window with `screencapture`
/// instead, which needs Screen Recording permission for whatever launched it.
/// `CASKROOM_SNAPSHOT_ONLY=<scene>,<scene>` captures only those scenes and
/// skips the popover and Doctor captures.
///
/// Walks the pages, writes one PNG each, then quits. Does nothing unless the
/// variable is set, and isn't compiled into release builds: `make screenshots`
/// and the commands above use the debug build.
@MainActor
enum SnapshotDriver {
    static func runIfRequested(store: BrewStore) async {
        #if DEBUG
        await run(store: store)
        #endif
    }

    #if DEBUG
    private static func run(store: BrewStore) async {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["CASKROOM_SNAPSHOT_DIR"] else { return }
        let output = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: env["CASKROOM_APPEARANCE"] == "dark" ? .darkAqua : .aqua)

        // Wait for the first load and the Discover shelves.
        for _ in 0..<60 where store.installed.isEmpty || store.isRefreshing || store.discover.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        if env["CASKROOM_SNAPSHOT_SCREEN"] == "1" {
            // An inactive window draws dimmed: grey controls and selection.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        // CASKROOM_SNAPSHOT_ONLY=1-discover,4-services captures just those scenes.
        let only = env["CASKROOM_SNAPSHOT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        // The first page as launched, before anything resizes or re-creates it.
        if only?.contains("0-launch") != false {
            try? await Task.sleep(for: .seconds(1))
            capture(window, to: output.appendingPathComponent("0-launch.png"))
        }
        window.setContentSize(NSSize(width: 1180, height: 760))

        // Nothing is outdated on a fresh machine; show what the page looks like with work to do.
        if store.outdated.isEmpty, env["CASKROOM_SNAPSHOT_FAKE_UPDATES"] != "0" {
            let samples = store.installed.filter(\.installedOnRequest).prefix(3)
            store.outdated = samples.map {
                OutdatedItem(ref: $0.ref, installedVersions: $0.installedVersions, currentVersion: ($0.installedVersions.last ?? "1.0") + ".1", pinned: false)
            }
        }
        // An open app that brew would replace while it runs, to show the Open tag.
        if env["CASKROOM_SNAPSHOT_FAKE_UPDATES"] != "0",
           let open = store.installed.first(where: { $0.kind == .cask && store.runningApps.contains($0.appPath ?? "") && !$0.quitsApp }),
           store.outdatedItem(open.ref) == nil {
            store.outdated.append(OutdatedItem(ref: open.ref, installedVersions: open.installedVersions,
                                               currentVersion: (open.installedVersions.last ?? "1.0") + ".1", pinned: false))
        }
        if store.cleanup?.isEmpty != false, env["CASKROOM_SNAPSHOT_FAKE_UPDATES"] != "0" {
            store.cleanup = CleanupSummary(reclaimable: "1.2GB", unneededFormulae: ["libyaml"])
        }
        // Set, not recorded, so none of this reaches the history file.
        if store.history.isEmpty, env["CASKROOM_SNAPSHOT_FAKE_UPDATES"] != "0" {
            store.history = store.installed.filter(\.installedOnRequest).suffix(2).enumerated().map { index, package in
                UpdateRecord(ref: package.ref, title: package.displayName, from: "0.9", to: package.installedVersions.last ?? "1.0",
                             date: .now.addingTimeInterval(-Double(index + 1) * 86400))
            }
        }
        let deprecated = PackageRef(.formula, "aftman")
        if store.needingAttention.isEmpty, env["CASKROOM_SNAPSHOT_FAKE_UPDATES"] != "0" {
            store.installed.append(Package(
                ref: deprecated, fullName: "aftman", desc: "Toolchain manager for Roblox", installedVersions: ["0.3.0"],
                deprecated: true,
                deprecation: Deprecation(reason: "repo_archived", replacement: PackageRef(.formula, "mise"), date: .now.addingTimeInterval(-90 * 86400)),
                disabling: Deprecation(reason: "repo_archived", replacement: PackageRef(.formula, "mise"), date: .now.addingTimeInterval(90 * 86400))
            ))
        }
        // One service running at login, one that failed.
        if store.services.count >= 2, !store.services.contains(where: \.status.isRunning), env["CASKROOM_SNAPSHOT_FAKE_UPDATES"] != "0" {
            let (a, b) = (store.services[0], store.services[1])
            store.services[0] = ServiceEntry(name: a.name, status: .started, user: NSUserName(), file: a.file, pid: 4321,
                                             registered: true, logPath: a.logPath, errorLogPath: a.errorLogPath)
            store.services[1] = ServiceEntry(name: b.name, status: .error, user: NSUserName(), file: b.file, exitCode: 78,
                                             registered: true, logPath: b.logPath, errorLogPath: b.errorLogPath)
        }

        let firstFormula = store.installed.first { $0.kind == .formula && $0.installedOnRequest && $0.caveats != nil }?.ref
        let firstApp = store.installed.first { $0.appPath != nil }?.ref
        let firstDependency = store.installed.first { !store.dependents(of: $0.ref).isEmpty }?.ref
        // A pushed page can take a few seconds before it draws into the capture.
        let scenes: [(name: String, wait: Double, apply: () -> Void)] = [
            ("1-discover", 2, { store.sidebar = .discover }),
            ("1b-top-apps", 4, { store.path = NavigationPath([DiscoverList.topApps]) }),
            ("1b2-top-tools", 4, { store.path = NavigationPath([DiscoverList.topTools]) }),
            ("1b3-trending", 6, { store.path = NavigationPath([DiscoverList.trending]) }),
            ("1b4-new", 6, { store.path = NavigationPath([DiscoverList.new]) }),
            ("1c-fonts", 6, { store.path = NavigationPath([DiscoverList.collection(.fonts)]) }),
            ("1c2-services-collection", 6, { store.path = NavigationPath([DiscoverList.collection(.services)]) }),
            ("1d-trending-app", 5, {
                store.path = NavigationPath(store.discover.trending.first { $0.ref.kind == .cask }.map { [$0.ref] } ?? [])
            }),
            // Not installed, with dependencies: what installing it brings along.
            ("1e-before-install", 6, { store.path = NavigationPath([PackageRef(.formula, "ffmpeg")]) }),
            ("2-library", 2, { store.sidebar = .library(.all) }),
            ("3-updates", 2, { store.sidebar = .updates }),
            ("4-services", 2, { store.sidebar = .services }),
            ("5-formula", 4, { store.sidebar = .library(.all); store.path = NavigationPath(firstFormula.map { [$0] } ?? []) }),
            ("5b-dependency", 4, { store.path = NavigationPath(firstDependency.map { [$0] } ?? []) }),
            ("6-apps", 2, { store.sidebar = .library(.apps) }),
            ("6b-dependencies", 2, { store.sidebar = .library(.dependencies) }),
            ("7-app", 4, { store.sidebar = .library(.apps); store.path = NavigationPath(firstApp.map { [$0] } ?? []) }),
            ("8-search", 2, { store.path = NavigationPath(); store.searchText = "wget" }),
            ("12-attention", 2, { store.path = NavigationPath(); store.searchText = ""; store.sidebar = .library(.attention) }),
            ("15-security-opt-in", 2, { store.sidebar = .security }),
            ("15b-security", 2, {
                // Not checked for real: that would send this Mac's formulae to OSV.dev.
                guard store.vulnerabilityCheck == nil else { return }
                let formulae = store.installed.filter { $0.kind == .formula && $0.installedOnRequest }
                let outdatedFormula = store.outdated.first { $0.ref.kind == .formula }?.ref
                let samples = ([outdatedFormula].compactMap { $0 } + formulae.map(\.ref).filter { $0 != outdatedFormula }).prefix(2)
                store.vulnerabilityCheck = .finished(VulnerabilityReport(findings: samples.enumerated().map { index, ref in
                    VulnerableFormula(name: ref.name, version: store.installedPackage(ref)?.installedVersions.last ?? "1.0", vulnerabilities: [
                        Vulnerability(id: "CVE-2026-1234\(index)", severity: index == 0 ? .high : .medium,
                                      summary: "Heap buffer overflow when parsing crafted input", fixedVersions: index == 0 ? ["0.1"] : []),
                    ])
                }, checked: formulae.count, unchecked: ["abseil"]), at: .now)
            }),
            ("15c-vulnerable-page", 4, { store.path = NavigationPath(store.vulnerabilityReport?.findings.first.map { [$0.ref] } ?? []) }),
            ("16-adopt", 10, { store.path = NavigationPath(); store.sidebar = .adopt }),
            ("17-command-search", 2, { store.searchText = "pg_dump" }),
            ("18-updates-tags", 3, { store.searchText = ""; store.sidebar = .updates }),
            ("13-deprecated", 4, { store.path = NavigationPath([store.needingAttention.first?.ref ?? deprecated]) }),
            ("14-service-page", 4, { store.path = NavigationPath(store.services.first.map { [$0.ref] } ?? []) }),
            ("9-activity", 2, { store.path = NavigationPath(); store.searchText = ""; store.sidebar = .library(.all); store.showActivity = true }),
            ("10-inserted-row", 2, {
                // A package appearing in a list that's already on screen, as after an install.
                store.showActivity = false
                if let sample = store.installed.first(where: { $0.kind == .formula }) {
                    store.installed.insert(Package(ref: PackageRef(.formula, "aaa-new"), fullName: "aaa-new", desc: sample.desc,
                                                   installedVersions: ["1.0"]), at: 0)
                }
            }),
        ]
        for scene in scenes {
            // A skipped scene still applies: later ones build on its state
            // (Security's findings tag the rows in 18-updates-tags).
            scene.apply()
            guard only?.contains(scene.name) != false else { continue }
            try? await Task.sleep(for: .seconds(scene.wait))
            capture(window, to: output.appendingPathComponent("\(scene.name).png"))
        }
        if only != nil {
            NSApp.terminate(nil)
            return
        }
        // Popovers are their own windows. The sidebar's vibrant rows don't draw
        // into a capture at all.
        if let popover = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.className.contains("Popover") }),
           let view = popover.contentView {
            capture(view, to: output.appendingPathComponent("9-activity-popover.png"))
        }
        // Sheets are their own windows too.
        store.doctor = .checking
        for _ in 0..<120 where store.doctor == .checking {
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(1))
        if let sheet = window.attachedSheet?.contentView {
            capture(sheet, to: output.appendingPathComponent("11-doctor.png"))
        }
        // An open sheet keeps the app from quitting.
        store.doctor = nil
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        // With Screen Recording permission, the window server's own image: glass,
        // the sidebar's vibrancy and the window shadow included.
        if ProcessInfo.processInfo.environment["CASKROOM_SNAPSHOT_SCREEN"] == "1" {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-l", String(window.windowNumber), url.path]
            try? shot.run()
            shot.waitUntilExit()
            return
        }
        if let view = window.contentView?.superview { capture(view, to: url) }
    }

    private static func capture(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif
}

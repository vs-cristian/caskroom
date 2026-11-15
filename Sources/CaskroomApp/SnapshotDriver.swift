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
/// skips the Doctor capture.
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
        if let path = env["CASKROOM_TEST_UNINSTALL"] {
            await testUninstall(path, confirm: env["CASKROOM_TEST_UNINSTALL_CONFIRM"] == "1", store: store)
            return
        }
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
        // One service running at login, one that failed. No user: the row would
        // show this Mac's account name, and these end up on the site.
        if store.services.count >= 2, !store.services.contains(where: \.status.isRunning), env["CASKROOM_SNAPSHOT_FAKE_UPDATES"] != "0" {
            let (a, b) = (store.services[0], store.services[1])
            store.services[0] = ServiceEntry(name: a.name, status: .started, user: nil, file: a.file, pid: 4321,
                                             registered: true, logPath: a.logPath, errorLogPath: a.errorLogPath)
            store.services[1] = ServiceEntry(name: b.name, status: .error, user: nil, file: b.file, exitCode: 78,
                                             registered: true, logPath: b.logPath, errorLogPath: b.errorLogPath)
        }

        // CASKROOM_SNAPSHOT_SELECTION=1: clicks rows the way a person would and
        // prints PASS or FAIL for each check, with a capture of each step.
        if env["CASKROOM_SNAPSHOT_SELECTION"] == "1" {
            await checkSelection(store: store, window: window, output: output)
            NSApp.terminate(nil)
            return
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
            ("19-taps", 3, { store.searchText = ""; store.path = NavigationPath(); store.sidebar = .taps }),
            ("20-add-tap", 2, { store.addingTap = true }),
            ("21-brewfile-import", 6, {
                store.addingTap = false
                // A sample, so the capture shows each kind: some here already, some not.
                let url = output.appendingPathComponent("Brewfile")
                try? """
                tap "mongodb/brew"
                tap "hashicorp/tap"
                brew "gh"
                brew "ripgrep"
                brew "hashicorp/tap/terraform"
                cask "iina"
                cask "zed"
                cask "rectangle"
                mas "Xcode", id: 497799835
                vscode "rust-lang.rust-analyzer"
                """.write(to: url, atomically: true, encoding: .utf8)
                Task { await store.previewBrewfile(url) }
            }),
            ("22-bulk-uninstall", 2, {
                store.brewfileImport = nil
                // Two apps, plus a dependency something outside the selection needs.
                let apps = store.installed.filter { $0.kind == .cask }.prefix(2).map(\.ref)
                let needed = store.installed.first { !store.dependents(of: $0.ref).isEmpty }.map { [$0.ref] } ?? []
                store.bulkUninstall = store.uninstallPlan(Set(apps + needed))
            }),
            ("23-uninstall-apps", 4, { store.bulkUninstall = nil; store.brewfileImport = nil; store.sidebar = .uninstallApps }),
            // Only looks: nothing is removed unless the sheet's button is clicked.
            ("24-app-removal", 6, {
                if let app = store.otherApps?.first { store.uninstallApp(at: URL(fileURLWithPath: app.path)) }
            }),
            ("9-activity", 2, {
                store.bulkUninstall = nil
                store.appRemoval = nil
                store.path = NavigationPath(); store.searchText = ""; store.sidebar = .library(.all); store.showActivity = true
            }),
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
            // Sheets and dialogs are windows of their own.
            if let sheet = window.attachedSheet?.contentView {
                capture(sheet, to: output.appendingPathComponent("\(scene.name)-sheet.png"))
            }
            // Popovers are their own windows, captured while this scene holds one open.
            if scene.name == "9-activity",
               let popover = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.className.contains("Popover") }),
               let view = popover.contentView {
                capture(view, to: output.appendingPathComponent("9-activity-popover.png"))
            }
        }
        if only != nil {
            NSApp.terminate(nil)
            return
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

    /// `CASKROOM_TEST_UNINSTALL=<app path>`: opens the uninstall sheet for that
    /// app and prints what it found; with `CASKROOM_TEST_UNINSTALL_CONFIRM=1`
    /// also clicks the sheet's button (which really moves things to the
    /// Trash) and prints the outcome. Then quits.
    private static func testUninstall(_ path: String, confirm: Bool, store: BrewStore) async {
        func log(_ text: String) { print("UNINSTALL \(text)"); fflush(stdout) }
        for _ in 0..<120 where store.installed.isEmpty || store.isRefreshing {
            try? await Task.sleep(for: .milliseconds(500))
        }
        store.uninstallApp(at: URL(fileURLWithPath: path))
        guard let removal = store.appRemoval else { log("no sheet"); NSApp.terminate(nil); return }
        for _ in 0..<240 where removal.state == .scanning {
            try? await Task.sleep(for: .milliseconds(250))
        }
        log("state \(removal.state) cask \(removal.cask?.name ?? "-") running \(store.isRunning(removal)) admin \(removal.needsAdministrator)")
        for leftover in removal.leftovers {
            log("\(removal.selected.contains(leftover.path) ? "[x]" : "[ ]") \(leftover.evidence)\(leftover.needsAdministrator ? " admin" : "") \(leftover.path)")
        }
        log("receipts \(removal.receipts)")
        guard confirm, removal.state == .ready else { store.appRemoval = nil; NSApp.terminate(nil); return }
        store.confirmRemoval(removal)
        if removal.cask != nil {
            try? await Task.sleep(for: .seconds(1))
            for _ in 0..<600 where store.hasPendingOperations || !store.leftoverCleanups.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let run = store.operations.last {
                log("brew \(run.operation.command): \(run.state)")
                for line in run.log.suffix(40) { log("  \(line.text)") }
            }
        } else {
            for _ in 0..<600 {
                if case .finished = removal.state { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if case let .finished(outcome) = removal.state {
                for path in outcome.moved { log("moved \(path)") }
                for failure in outcome.failed { log("FAILED \(failure.path): \(failure.reason)") }
                log("forgot \(outcome.forgotten) declined \(outcome.administratorDeclined)")
            } else {
                log("never finished: \(removal.state)")
            }
        }
        store.appRemoval = nil
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
    }

    /// Selecting rows with ⌘-click while a plain click opens a page; see
    /// `PackageSelection`. Points are from the window's top left, for its
    /// 1180×760 size: the first rows of each list.
    private static func checkSelection(store: BrewStore, window: NSWindow, output: URL) async {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        var step = 0
        func settle(_ name: String) async {
            try? await Task.sleep(for: .seconds(1.5))
            step += 1
            capture(window, to: output.appendingPathComponent("s\(step)-\(name).png"))
        }
        func expect(_ what: String, _ ok: Bool) { print(ok ? "PASS" : "FAIL", what) }

        store.sidebar = .library(.all)
        await settle("library")
        click(window, at: NSPoint(x: 600, y: 156), flags: .command)
        click(window, at: NSPoint(x: 600, y: 200), flags: .command)
        await settle("library-selected")
        expect("⌘-click selects without opening", store.path.isEmpty)
        click(window, at: NSPoint(x: 600, y: 244))
        await settle("library-click")
        expect("a plain click opens the page", store.path.count == 1)
        store.path = NavigationPath()

        store.sidebar = .updates
        await settle("updates")
        let rows = (ProcessInfo.processInfo.environment["CASKROOM_SELECTION_ROWS"] ?? "")
            .split(separator: ",").compactMap { Double($0) }
        guard rows.count >= 4 else { return }
        click(window, at: NSPoint(x: 600, y: rows[0]), flags: .command)
        click(window, at: NSPoint(x: 600, y: rows[1]), flags: .command)
        await settle("updates-selected")
        expect("⌘-click selects updates without opening", store.path.isEmpty)
        // A link inside a row does its own thing, without opening the page.
        click(window, at: NSPoint(x: rows[2], y: rows[3]))
        await settle("updates-link")
        expect("a link in a row doesn't open the page", store.path.isEmpty)
        if rows.count >= 5 {
            store.showActivity = false
            click(window, at: NSPoint(x: 600, y: rows[4]))
            await settle("updates-recent")
            expect("an Updated Recently row opens its page", store.path.count == 1)
        }
    }

    /// A click at `point`, measured from the window's top left, sent to the
    /// window directly: no Accessibility permission needed.
    static func click(_ window: NSWindow, at point: NSPoint, flags: NSEvent.ModifierFlags = []) {
        let location = NSPoint(x: point.x, y: window.frame.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            // Through the app, so its event monitors (PlainClick) see it, as a real click.
            NSApp.sendEvent(event)
        }
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

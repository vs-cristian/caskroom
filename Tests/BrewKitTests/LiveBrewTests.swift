import XCTest
@testable import BrewKit

/// Read-only checks against the real Homebrew on this machine.
/// Run with `CASKROOM_BREW_TESTS=1 swift test --filter LiveBrewTests`.
final class LiveBrewTests: XCTestCase {
    private var service: BrewService!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASKROOM_BREW_TESTS"] == "1", "set CASKROOM_BREW_TESTS=1")
        let runner = try XCTUnwrap(BrewRunner.locate(), "Homebrew not installed")
        service = BrewService(runner: runner)
    }

    func testReadCommandsDecode() async throws {
        let installed = try await service.installed()
        XCTAssertFalse(installed.isEmpty)
        XCTAssertTrue(installed.allSatisfy(\.isInstalled))
        _ = try await service.outdated()
        _ = try await service.outdated(greedy: true)
        _ = try await service.services()
        _ = try await service.cleanupPreview()
        _ = try await service.doctor()
    }

    func testTapsAndBrewfilePlan() async throws {
        let taps = try await service.tapInfo()
        // Under the API homebrew/cask is listed but not tapped, and left out.
        let tapped = try await service.taps()
        if !tapped.contains("homebrew/cask") {
            XCTAssertFalse(taps.contains { $0.name == "homebrew/cask" })
        }
        // A formula that doesn't exist is simply missing to bundle check.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LiveBrewfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Brewfile")
        try #"brew "this-formula-does-not-exist-caskroom""#.write(to: file, atomically: true, encoding: .utf8)
        let plan = try await service.brewfilePlan(at: file)
        XCTAssertEqual(plan.formulae, [.init(name: "this-formula-does-not-exist-caskroom", needed: true)])
        // Not Ruby: brew says why, and nothing is installed.
        try "brew \"tree\"\nthis is not ruby(\n".write(to: file, atomically: true, encoding: .utf8)
        do {
            _ = try await service.brewfilePlan(at: file)
            XCTFail("expected an invalid Brewfile to fail")
        } catch let BrewError.commandFailed(_, _, stderr) {
            XCTAssertTrue(stderr.contains("Invalid Brewfile"), stderr)
        }
    }

    func testSearchIndexAndInfo() async throws {
        let index = try await service.searchIndex()
        XCTAssertGreaterThan(index.formulae.count, 1000)
        XCTAssertGreaterThan(index.casks.count, 1000)
        XCTAssertEqual(index.search("wget").first, PackageRef(.formula, "wget"))

        let info = try await service.info(PackageRef(.cask, "iterm2"))
        XCTAssertEqual(info?.displayName, "iTerm2")
        XCTAssertNotNil(info?.latestVersion)
        XCTAssertEqual(info?.appPath, "/Applications/iTerm.app")
        XCTAssertEqual(info?.autoUpdates, true)
        XCTAssertEqual(info?.hasZap, true)
    }

    /// Public feeds and Homebrew's public API; nothing about this Mac is sent.
    /// (`brew vulns` isn't run: it sends installed formulae to OSV.dev.)
    func testNetworkSources() async throws {
        let commands = CommandIndex(text: try await CommandIndex.fetch())
        XCTAssertGreaterThan(commands.formulaCount, 5000)
        XCTAssertEqual(commands.search("rg").first?.formulae.first, "ripgrep")
        XCTAssertTrue(commands.search("pg_dump").first?.formulae.contains("libpq") == true)

        let apps = try await AdoptionIndex.fetch()
        XCTAssertEqual(apps["Google Chrome.app"]?.first, "google-chrome")

        let installed = try await service.installed()
        var sources = 0, withNotes = 0
        for package in installed where package.isInstalled {
            guard let source = ReleaseSource.find(for: package), let current = package.latestVersion else { continue }
            sources += 1
            let notes = try await ReleaseNotes.load(source, installed: nil, current: package.kind.upstreamVersion(current))
            if !notes.isEmpty { withNotes += 1 }
            print("release notes:", package.name, source, notes.map(\.tag), notes.first.map { String($0.text.prefix(80)) } ?? "")
        }
        print("release notes: \(withNotes) of \(sources) sources have this version's notes")
        XCTAssertGreaterThan(withNotes, 0)
    }
}

/// Installs and uninstalls `tree` through the streaming path the app uses.
/// Run with `CASKROOM_BREW_MUTATE=1 swift test --filter LiveBrewMutationTests`.
final class LiveBrewMutationTests: XCTestCase {
    func testInstallThenUninstallTree() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASKROOM_BREW_MUTATE"] == "1", "set CASKROOM_BREW_MUTATE=1")
        let service = BrewService(runner: try XCTUnwrap(BrewRunner.locate()))
        let tree = PackageRef(.formula, "tree")
        let before = try await service.installed()
        try XCTSkipIf(before.contains { $0.ref == tree }, "tree is already installed; leaving it alone")

        var lines: [LogLine] = []
        for try await line in service.perform(.install(tree)) { lines.append(line) }
        XCTAssertTrue(lines.contains { $0.text.contains("tree") }, "expected streamed install output")
        let afterInstall = try await service.installed()
        XCTAssertEqual(afterInstall.first { $0.ref == tree }?.installedOnRequest, true)

        for try await _ in service.perform(.uninstall(tree)) {}
        let afterUninstall = try await service.installed()
        XCTAssertFalse(afterUninstall.contains { $0.ref == tree })
    }

    /// The same, through a Brewfile, as Import Brewfile does it.
    func testBrewfileInstallsTree() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASKROOM_BREW_MUTATE"] == "1", "set CASKROOM_BREW_MUTATE=1")
        let service = BrewService(runner: try XCTUnwrap(BrewRunner.locate()))
        let tree = PackageRef(.formula, "tree")
        let installed = try await service.installed()
        try XCTSkipIf(installed.contains { $0.ref == tree }, "tree is already installed; leaving it alone")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LiveBrewfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Brewfile")
        try #"brew "tree""#.write(to: file, atomically: true, encoding: .utf8)

        let before = try await service.brewfilePlan(at: file)
        XCTAssertEqual(before.formulae, [.init(name: "tree", needed: true)])
        for try await _ in service.perform(.installBrewfile(file)) {}
        let after = try await service.brewfilePlan(at: file)
        XCTAssertTrue(after.isSatisfied)

        for try await _ in service.perform(.uninstall(tree)) {}
        let afterUninstall = try await service.installed()
        XCTAssertFalse(afterUninstall.contains { $0.ref == tree })
    }
}

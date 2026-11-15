import XCTest
@testable import BrewKit

/// Runs the self-upgrade helper against a shell script standing in for brew.
final class SelfUpgradeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SelfUpgradeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testWaitsForTheAppThenRunsBrewAndLogs() async throws {
        let upgrade = try fakeUpgrade(#"echo "args: $*"; echo "auto-update: ${HOMEBREW_NO_AUTO_UPDATE:-allowed}"; echo warning >&2"#)
        // Stands in for the app: the helper must not start brew while it runs.
        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["1"]
        try app.run()

        try upgrade.start(["upgrade", "--cask", "caskroom"], waitingFor: app.processIdentifier, relaunch: nil)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(FileManager.default.fileExists(atPath: upgrade.logURL.path))

        let outcome = try await waitForOutcome(upgrade)
        XCTAssertEqual(outcome.exitStatus, 0)
        XCTAssertEqual(outcome.log, ["args: upgrade --cask caskroom", "auto-update: allowed", "warning"])
        // Read once.
        XCTAssertNil(upgrade.pickUp())
    }

    func testFailureKeepsTheStatus() async throws {
        let upgrade = try fakeUpgrade(#"echo "Error: Download failed" >&2; exit 3"#)
        try upgrade.start(["upgrade", "--cask", "caskroom"], waitingFor: 999_999, relaunch: nil)
        let outcome = try await waitForOutcome(upgrade)
        XCTAssertEqual(outcome.exitStatus, 3)
        XCTAssertEqual(outcome.log, ["Error: Download failed"])
    }

    func testRelaunchesWhenAsked() async throws {
        let marker = dir.appendingPathComponent("relaunched")
        // `open` is found on PATH; brew's own bin dir comes first there.
        let open = dir.appendingPathComponent("open")
        try "#!/bin/sh\necho \"$1\" > '\(marker.path)'\n".write(to: open, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: open.path)

        let upgrade = try fakeUpgrade("exit 1")
        try upgrade.start(["upgrade"], waitingFor: 999_999, relaunch: "/Applications/Caskroom.app")
        _ = try await waitForOutcome(upgrade)
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "/Applications/Caskroom.app\n")
    }

    func testAnUnfinishedRunHasNoStatus() throws {
        let upgrade = try fakeUpgrade("")
        try FileManager.default.createDirectory(at: upgrade.directory, withIntermediateDirectories: true)
        try "==> Downloading\n".write(to: upgrade.partialLogURL, atomically: true, encoding: .utf8)
        let outcome = try XCTUnwrap(upgrade.pickUp())
        XCTAssertNil(outcome.exitStatus)
        XCTAssertEqual(outcome.log, ["==> Downloading"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: upgrade.partialLogURL.path))
    }

    func testNothingToPickUp() throws {
        XCTAssertNil(try fakeUpgrade("").pickUp())
    }

    private func waitForOutcome(_ upgrade: SelfUpgrade) async throws -> SelfUpgrade.Outcome {
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: upgrade.logURL.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        return try XCTUnwrap(upgrade.pickUp())
    }

    private func fakeUpgrade(_ body: String) throws -> SelfUpgrade {
        let url = dir.appendingPathComponent("brew")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return SelfUpgrade(runner: BrewRunner(brewURL: url, sudoPAMFiles: []), directory: dir.appending(path: "logs"))
    }
}
